/// # CacheCleaner — Guarded Cache Deletion + Honest Freed-Bytes Accounting
///
/// An `actor` that deletes cache trees — permanently or to the Trash — with
/// every deletion target passing through `PathGuard` (D4) and every freed
/// byte measured at delete time, never assumed from pre-scan totals (D1).
///
/// ## Unified entry (fn-2.3)
///
/// `clean(items:moveToTrash:)` is THE one clean path — and since fn-4.7 the
/// ONLY one: every selected `ReclaimableItem` — category aggregate, per-item
/// scanner row, command category — flows through ONE dispatch on
/// `ReclaimAction`, with PathGuard enforced at this chokepoint via each
/// item's admission descriptor and per-root records. The pre-unification
/// category-vs-node_modules fork is gone, and so is the
/// `clean(results:nodeModules:moveToTrash:)` compatibility adapter that
/// outlived it: its callers (the ViewModel in fn-2.4, the CLI in fn-2.6) had
/// already migrated, and its remaining tests moved onto item fixtures when
/// the node_modules scanner was retired.
///
/// ## Safety model (fn-1.3, reshaped by fn-2.3)
///
/// 0. **Structural refusal before ANY skip (frozen order, epic round 13)**:
///    an item whose action and admission descriptor disagree — or a
///    non-`.missing` category-backed item with ZERO root records — is
///    refused with an item-keyed error INDEPENDENTLY of the runtime
///    validator (defense in depth: the cleaner never assumes validation
///    ran). Well-formed `.missing` items then skip; a skip must never mask
///    a malformed shape.
/// 1. **Scan-state refusal (R18)**: a `.denied` item is refused even when
///    selected — selection is mutable UI state and never overrides the
///    scanner's verdict. `.partiallyDenied` reaches the cleaner only
///    through explicit selection (fn-1.4 owns never-auto-selecting it) and
///    reports measured deletions only. `.empty` items are a pre-admission
///    no-op for every action — no entry, never an error (round 9).
/// 2. **Mode-aware guard**: `.removeContents` admits each `.measured` root
///    record's `requestedURL` at delete time via `admitDeletionRoot`
///    against the category's OWN `CategoryAdmissionPolicy` (the
///    `refusedAdmission`/`deniedUnmeasured` statuses are NEVER deletable);
///    each child is then `validateContainedChild`-checked (strict
///    descendant). `.removeItem` targets go through `admitContainer`
///    (constructor-injected container roots — the runtime's
///    scanner-declared union, NEVER roots read off items) +
///    `validateRemovableItem` (strict descendant + deny-list re-check +
///    cross-device refusal, R15) against their origin-container claim.
/// 3. **Unresolved spelling deletes; resolved spelling contains**: children
///    are enumerated under `AdmittedRoot.requestedURL` and deleted by their
///    unresolved URLs — a symlink child is removed AS a link, its target
///    untouched (R4); `.removeItem` deletes the descriptor's UNRESOLVED
///    `requestedTargetURL` (leaf never resolved — `item.url` is display
///    state, never a destructive input). Containment always compares
///    against the canonical resolved form, and the chain is re-validated
///    immediately before each destructive call (TOCTOU narrowing).
///    Additionally, an auto-clean-eligible orphaned-caches item re-runs the
///    sweep's bounded user-data probe immediately pre-delete and is refused
///    unless the scan-time clean promise re-establishes (no matches AND a
///    complete probe) — an entry recreated at the same name since the scan
///    must never be deleted on the strength of a probe of its predecessor.
/// 4. **`.commands` (R17)**: EVERY root record's `requestedURL` — all
///    statuses, the full scan-time capture — is re-admitted BEFORE any argv
///    runs; ANY refusal blocks the ENTIRE command set. `.missing` items
///    skip pre-dispatch and zero-record non-missing items are refused
///    outright, so a vacuous admission pass (a loop over zero roots) can
///    never launch argv — and because admission's canonical-components
///    fallback passes a declared spelling that no longer exists, a
///    delete-time SURVIVAL GATE additionally refuses the whole set when no
///    captured root still exists as a real directory (pre-unification
///    `resolvedPaths` parity; partial survival proceeds). Paths INSIDE a
///    command's argv are trusted registry code (`Categories.swift`), not
///    runtime input — admission covers the roots the category operates on.
///
/// ## Freed-bytes accounting (D1/R8)
///
/// Each deletion target is measured with `DirectorySizer` in `.deletionTarget`
/// mode immediately before deletion and settled through the claim-based
/// two-phase `InodeAccountingRegistry`: claims are REGISTERED before deletion,
/// canonical bytes TRANSFER once after success. Unique-inode bytes are exact;
/// hardlinked bytes are estimates (`estimatedUpToBytes`). Failed deletions
/// accept nothing — their registered claims remain transferable by siblings.
/// Command categories free bytes nothing measures: exact 0, estimated =
/// pre-scan size (R16).
///
/// ## Deletion modes
///
/// - **Permanent delete** (`moveToTrash: false`): `DepthSafeRemoval` —
///   descriptor-relative, no-follow, mount-respecting — offloaded to a
///   background queue. NOT `FileManager.removeItem()`, which composes an
///   absolute path per entry and therefore refuses, forever and with a
///   misattributed message, exactly the trees past `PATH_MAX` that the
///   descriptor-relative probe can now inspect and pronounce clean. Contents
///   of category roots are removed individually (the root itself survives so
///   tools/apps can recreate it).
/// - **Move to Trash** (`moveToTrash: true` — the GUI's DEFAULT, see
///   `CacheoutViewModel.moveToTrash`, so this is the arm most deletions take):
///   the injectable `@MainActor` trash seam (production:
///   `FileManager.trashItem`, which talks to Finder), reached ONLY through
///   `TrashDisposal`. `trashItem` takes a URL and resolves it inside itself,
///   so no binding can ride into the call; what rides in is a proof on either
///   side of it, and a disposal that cannot be proved is PUT BACK and reported
///   as a refusal — no entry, no bytes. WHICH fact the leaf is bound to
///   depends on what the item has (a scanner's `PreDeleteRevalidator` verdict,
///   or the object that stood at the name inside the admitted container), but
///   every disposal is bound to one of them and nothing here hands the seam a
///   bare URL. For three review rounds the two arms with no leaf verdict did
///   exactly that — all of contents mode plus every `.unestablished` item —
///   and this section described the arm as though they did not exist.
///   A trash failure is a per-child error — it never falls through to a
///   permanent delete.
///
/// The per-target pipeline is sequential — measure → register → re-validate →
/// delete → accept — with per-child error isolation (R10): one undeletable
/// child never poisons its siblings. The measurement latency is accepted
/// (epic: at most one metadata walk per deleted tree, no separate pre-walk).
///
/// ## Custom Clean Commands
///
/// Categories with `cleanCommands` (e.g., Simulator Devices) bypass file
/// deletion entirely. Each command runs directly via `/usr/bin/env` with an
/// argv array (never a shell), a 30-second timeout, and a restricted
/// environment: an allowlisted `PATH` plus `HOME` pinned to the injected
/// home, so commands stay anchored to the same seam as discovery and
/// admission. If a command times out, the process is terminated and an
/// error is reported.
///
/// ## Cleanup Logging
///
/// Every cleanup action AND every refusal is appended to
/// `<home>/.cacheout/cleanup.log` with ISO 8601 timestamps. Refusal lines are
/// classified off the typed `PathGuardError` cases — never message strings.
/// The home directory is injectable, so tests log inside their fixture home.
///
/// ## Error Handling
///
/// Errors are collected per category / per child rather than aborting the
/// cleanup. The returned `CleanupReport` carries split-component entries and
/// errors so the UI can render partial results honestly (R11/R16).

import Foundation
import Darwin

// MARK: - Claim-based two-phase accounting (R8)

/// Opaque token binding one deletion target ("child") to the inode claims it
/// registered. Returned by `registerObservations(_:)`; handed back to
/// `acceptSuccessful(_:)` after — and only after — the deletion succeeded.
/// The memberwise initializer is fileprivate so tokens cannot be forged.
struct RegisteredChild {
    fileprivate let claimedIdentities: [FileSystemIdentityProvider.Identity]
}

/// The byte components a successful deletion actually transferred out of the
/// registry — exactly what the report may add for that child, nothing more.
struct AcceptedByteComponents {
    var exactBytes: Int64 = 0
    var estimatedUpToBytes: Int64 = 0
}

/// Per-operation inode accounting registry (R8, D8 mitigation). Scope is
/// preserved fn-1 behavior (fn-2.3): ONE instance per `.removeContents`
/// aggregate (item-local — cross-category hardlinks still count per
/// category, D8-disclosed) and ONE instance per SCANNER of `.removeItem`
/// items, spanning all of that scanner's selected items in the operation.
///
/// Deleting one hardlink DECREMENTS the survivors' `st_nlink`, so later
/// observations of the same inode cannot be trusted for classification or
/// size. The registry therefore retains the CANONICAL byte value and a STICKY
/// classification from registration time, and transfers each inode's bytes at
/// most once per operation:
///
/// - **Phase 1 — `registerObservations`** (after measurement, BEFORE
///   deletion, atomic): merges the child's claims into the registry. Once ANY
///   observer saw an inode hardlinked it stays ESTIMATED for the whole
///   operation, regardless of registration order. Registration accepts no
///   bytes.
/// - **Phase 2 — `acceptSuccessful`** (after successful deletion only,
///   atomic): every inode the token claimed that has not yet been transferred
///   is marked transferred and its canonical bytes returned under the sticky
///   classification. Failed deletions never accept — their registrations
///   remain for siblings to transfer later (a successful child can accept
///   bytes first observed by a failed sibling).
actor InodeAccountingRegistry {

    private struct Registration {
        /// Byte value from the FIRST observation — later observations of a
        /// partially-deleted inode are not trusted.
        let canonicalByteSize: Int64
        /// Sticky: ratchets to `true` and never back — a survivor whose
        /// `st_nlink` already decayed to 1 must not reclassify as exact.
        var stickyHardlinked: Bool
        var transferred: Bool
    }

    private var registrations: [FileSystemIdentityProvider.Identity: Registration] = [:]

    /// Identities the registry has seen — handed to `DirectorySizer.measure`
    /// as `knownInodes` so an already-registered inode contributes zero local
    /// bytes while still emitting a claim.
    var knownIdentities: Set<FileSystemIdentityProvider.Identity> {
        Set(registrations.keys)
    }

    func registerObservations(_ claims: [InodeClaim]) -> RegisteredChild {
        for claim in claims {
            if var existing = registrations[claim.identity] {
                existing.stickyHardlinked =
                    existing.stickyHardlinked || claim.observedHardlinked
                registrations[claim.identity] = existing
            } else {
                registrations[claim.identity] = Registration(
                    canonicalByteSize: claim.canonicalByteSize,
                    stickyHardlinked: claim.observedHardlinked,
                    transferred: false
                )
            }
        }
        return RegisteredChild(claimedIdentities: claims.map(\.identity))
    }

    func acceptSuccessful(_ token: RegisteredChild) -> AcceptedByteComponents {
        var accepted = AcceptedByteComponents()
        for identity in token.claimedIdentities {
            guard var registration = registrations[identity],
                  !registration.transferred else { continue }
            registration.transferred = true
            registrations[identity] = registration
            if registration.stickyHardlinked {
                accepted.estimatedUpToBytes += registration.canonicalByteSize
            } else {
                accepted.exactBytes += registration.canonicalByteSize
            }
        }
        return accepted
    }
}

// MARK: - Pre-delete seam refusal

/// One pre-delete revalidation refusal, as the chokepoint consumes it: the
/// item-keyed `reason`, the cleanup-log `tag`, and the TYPED wire `payload`.
///
/// A named type rather than a tuple (fn-5.4) because it now travels to a
/// SECOND consumer — `WorktreeReclaimPerformer` runs the same seam for the
/// composite action — and one shape is what keeps the two from wording the
/// same refusal differently.
struct PreDeleteSeamRefusal {
    let reason: String
    let tag: String
    let payload: CleanupReport.ItemError.Refusal?
}

// MARK: - CacheCleaner

actor CacheCleaner {

    /// Injectable Trash seam. Production moves the URL to the Trash via
    /// Finder; tests record or redirect so nothing outside a fixture root is
    /// ever trashed. `@MainActor` because `trashItem` talks to Finder.
    ///
    /// IT RETURNS WHERE THE ITEM LANDED, and that is not bookkeeping: the
    /// disposal takes a URL and resolves it itself, so the ONLY way to ask
    /// what it actually took is to look at what it produced (see
    /// `TrashDisposal`). `nil` means the disposal would not say — which is
    /// treated as unprovable, never as success.
    typealias TrashHandler = @Sendable @MainActor (URL) throws -> URL?

    private let fileManager = FileManager.default
    private let home: URL
    private let provider: FileSystemIdentityProvider
    private let sizer: DirectorySizer
    private let pathGuard: PathGuard
    /// The scan-session container snapshot delete-time `.removeItem`
    /// admission is identity-bound to (fn-3.4, R9). `nil` is FAIL-CLOSED:
    /// a cleaner built without a session snapshot refuses every
    /// `.removeItem` item (`container-unavailable`) — there is no
    /// fail-open path; the cleaner for a set of items must hold the
    /// snapshot of the session that produced them.
    private let containerSnapshot: ContainerSnapshot?
    /// The REGISTRATION-captured per-scanner revalidator registry (fn-4.8,
    /// R17/D8), injected by `SpaceScannerRuntime.makeCleaner(snapshot:)` —
    /// never global state, never read off items. Empty for a cleaner built
    /// directly: such a cleaner then REFUSES every item carrying
    /// `requiresPreDeleteRevalidation` (fail-closed), because it cannot
    /// perform the re-inspection the item structurally demands.
    private let preDeleteRevalidators: [String: PreDeleteRevalidator]
    /// The SHARED git runner (fn-5.1), injected for the composite
    /// `git_worktree_reclaim` action and used by nothing else. `nil` is
    /// FAIL-CLOSED and is the DEFAULT: a cleaner built without a runner
    /// refuses every composite item rather than reaching for a runner of its
    /// own — the `containerSnapshot` doctrine, one dependency later. The
    /// protocol type (not the concrete runner) is what fn-5.1 froze as the
    /// injection seam, so tests inject doubles and production injects the one
    /// instance the scanner already shares.
    private let gitRunner: (any GitCommandRunning)?
    /// The DELETE-TIME per-invocation git budget (fn-5.4) — pinned at
    /// `WorktreeReclaimPerformer.deleteTimeGitTimeout` (300 s), NEVER
    /// fn-5.1's ~10 s scan default: a mid-removal timeout on a multi-GB tree
    /// leaves a partially-deleted tree. Injectable so tests can prove the
    /// budget is passed per invocation without waiting for it.
    private let gitTimeout: TimeInterval
    private nonisolated let trashHandler: TrashHandler

    /// - Parameters:
    ///   - home: home directory admission policies and the deny list anchor
    ///     to, and where `.cacheout/cleanup.log` lives (injectable — tests
    ///     pass a fixture home; production the real one).
    ///   - containerRoots: configured container roots for delete-time
    ///     `.removeItem` admission — REQUIRED, no default (fn-4.7). Every
    ///     production cleaner is built by
    ///     `SpaceScannerRuntime.makeCleaner(snapshot:)` from the runtime's
    ///     registration-derived `trustedContainerRoots` union, so delete-time
    ///     admission covers exactly what registration declared. A
    ///     store-reading default inside the cleaner would resolve dev-root
    ///     configuration at the wrong layer and could admit roots the
    ///     registered runtime never walked; direct callers (tests, the
    ///     headless paths) pass their roots explicitly — `[]` admits no
    ///     container item at all, which is the honest fail-closed value for a
    ///     cleaner that owns no containers.
    ///   - containerSnapshot: the producing scan session's container
    ///     identity snapshot; `nil` refuses every `.removeItem` deletion
    ///     (fail-closed — category admission is unaffected).
    ///   - preDeleteRevalidators: the runtime's registration-captured
    ///     per-scanner revalidator registry (fn-4.8). The DEFAULT (empty)
    ///     is fail-closed for items carrying `requiresPreDeleteRevalidation`
    ///     — a cleaner that cannot re-inspect a marked item refuses it.
    ///   - provider: identity provider shared with `PathGuard` and the sizer
    ///     (tests may subclass to inject devices/kinds).
    ///   - trashHandler: Trash seam; `nil` uses `FileManager.trashItem`.
    ///   - gitRunner: the shared fn-5.1 runner for the composite
    ///     `git_worktree_reclaim` action. TRAILING and DEFAULTED so every
    ///     existing construction site — including
    ///     `SpaceScannerRuntime.makeCleaner(snapshot:trashHandler:)` —
    ///     compiles unchanged; the default `nil` refuses every composite
    ///     item (fail-closed, the `containerSnapshot` precedent). fn-5.6
    ///     threads the production instance through `makeCleaner`.
    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        containerRoots: [URL],
        containerSnapshot: ContainerSnapshot? = nil,
        preDeleteRevalidators: [String: PreDeleteRevalidator] = [:],
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider(),
        trashHandler: TrashHandler? = nil,
        gitRunner: (any GitCommandRunning)? = nil,
        gitTimeout: TimeInterval = WorktreeReclaimPerformer.deleteTimeGitTimeout
    ) {
        self.home = home
        self.provider = provider
        self.sizer = DirectorySizer(provider: provider)
        self.pathGuard = PathGuard(
            home: home, containerRoots: containerRoots, provider: provider
        )
        self.containerSnapshot = containerSnapshot
        self.preDeleteRevalidators = preDeleteRevalidators
        self.gitRunner = gitRunner
        self.gitTimeout = gitTimeout
        self.trashHandler = trashHandler ?? { url in
            var landed: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
            return landed as URL?
        }
    }

    // MARK: Clean — unified entry (fn-2.3)

    /// THE one clean path. Consumes bare `ReclaimableItem`s (already
    /// selected upstream — selection never rides the item) and dispatches
    /// on `ReclaimAction`, enforcing PathGuard per action at this
    /// chokepoint.
    ///
    /// FROZEN check order (epic round 13 — a skip must never mask a
    /// malformed shape): (1) structural action/descriptor compatibility on
    /// EVERY item regardless of state; (1b) the fn-4.8 MARKED-BUT-
    /// UNREVALIDATABLE refusal, ordered with (1) for the same reason — a
    /// state skip must never mask it either; (2) well-formed `.missing`
    /// skip; (3) non-`.missing` category-backed zero-record refusal;
    /// (4) state eligibility (`.denied` refusal, `.empty` no-op, aggregate
    /// `.commands`/`.removeContents` zero-measured skip); (5) action
    /// dispatch.
    ///
    /// - Parameter authorization: the PER-CLEAN `[ItemKey: acknowledgement]`
    ///   context (fn-4.8, R17). Each item's revalidator receives ITS OWN
    ///   entry (nil when absent) — the item's structural
    ///   `valuablesDisclosure` is disclosure only and is never read as
    ///   acknowledgement. Defaults to EMPTY: an unacknowledged clean, which
    ///   is exactly what a GUI clean without the confirmation sheet's
    ///   population (fn-4.6) and a plain CLI `--confirm` (fn-4.9) are.
    func clean(
        items: [ReclaimableItem],
        moveToTrash: Bool,
        authorization: PreDeleteAuthorizationContext = [:]
    ) async -> CleanupReport {
        var entries: [CleanupReport.Entry] = []
        var errors: [CleanupReport.ItemError] = []
        // Accounting scope (preserved fn-1 behavior): ONE registry per
        // SCANNER of `.removeItem` items — two items of one scanner
        // hardlinking the same inode transfer it once — while each
        // `.removeContents` aggregate builds its ITEM-LOCAL registry inside
        // its dispatch (cross-category hardlinks still count per category,
        // D8-disclosed).
        var scannerRegistries: [String: InodeAccountingRegistry] = [:]

        for item in items {
            // (1) Structural compatibility — FIRST, unconditional, every
            // item, every state. Defense in depth: the runtime validator
            // refuses the same shapes, but this chokepoint never assumes
            // validation ran (fn-2.7's headless path reaches it directly).
            if let refusal = Self.structuralRefusal(of: item) {
                errors.append(Self.itemError(item, refusal))
                logRefusal(label: item.displayName, tag: "malformed-item",
                           detail: refusal)
                continue
            }

            // (1b) MARKED, but this cleaner holds no revalidator for its
            // scanner (fn-4.8) — fail closed HERE, ordered with (1) rather
            // than at the destructive chokepoint: a `.missing`/`.empty`
            // skip or a `.denied` refusal below would otherwise SWALLOW the
            // condition, and a marked item that cannot be re-inspected must
            // always SURFACE as its own item-keyed error, never as a silent
            // no-op or a differently-worded refusal. The chokepoint keeps
            // the same check as defense in depth.
            if let refusal = Self.missingRevalidatorRefusal(
                for: item, registry: preDeleteRevalidators
            ) {
                errors.append(Self.itemError(item, refusal))
                logRefusal(label: item.displayName,
                           tag: "revalidator-unavailable", detail: refusal)
                continue
            }

            // (2) Well-formed `.missing`: nothing resolved on this machine
            // — nothing to do, no entry, no error. Skipping BEFORE dispatch
            // also keeps an empty record set from vacuously passing
            // `.commands` re-admission (round 8).
            if item.state == .missing { continue }

            // (3) A non-`.missing` category-backed item with ZERO root
            // records can only be a construction bug — never vacuously
            // admissible (rounds 11-12). Exhaustive over the action so a
            // future case is a compile-time decision.
            //
            // SITE 1 of 8 (fn-5.3): the composite JOINS this refusal in BOTH
            // modes. Stale mode's worktree and prune mode's admin container
            // are each captured as a root record by the scan, so an empty
            // record set is the same construction bug it is for an aggregate
            // — and the composite's structural rules demand a `.measured`
            // record binding the target in every deletable state, which zero
            // records could never satisfy.
            switch item.action {
            case .removeContents, .commands, .gitWorktreeReclaim:
                if item.rootRecords.isEmpty {
                    let reason = "refused: no root records — nothing was captured for this item to admit"
                    errors.append(Self.itemError(item, reason))
                    logRefusal(label: item.displayName, tag: "no-root-records",
                               detail: reason)
                    continue
                }
            case .removeItem:
                break
            }

            // (4) State eligibility. R18: the scanner's verdict beats
            // mutable selection state — `.denied` is refused even when
            // selected, and the refusal SURFACES as an error rather than
            // silently skipping.
            if item.state == .denied {
                let reason = Self.deniedRefusalReason(for: item.scanError)
                errors.append(Self.itemError(item, reason))
                logRefusal(label: item.displayName, tag: "scan-denied",
                           detail: reason)
                continue
            }
            // `.empty` has nothing to clean: a no-op BEFORE any admission
            // for EVERY action — no entry, never an error, even when
            // explicitly selected/addressed (round 9).
            if item.state == .empty { continue }
            // Aggregate zero-measured parity (the as-built `result.isEmpty`
            // guard): no argv ever runs for an empty command category, and
            // no children are deleted for a zero-allocated `.removeContents`
            // aggregate — a `.measured` category holding only zero-allocation
            // files plans as "skip" in the CLI confirmation/dry-run, and a
            // confirmed run must never delete what its plan said it would
            // skip. `.removeItem` deliberately has NO zero-byte skip (frozen
            // plan parity: a measured zero-byte per-item target IS deleted).
            // Exhaustive so a future action decides at compile time.
            switch item.action {
            case .commands, .removeContents:
                if item.allocatedBytes == 0 { continue }
            case .removeItem:
                break
            // SITE 2 of 8 (fn-5.3): the composite is EXCLUDED from the
            // zero-byte skip, deliberately. A prune-only item frees roughly
            // nothing (git metadata) yet MUST still run — the registry is
            // what it cleans — and this skip runs BEFORE dispatch, so
            // including it here would turn every zero-byte prune item into a
            // silent no-op that reported success. (fn-5.5 emits prune items
            // `.measured`, never `.empty`, for the same reason: the `.empty`
            // no-op above also precedes dispatch.)
            case .gitWorktreeReclaim:
                break
            }
            // `.partiallyDenied` reaches here only through explicit
            // selection (fn-1.4/fn-2.4 own never auto-selecting it) and
            // reports measured deletions only — which is all this pipeline
            // ever reports.

            // (5) Dispatch — exhaustive, no `default:` (fn-5 adds a
            // composite case; that addition must be compile-time-visible).
            switch item.action {
            case .removeContents:
                // The descriptor arm is guaranteed by check (1).
                guard case .category(let category) = item.admission else { continue }
                let outcome = await cleanContents(
                    of: item, category: category, moveToTrash: moveToTrash
                )
                if let entry = outcome.entry { entries.append(entry) }
                errors.append(contentsOf: outcome.errors)

            case .commands:
                // Argv comes from the CATEGORY's declaration — check (1)
                // refused any payload mismatch, and sourcing from the
                // admission descriptor keeps command argv trusted registry
                // code, never item input.
                guard case .category(let category) = item.admission,
                      let commands = category.cleanCommands else { continue }
                let outcome = cleanViaCommands(commands, for: item, category: category)
                if let entry = outcome.entry { entries.append(entry) }
                errors.append(contentsOf: outcome.errors)

            case .removeItem:
                guard case .containerItem(let origin, let target) = item.admission else { continue }
                let registry: InodeAccountingRegistry
                if let existing = scannerRegistries[item.scannerID] {
                    registry = existing
                } else {
                    registry = InodeAccountingRegistry()
                    scannerRegistries[item.scannerID] = registry
                }
                let outcome = await removeGuardedItem(
                    item, origin: origin, target: target,
                    registry: registry, moveToTrash: moveToTrash,
                    // THIS item's own entry — never another item's, never
                    // the item's structural disclosure.
                    authorization: authorization[item.key]
                )
                if let entry = outcome.entry { entries.append(entry) }
                errors.append(contentsOf: outcome.errors)

            // SITE 3 of 8: the composite EXECUTION arm (fn-5.4 replaced
            // fn-5.3's fail-closed placeholder). Two fail-closed
            // preconditions come first and are kept APART on purpose — a
            // cleaner without the runner seam is a COMPOSITION fault (the
            // runtime never threaded it through), while a cleaner without
            // the session snapshot is the `removeGuardedItem` doctrine's own
            // refusal (items must be cleaned with the session that produced
            // them). Collapsing them would hide a wiring regression behind
            // an identity refusal.
            case .gitWorktreeReclaim(let plan):
                // The descriptor arm is guaranteed by check (1).
                guard case .containerItem(let origin, let target) = item.admission
                else { continue }
                guard let gitRunner else {
                    let reason = "refused: no git runner is available to this "
                        + "cleaner — a git_worktree_reclaim item can only be "
                        + "cleaned through a cleaner built with one"
                    errors.append(Self.itemError(item, reason))
                    logRefusal(label: item.displayName,
                               tag: "git-runner-unavailable", detail: reason)
                    continue
                }
                guard let snapshot = containerSnapshot else {
                    let error = PathGuardError.containerUnavailable(path: origin.path)
                    let detail = "\(target.path): \(error.localizedDescription) "
                        + "(no scan-session container snapshot — items must be "
                        + "cleaned with the session that produced them)"
                    errors.append(Self.itemError(item, detail))
                    logRefusal(label: item.displayName,
                               tag: Self.refusalTag(error), detail: detail)
                    continue
                }
                // The SAME per-scanner registry `.removeItem` items of this
                // scanner use: two items of one scanner hardlinking an inode
                // transfer it once.
                let registry: InodeAccountingRegistry
                if let existing = scannerRegistries[item.scannerID] {
                    registry = existing
                } else {
                    registry = InodeAccountingRegistry()
                    scannerRegistries[item.scannerID] = registry
                }
                let performer = makePerformer(
                    for: item, runner: gitRunner, snapshot: snapshot,
                    moveToTrash: moveToTrash,
                    // THIS item's own entry — never another item's, never
                    // the item's structural disclosure.
                    authorization: authorization[item.key]
                )
                let outcome = await performer.perform(
                    item: item, plan: plan, origin: origin, target: target,
                    registry: registry
                )
                if let entry = outcome.entry { entries.append(entry) }
                errors.append(contentsOf: outcome.errors)
            }
        }

        // Report-level disposal is the REQUESTED mode; each entry carries
        // what actually happened (command-backed entries stay `.permanent`
        // even in a Trash run).
        return CleanupReport(
            disposal: moveToTrash ? .trash : .permanent,
            entries: entries,
            errors: errors
        )
    }

    // MARK: - Structural refusal (defense in depth, rounds 11-13)

    /// The action/descriptor shapes the runtime validator rejects, refused
    /// HERE independently — a chokepoint that trusts its caller's
    /// validation is not a chokepoint. Exhaustive over `ReclaimAction` (a
    /// future case must decide its descriptor requirement at compile time).
    /// The non-`.missing` zero-record rule is check (3) in `clean(items:)`
    /// — it is state-aware and therefore ordered AFTER the `.missing` skip.
    private static func structuralRefusal(of item: ReclaimableItem) -> String? {
        // The revalidation marker (fn-4.8) is a PER-TARGET contract: the
        // seam re-inspects the ONE `.containerItem` target immediately
        // before deleting it. An aggregate carrying the marker could never
        // be re-inspected that way, so it is refused here rather than
        // deleted through a path the marker does not cover — the marked-item
        // guarantee ("nothing marked is ever deleted without passing the
        // seam") must hold for EVERY action, not just the one that has a
        // seam. No production scanner emits this shape; a forged or
        // regressed item cannot use it to slip past revalidation.
        //
        // SITE 8 of 8 (fn-5.3) — the site the epic census MISSED: fn-4.8
        // added this second exhaustive switch INSIDE `structuralRefusal`,
        // so the function holds two, not one.
        //
        // FLIPPED TO TRUE BY fn-5.4, deliberately and on the condition
        // fn-5.3 named: `WorktreeReclaimPerformer` now routes the composite
        // item through the SAME seam this marker guards, in BOTH modes, at
        // the same position `removeGuardedItem` uses — after admission,
        // containment and the mount-boundary check, and before ANY claim
        // registration, git invocation or filesystem delete. The marker's
        // guarantee ("nothing marked is ever deleted without passing the
        // seam") therefore holds for the composite by construction, and the
        // fail-closed half still holds too: check (1b) refuses a MARKED
        // composite item whose scanner has no registered revalidator.
        //
        // `.removeContents`/`.commands` stay FALSE — an aggregate cannot be
        // re-inspected per target, which is what the marker means.
        let revalidatableAction: Bool
        switch item.action {
        case .removeItem, .gitWorktreeReclaim: revalidatableAction = true
        case .removeContents, .commands:
            revalidatableAction = false
        }
        if item.requiresPreDeleteRevalidation, !revalidatableAction {
            return "refused: requiresPreDeleteRevalidation is a per-target "
                + "contract — only a remove_item item can be re-inspected "
                + "immediately before its deletion"
        }

        switch item.action {
        case .removeItem:
            switch item.admission {
            case .containerItem:
                return nil
            case .category:
                return "refused: a remove_item item must carry the container-item admission descriptor"
            }
        case .removeContents:
            switch item.admission {
            case .category(let category):
                // A command-backed category can never route through file
                // deletion: pre-unification, the category's OWN declaration
                // decided the path (`cleanCommands` beat contents mode), so
                // an action/category mismatch here can only be a forged or
                // corrupted item.
                if category.cleanCommands != nil {
                    return "refused: a command-backed category cleans via its declared commands, never file deletion"
                }
                return nil
            case .containerItem:
                return "refused: a \(item.action.wireString) item must carry category admission provenance"
            }
        case .commands(let payload):
            switch item.admission {
            case .category(let category):
                // Command argv is TRUSTED REGISTRY CODE (`Categories.swift`)
                // — never item input. The payload riding the action must BE
                // the category's declaration; dispatch then executes the
                // CATEGORY's argv, so a crafted payload gains nothing even
                // if this refusal were bypassed.
                if category.cleanCommands != payload {
                    return "refused: the item's argv payload does not match the category's declared cleanCommands"
                }
                return nil
            case .containerItem:
                return "refused: a \(item.action.wireString) item must carry category admission provenance"
            }
        // SITE 4 of 8 (fn-5.3). The plan riding the action is a CLAIM
        // exactly like a `.commands` payload, so it is checked against the
        // admission descriptor here — independently of the runtime
        // validator, which this chokepoint never assumes ran (fn-2.7's
        // headless path reaches it directly). ONE rule set, two enforcers:
        // the validator's own arm calls the same helper, so the two can
        // never disagree about a well-formed composite item.
        case .gitWorktreeReclaim(let plan):
            guard let violation = GitWorktreeReclaimPlan.violation(
                for: item, plan: plan
            ) else { return nil }
            return "refused: \(violation)"
        }
    }

    // MARK: - Pre-delete revalidation seam (fn-4.8, R17/D8)

    /// The UNIFORM fail-closed refusal for an item that carries the
    /// scanner-agnostic `requiresPreDeleteRevalidation` marker while this
    /// cleaner holds NO revalidator for its scanner — a `CacheCleaner` built
    /// directly (bypassing `SpaceScannerRuntime.makeCleaner`), or a scanner
    /// that lost its declaration. `nil` for an unmarked item, and for any
    /// item whose scanner IS registered.
    ///
    /// One helper, two call sites (check (1b) and the chokepoint) so the
    /// refusal can never diverge in wording or in condition.
    private static func missingRevalidatorRefusal(
        for item: ReclaimableItem,
        registry: [String: PreDeleteRevalidator]
    ) -> String? {
        guard item.requiresPreDeleteRevalidation,
              registry[item.scannerID] == nil
        else { return nil }
        return "refused: this item requires a pre-delete revalidation, but "
            + "no revalidator is registered for scanner "
            + "'\(item.scannerID)' — clean it through the runtime that "
            + "registered its scanner"
    }

    /// The chokepoint's revalidation decision for ONE item, with ITS
    /// authorization entry. `nil` means "nothing here stands in the way" —
    /// never a grant (every other gate still applies).
    ///
    /// DISPATCH IS BELT-AND-BRACES. The item's structural
    /// `requiresPreDeleteRevalidation` marker (braces) and the registered
    /// revalidator's own `requiresRevalidation(item:)` predicate (belt) are
    /// OR-ed: a mapping regression that stops setting the marker on an
    /// applicable item is STILL re-probed here — the protection the old
    /// hard-coded gate gave orphaned caches is never lost — and the marker
    /// alone is enough for a scanner whose predicate is narrower.
    ///
    /// The marker is ALSO the uniform FAIL-CLOSED signal: a marked item
    /// whose scanner has NO registry entry (a `CacheCleaner` built directly,
    /// bypassing `SpaceScannerRuntime.makeCleaner`, or a scanner that lost
    /// its declaration) is refused outright. The cleaner never inspects
    /// scanner-specific fields to decide whether revalidation was expected —
    /// the marker subsumes all of that.
    ///
    /// `.proceed` carries the OBJECT BINDING the inspection established (PR
    /// #458 review r7), which the disposal proves the path still names. It is
    /// `.unestablished` — "nothing to bind to" — in exactly three cases, all
    /// of which are the seam's absence rather than a skipped guard: the item's
    /// scanner registered no revalidator; the revalidator declined
    /// applicability; or the revalidator has no object binding to offer.
    ///
    /// `nonisolated` (fn-5.4): it reads only immutable `let` state
    /// (`preDeleteRevalidators`) and runs a pure, synchronous scanner-declared
    /// closure, so the composite performer can call it as a plain function
    /// from its own execution context instead of forcing a hop back onto the
    /// actor mid-deletion.
    private enum PreDeleteOutcome {
        case proceed(inspected: PreDeleteInspectedObject)
        case refuse(
            reason: String, tag: String,
            payload: CleanupReport.ItemError.Refusal?
        )
    }

    nonisolated private func preDeleteOutcome(
        for item: ReclaimableItem, authorization: String?
    ) -> PreDeleteOutcome {
        // DEFENSE IN DEPTH: check (1b) already refused this shape before any
        // state skip could hide it; re-checking here keeps the destructive
        // chokepoint independently fail-closed for any future caller,
        // through the SAME helper so the two can never word it differently.
        if let refusal = Self.missingRevalidatorRefusal(
            for: item, registry: preDeleteRevalidators
        ) {
            // No revalidator ran, so there is no probe and no typed payload —
            // an unrevalidatable item discloses nothing at delete time.
            return .refuse(
                reason: refusal, tag: "revalidator-unavailable", payload: nil
            )
        }
        // NO INSPECTION RAN, AND THIS CALL SITE SAYS SO. Two disjoint
        // populations arrive at `.unestablished` here: items from a scanner
        // that declares no revalidator at all, and items a declared
        // revalidator does not consider applicable (a sweep entry whose
        // classifier declined the clean promise, which reaches a deletion
        // ONLY through conscious per-item confirmation against DISPLAYED
        // caution evidence). Neither has an inspection verdict to bind a
        // disposal to, so neither gets one — the guards they rest on are the
        // container admission, the containment chain, the deny list and the
        // mount doctrine. This is not a way to skip the binding; it is the
        // absence of anything to bind to.
        guard let revalidator = preDeleteRevalidators[item.scannerID]
        else { return .proceed(inspected: .unestablished) }
        guard item.requiresPreDeleteRevalidation
            || revalidator.requiresRevalidation(item: item)
        else { return .proceed(inspected: .unestablished) }

        switch revalidator.revalidate(item: item, authorization: authorization) {
        case .allow(let inspected):
            return .proceed(inspected: inspected)
        case .refuse(let reason, let valuables, let token):
            // The TYPED payload travels with the refusal (fn-4.9): the report's
            // `ItemError` carries it verbatim so `confirmedCleanPayload`
            // serializes `results[].valuables` + `results[].acknowledgement_token`
            // from structured data on BOTH result arms — the row encoder never
            // parses the prose. The REASON stays what the error surface and the
            // log line carry, item-keyed by construction.
            //
            // ONE tag for the whole seam, inherited VERBATIM from the
            // orphaned-caches precedent this generalizes so the cleanup
            // log's grammar gains no new token: the item's delete-time
            // content is not what the deletion decision rests on — it
            // changed since the scan, could not be re-inspected, or was
            // never authorized on the content present NOW.
            return .refuse(
                reason: reason, tag: "content-drift",
                payload: CleanupReport.ItemError.Refusal(
                    valuables: valuables, acknowledgementToken: token
                )
            )
        }
    }

    /// The composite performer's REFUSAL-ONLY view of the seam (fn-5.4 shape,
    /// re-expressed over fn-6's `PreDeleteOutcome`). `nil` means "the seam
    /// raised no objection"; the performer's own gates still apply.
    ///
    /// WHY DISCARDING `inspected` IS FAITHFUL HERE, AND WHERE THAT STOPS BEING
    /// TRUE. The binding exists so a disposal can prove the inode it destroys
    /// against the object a probe inspected. `git_worktrees` registers NO
    /// `preDeleteRevalidator` (GitWorktreeScanner.swift, the
    /// `SpaceScanner` conformance extension) and no worktree item sets
    /// `requiresPreDeleteRevalidation`, so this seam returns
    /// `.proceed(inspected: .unestablished)` for every item that reaches the
    /// performer — there is no binding to carry and none is dropped.
    ///
    /// The `.proceed(inspected:)` arm is therefore matched EXPLICITLY rather
    /// than with a wildcard: if a revalidator is ever registered for this
    /// scanner, an established binding would start arriving here and this
    /// adapter would silently drop it. `assertionFailure` makes that a loud
    /// debug-build failure at the moment it becomes possible, instead of a
    /// quiet loss of the identity proof; release builds still fall through to
    /// the performer's own re-checks — its delete-time gate re-establishment
    /// (R0/R1/R2), the G2 clean re-check before the filesystem fallback, the
    /// oracle recompute in prune mode, and the D13 traversal guard.
    nonisolated private func preDeleteRefusal(
        for item: ReclaimableItem, authorization: String?
    ) -> PreDeleteSeamRefusal? {
        switch preDeleteOutcome(for: item, authorization: authorization) {
        case .refuse(let reason, let tag, let payload):
            return PreDeleteSeamRefusal(
                reason: reason, tag: tag, payload: payload
            )
        case .proceed(.unestablished):
            return nil
        case .proceed(let inspected):
            assertionFailure(
                "the composite performer's seam adapter cannot carry an "
                + "established pre-delete object binding (\(inspected)) into "
                + "the deletion; a revalidator was registered for "
                + "'\(item.scannerID)' without teaching "
                + "WorktreeReclaimPerformer to prove it"
            )
            return nil
        }
    }

    /// The ONE item-error constructor. `refusal` is the ADDITIVE typed payload
    /// (fn-4.9) — nil on every path but a pre-delete revalidation refusal, so
    /// ordinary errors keep their exact as-built shape.
    ///
    /// Internal (fn-5.4) so `WorktreeReclaimPerformer` builds its per-item
    /// errors through the SAME constructor — a second one would be a second
    /// place for the item-keying invariant to rot.
    static func itemError(
        _ item: ReclaimableItem, _ message: String,
        refusal: CleanupReport.ItemError.Refusal? = nil
    ) -> CleanupReport.ItemError {
        CleanupReport.ItemError(
            key: item.key, displayName: item.displayName, message: message,
            refusal: refusal
        )
    }

    // MARK: - Command items (R17)

    private func cleanViaCommands(
        _ commands: [[String]], for item: ReclaimableItem, category: CacheCategory
    ) -> (entry: CleanupReport.Entry?, errors: [CleanupReport.ItemError]) {
        let policy = CategoryAdmissionPolicy(category: category, home: home)

        // EVERY record's `requestedURL` — the FULL scan-time capture, all
        // statuses, not just `.measured` — is re-admitted BEFORE any argv
        // runs, and ANY refusal blocks the ENTIRE command set (fn-1.3 R17
        // parity; no per-root partial execution). A vacuous pass over zero
        // roots is impossible here: `.missing` items skip pre-dispatch and
        // non-missing zero-record items are refused before dispatch.
        for record in item.rootRecords {
            do {
                let admitted = try pathGuard.admitDeletionRoot(
                    record.requestedURL, policy: policy
                )
                logDriftAdmission(admitted, label: item.displayName)
            } catch {
                let reason = "clean commands not run — root refused: \(error.localizedDescription)"
                logRefusal(
                    label: item.displayName, tag: Self.refusalTag(error),
                    detail: "\(record.requestedURL.path): \(reason)"
                )
                return (nil, [Self.itemError(item, reason)])
            }
        }

        // DELETE-TIME SURVIVAL GATE (pre-unification parity): the old
        // cleaner re-ran `resolvedPaths` at delete time, which filtered
        // every root through an exists-as-directory check — a category
        // whose roots ALL vanished (or were renamed) between scan and
        // confirmation resolved to NOTHING and was refused rather than
        // running destructive argv (the PR #454 "no-resolved-root"
        // refusal; think `simctl erase all` after the Simulator root was
        // removed). The captured-record snapshot re-admits the SPELLING,
        // and admission's canonical-components fallback deliberately
        // passes a nonexistent declared path — so existence is its own
        // check, composed AFTER admission, never replacing it. At least
        // one captured root must still exist as a real directory
        // (canonicalized first, so a symlink root pointing at a real
        // directory still counts — `directoryExists` parity). Partial
        // survival proceeds, matching the old semantics where surviving
        // roots resolved and the command set ran.
        let anyCapturedRootSurvives = item.rootRecords.contains { record in
            provider.probeKind(
                of: provider.canonicalize(record.requestedURL)
            ) == .kind(.directory)
        }
        guard anyCapturedRootSurvives else {
            let reason = "clean commands not run — no captured root still exists as a directory at delete time"
            logRefusal(
                label: item.displayName, tag: "no-resolved-root", detail: reason
            )
            return (nil, [Self.itemError(item, reason)])
        }

        do {
            for command in commands {
                try runCleanCommand(command)
            }
        } catch {
            return (nil, [Self.itemError(item, error.localizedDescription)])
        }

        // Nothing measures what a command frees: exact 0, estimated =
        // pre-scan measured size (R16). Disposal is ALWAYS `.permanent`:
        // the argv ran regardless of the Move-to-Trash toggle and placed
        // nothing in the Trash — reporting `.trash` would falsely promise
        // the bytes are recoverable by emptying it.
        logCleanup(label: item.displayName, bytesFreed: item.allocatedBytes)
        guard item.allocatedBytes > 0 else { return (nil, []) }
        return (
            CleanupReport.Entry(
                itemID: item.id, scannerID: item.scannerID,
                displayName: item.displayName,
                exactBytes: 0,
                estimatedUpToBytes: item.allocatedBytes,
                disposal: .permanent
            ),
            []
        )
    }

    // MARK: - Contents mode (.removeContents)

    private func cleanContents(
        of item: ReclaimableItem, category: CacheCategory, moveToTrash: Bool
    ) async -> (entry: CleanupReport.Entry?, errors: [CleanupReport.ItemError]) {
        let policy = CategoryAdmissionPolicy(category: category, home: home)
        // ITEM-LOCAL registry (preserved fn-1 scope): two roots (or two
        // children) of ONE aggregate hardlinking the same inode transfer
        // its bytes once.
        let registry = InodeAccountingRegistry()
        var errors: [CleanupReport.ItemError] = []
        var exact: Int64 = 0
        var estimated: Int64 = 0

        // Scan-time captured records ONLY (root-snapshot rule — never a
        // re-evaluation of `resolvedPaths`), and ONLY `status == .measured`
        // records: `refusedAdmission` and `deniedUnmeasured` are NEVER
        // deletable (frozen truth table); a clean-empty measured root is
        // still processed (a no-op delete). A delete-time refusal of one
        // root reports per-item and leaves the remaining roots cleaning —
        // per-child isolation extends per-root.
        for record in item.rootRecords where record.status == .measured {
            let admitted: AdmittedRoot
            do {
                admitted = try pathGuard.admitDeletionRoot(
                    record.requestedURL, policy: policy
                )
                logDriftAdmission(admitted, label: item.displayName)
            } catch {
                let message = "\(record.requestedURL.path): \(error.localizedDescription)"
                errors.append(Self.itemError(item, message))
                logRefusal(
                    label: item.displayName, tag: Self.refusalTag(error),
                    detail: message
                )
                continue
            }

            // A measured root that VANISHED since the scan has nothing to
            // enumerate — the root-level counterpart of the child ENOENT
            // skip below (and parity with the pre-snapshot behavior, where
            // a vanished root simply no longer resolved).
            if provider.probeKind(of: admitted.requestedURL) == .absent {
                continue
            }

            // WHICH FOLDER ARE THESE CHILDREN CHILDREN OF (PR #458 review —
            // the P1). Every child deleted below is opened by the removal
            // through THIS directory's path, on the far side of a queue hop,
            // and contents mode has no leaf binding at all (no probe runs
            // here), so a `rename(2)` pair at that seam pointed the whole
            // per-child loop into a stranger's directory with SUCCESS
            // reported. The identity is read from a descriptor ONCE per root
            // — before the enumeration, so the names the loop works from and
            // the folder they are unlinked out of are the same folder.
            let admittedParent: DepthSafeRemoval.AdmittedParent
            do {
                admittedParent = try DepthSafeRemoval.admittedParent(
                    directory: admitted.requestedURL,
                    displayPath: admitted.requestedURL.path,
                    provider: provider
                )
            } catch {
                errors.append(Self.itemError(item, error.localizedDescription))
                continue
            }

            // Enumerate children under the UNRESOLVED spelling — deletion
            // must remove exactly what sits at the requested location, and a
            // symlink child must be removed AS a link (R4). Containment
            // checks compare against the resolved spelling inside the guard.
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: admitted.requestedURL, includingPropertiesForKeys: nil
                )
            } catch {
                errors.append(Self.itemError(item, error.localizedDescription))
                continue
            }

            for child in children {
                switch await deleteGuardedChild(
                    child, of: admitted, containedIn: admittedParent,
                    registry: registry,
                    moveToTrash: moveToTrash, label: item.displayName
                ) {
                case .accepted(let components):
                    exact += components.exactBytes
                    estimated += components.estimatedUpToBytes
                case .skippedAlreadyGone:
                    break
                case .failed(let message):
                    errors.append(Self.itemError(item, message))
                }
            }
        }

        logCleanup(label: item.displayName, bytesFreed: exact + estimated)
        // A partially-refused/failed item still yields ONE entry carrying
        // the per-child accounting that actually succeeded (R1); a
        // zero-byte outcome yields none (as-built no-entry behavior).
        guard exact + estimated > 0 else { return (nil, errors) }
        return (
            CleanupReport.Entry(
                itemID: item.id, scannerID: item.scannerID,
                displayName: item.displayName,
                exactBytes: exact, estimatedUpToBytes: estimated,
                disposal: moveToTrash ? .trash : .permanent
            ),
            errors
        )
    }

    private enum ChildOutcome {
        case accepted(AcceptedByteComponents)
        case skippedAlreadyGone
        case failed(String)
    }

    /// The guarded per-child pipeline: validate → probe → measure → register
    /// → re-validate → delete → accept. Per-child error isolation (R10): any
    /// failure is returned, never thrown.
    private func deleteGuardedChild(
        _ child: URL, of root: AdmittedRoot,
        containedIn admittedParent: DepthSafeRemoval.AdmittedParent,
        registry: InodeAccountingRegistry,
        moveToTrash: Bool, label: String
    ) async -> ChildOutcome {
        // Strict-descendant containment against the admitted root. NOTE:
        // `validateContainedChild` is descendant-only by design (fn-1.1) —
        // cross-device refusal and the deny-list re-check live in item mode
        // (`validateRemovableItem`); a foreign-device subtree under a
        // category root is still never ENTERED by the sizer (mount
        // boundaries), and the root itself was deny-checked at admission.
        do {
            try pathGuard.validateContainedChild(child, of: root)
        } catch {
            logRefusal(
                label: label, tag: Self.refusalTag(error),
                detail: "\(child.path): \(error.localizedDescription)"
            )
            return .failed(error.localizedDescription)
        }

        // Already gone = skip. Decided by OUR probe: an absent leaf yields an
        // EMPTY SizeReport indistinguishable from an empty directory, so
        // "already gone" must never be inferred from the report.
        if provider.probeKind(of: child) == .absent {
            return .skippedAlreadyGone
        }

        // Measure → register (Phase 1) BEFORE deletion. Known inodes
        // contribute zero local bytes but still claim, so a failed sibling's
        // canonical bytes stay transferable by whoever succeeds later (R8).
        let report = sizer.measure(
            at: child, mode: .deletionTarget,
            knownInodes: await registry.knownIdentities
        )

        // ANY mount boundary in the measured tree — the child itself, or a
        // mounted subtree nested anywhere beneath it — refuses the deletion.
        // The sizer records-and-skips boundaries for SIZING, but `removeItem`
        // would recurse straight through an inner mount; refusal is the
        // epic's mount doctrine (R15). `validateContainedChild` is
        // descendant-only by design, so this is where the rule lands for
        // category children.
        if let boundary = report.mountBoundaries.first {
            let detail = "\(child.path): mount boundary at \(boundary.path) — refused, not deleted"
            logRefusal(label: label, tag: "mount_boundary", detail: detail)
            return .failed(detail)
        }

        let token = await registry.registerObservations(report.claims)

        do {
            // TOCTOU narrowing: re-validate the parent chain immediately
            // before the destructive call.
            try pathGuard.validateContainedChild(child, of: root)
            if moveToTrash {
                // A trash failure is a child error — it never falls through
                // to a permanent delete (R11).
                //
                // NO INSPECTION VERDICT TO BIND TO, WHICH IS WHY THE
                // CONTAINER BINDING IS NOT OPTIONAL HERE EITHER (PR #458
                // review — the P1 the permanent-arm rounds left open). The
                // note that stood here justified handing a BARE URL to the
                // mover with a fact about the LEAF: contents mode runs no
                // user-data probe, so there is no inspected object. True, and
                // beside the point — the very next branch was already
                // carrying `admittedParent` for exactly this absence, and
                // this branch ignored it. Measured with two real `rename(2)`s
                // at the seam: the stranger's identically-named child went to
                // the Trash and its bytes were reported as freed.
                //
                // So this arm binds what it HAS. `TrashDisposal` proves the
                // container, binds the child under that descriptor, and
                // proves what the disposal actually took on the far side of
                // a call it cannot be given a descriptor for.
                try await TrashDisposal.dispose(
                    child, containedIn: admittedParent, provider: provider,
                    via: { try await self.trash($0, provingImmediatelyBefore: $1) }
                )
            } else {
                // NO INSPECTION VERDICT TO BIND TO, and the call site says
                // so. Contents mode runs no user-data probe (only the
                // orphaned-caches sweep carries a clean promise), so there
                // is no inspected object here — which is precisely why the
                // CONTAINER binding below is not optional for this arm: with
                // `expecting: nil` there is nothing else that can notice the
                // folder these children were enumerated from being swapped.
                try await Self.removeItemConcurrently(
                    at: child, expecting: nil, provider: provider,
                    containedIn: admittedParent
                )
            }
        } catch {
            if error is PathGuardError {
                logRefusal(
                    label: label, tag: Self.refusalTag(error),
                    detail: "\(child.path): \(error.localizedDescription)"
                )
            } else if let failure = error as? DepthSafeRemoval.Failure,
                      failure.cause == .notTheAdmittedContainer {
                // The category root these children were enumerated from was
                // replaced under the loop. Same tag item mode uses for the
                // same event, so the cleanup log has ONE word for it.
                logRefusal(
                    label: label, tag: "container-drift",
                    detail: "\(child.path): \(error.localizedDescription)"
                )
            } else if error is TrashDisposal.Failure {
                // The swap landed inside `trashItem`'s own resolution, so it
                // was caught AFTER the move and undone. Same event as the one
                // above, one disposal over — and the same tag item mode uses
                // for it.
                logRefusal(
                    label: label, tag: "content-drift",
                    detail: "\(child.path): \(error.localizedDescription)"
                )
            }
            // Failed deletions never accept — their registrations remain for
            // siblings to transfer later (R8).
            return .failed(error.localizedDescription)
        }

        // Phase 2: transfer canonical bytes exactly once, after success only.
        return .accepted(await registry.acceptSuccessful(token))
    }

    // MARK: - Item mode (.removeItem, R15)

    /// Does `target` STILL name the object the pre-delete probe inspected?
    ///
    /// One no-follow `lstat`, asked as late as the path-based deletion API
    /// allows. It can only REFUSE — never widen admission — and it is
    /// deliberately asked of the UNRESOLVED target spelling, which is the
    /// one `removeItem` will act on.
    ///
    /// LAYER TWO, AND SAID SO IN SOURCE (PR #458 review — the P1).
    ///
    /// The note that used to stand here called the window between this
    /// `lstat` and the deletion syscall "irreducible for as long as the
    /// deletion takes a path". BOTH HALVES WERE WRONG. The window was
    /// measured through the production cleaner — from this `lstat` to the
    /// deletion's first question about a descriptor, an under-estimate —
    /// at 0.095 / 0.097 / 0.126 ms over three runs, because
    /// `removeItemConcurrently` hops to `DispatchQueue.global` inside it:
    /// not a syscall's width but an eternity for a `rename(2)` + `mkdir(2)`
    /// loop. And the deletion had already stopped taking a path. It HOLDS A
    /// DESCRIPTOR and simply never asked it who it was. It does now
    /// (`DepthSafeRemoval.proveInspectedRoot`), so the load-bearing proof is
    /// there, on the opened inode, past every window this method has.
    ///
    /// WHY THIS CHECK STAYS ANYWAY, honestly labelled: it is the arm that
    /// refuses on an UNREADABLE target (`.failed`), where the removal would
    /// only produce a raw errno; it refuses before the sweep spends a queue
    /// hop; and it produces the sentence users act on. It is NOT what makes
    /// the swap case safe. Its partner carries that, and the partner's
    /// failing test is
    /// `testTargetReplacedAfterTheFinalPathCheckIsRefused` — the fixture
    /// that wins the race against this very `lstat`. Deleting this method's
    /// body leaves that test GREEN; deleting the descriptor proof does not.
    /// (Same disclosure discipline as the entry-budget guard in
    /// `OrphanedCachesScanner.boundedUserDataShapeWalk`.)
    private func probedObjectStillAtTarget(
        _ inspected: UserDataProbeResult.InspectedRoot, target: URL
    ) -> Bool {
        switch inspected {
        case .directory(let identity):
            return provider.identity(of: target) == identity
        case .nonDirectoryLeaf(let identity):
            // Same comparison as the `.directory` arm — `identity(of:)` is
            // an `lstat`, so a symlink compares as the LINK — and, like the
            // whole method, this is the cheap early refusal, NOT the proof:
            // the load-bearing bindings are the removal's `fstatat` under
            // the proved parent and `TrashDisposal`'s two-sided leaf
            // binding. `nil` (absent/unreadable) is not a match; the
            // disposal's own arms produce the item-keyed error.
            return provider.identity(of: target) == identity
        case .noDirectoryTree:
            // The clean verdict rested on there being no directory TREE of
            // ours at that name (absent, symlink, regular file, special) —
            // deletion removes the leaf as-is. A directory standing there
            // now is a tree the probe never opened.
            //
            // `probeKind`, NOT `kind` (PR #458 review r8). `kind(of:)`
            // collapses "absent" and "`lstat` failed" onto `nil`, so
            // `kind(of:) != .directory` was TRUE for an EACCES or EIO
            // `lstat` — this arm ADMITTED the deletion on a target it could
            // not read, while the `.directory` arm below fails closed on
            // exactly the same nil. Same site, opposite directions.
            switch provider.probeKind(of: target) {
            case .absent:
                // Still nothing there: the verdict holds precisely.
                return true
            case .kind(let kind):
                return kind != .directory
            case .failed:
                // We cannot tell what is standing there. Unverifiable ⇒
                // refuse — and CLEARABLE: a re-scan of a readable target
                // proceeds normally.
                return false
            }
        case .unestablished:
            // No verdict to bind to. Unreachable — an incomplete probe has
            // already refused above — so fail closed rather than assume.
            return false
        }
    }

    /// One `.removeItem` deletion. `origin` is the item's CLAIMED container
    /// — validated by `admitContainer` against the CONSTRUCTOR-injected
    /// container roots (the runtime's scanner-declared union; a buggy or
    /// hostile item cannot widen admission). `target` is the FROZEN
    /// descriptor's UNRESOLVED `requestedTargetURL` (leaf never resolved —
    /// `item.url` is display state and never a destructive input). The
    /// registry is the caller's per-SCANNER instance. `authorization` is
    /// THIS item's entry from the per-clean authorization context (fn-4.8).
    private func removeGuardedItem(
        _ item: ReclaimableItem, origin: URL, target: URL,
        registry: InodeAccountingRegistry, moveToTrash: Bool,
        authorization: String?
    ) async -> (entry: CleanupReport.Entry?, errors: [CleanupReport.ItemError]) {
        // The scan-session snapshot is the delete-time identity anchor
        // (fn-3.4, R9). A cleaner built WITHOUT one refuses fail-closed:
        // the deletion-capable token is structurally unmintable without a
        // snapshot-bound admission, and this refusal is the runtime face
        // of that type-level rule.
        guard let snapshot = containerSnapshot else {
            let error = PathGuardError.containerUnavailable(path: origin.path)
            let detail = "\(target.path): \(error.localizedDescription) "
                + "(no scan-session container snapshot — items must be "
                + "cleaned with the session that produced them)"
            logRefusal(
                label: item.displayName, tag: Self.refusalTag(error),
                detail: detail
            )
            return (nil, [Self.itemError(item, detail)])
        }

        let container: AdmittedContainer
        do {
            container = try pathGuard.admitContainer(origin, snapshot: snapshot)
            try pathGuard.validateRemovableItem(target, inside: container)
        } catch {
            logRefusal(
                label: item.displayName, tag: Self.refusalTag(error),
                detail: "\(target.path): \(error.localizedDescription)"
            )
            return (nil, [Self.itemError(item, error.localizedDescription)])
        }

        // Deliberately NO already-gone skip here (the frozen ENOENT
        // asymmetry): a missing ("ghost") target surfaces as an ITEM-KEYED
        // error — its absent leaf measures as an empty report and the
        // deletion below reports the ENOENT. The ENOENT skip exists ONLY
        // for category children in contents mode.
        let report = sizer.measure(
            at: target, mode: .deletionTarget,
            knownInodes: await registry.knownIdentities
        )

        // Same mount doctrine as category children (R15): a boundary
        // anywhere in the measured tree refuses the deletion —
        // `validateRemovableItem` catches the target ITSELF being a mount
        // point, but not a mount nested beneath it.
        if let boundary = report.mountBoundaries.first {
            let detail = "\(target.path): mount boundary at \(boundary.path) — refused, not deleted"
            logRefusal(label: item.displayName, tag: "mount_boundary", detail: detail)
            return (nil, [Self.itemError(item, detail)])
        }

        // DELETE-TIME REVALIDATION SEAM (fn-4.8, R17/D8 — #457's
        // generalization of the hard-coded orphaned-caches gate that stood
        // here — carrying #458's OBJECT BINDING through it).
        //
        // Why anything runs here at all: the snapshot admission above binds
        // the CONTAINER's identity, not the target's CONTENTS — a sweep
        // entry removed and recreated at the same name, or a DMG written
        // into a build directory mid-build, passes every check so far while
        // holding content the scan never inspected. The scanner that owns
        // the probe declares a `PreDeleteRevalidator`; the runtime captures
        // it at REGISTRATION; the cleaner runs it HERE, at the one
        // chokepoint, immediately pre-delete — after admission, containment
        // and mount-boundary checks (a revalidator must never inspect a
        // path this cleaner would refuse to touch) and before any deletion.
        //
        // Direction-safe by construction: a revalidation can only REFUSE,
        // never widen admission. An item of a scanner with no revalidator,
        // unmarked and deemed inapplicable, behaves exactly as it did
        // before this seam existed.
        //
        // WHAT THE PROBE'S VERDICT IS ABOUT, CARRIED TO THE DISPOSAL ITSELF
        // (PR #458 review r7). The verdict is a fact about an OBJECT — the
        // probe held a descriptor — while every gate above is a fact about a
        // PATH that a replacement at the same name satisfies. So the object
        // travels out of the seam and into the deletion, where it is proved
        // against the inode the removal opens.
        //
        // `let`, WITH BOTH ARMS WRITTEN OUT (PR #458 review — the doc claim
        // that was false). `remove(at:expecting:)` documents `nil` as
        // something a call site STATES; contents mode states it with a
        // literal and a paragraph, while this call site used to let an
        // implicitly-nil `var` fall through the `if` and reach the deletion
        // having said nothing at all. A default is exactly what the parameter
        // must not have, so item mode says its `nil` too — here, by mapping
        // the seam's `.unestablished` ("nothing to bind to", see
        // `preDeleteOutcome`) onto it.
        let probedObject: UserDataProbeResult.InspectedRoot?
        switch preDeleteOutcome(for: item, authorization: authorization) {
        case .refuse(let reason, let tag, let payload):
            logRefusal(label: item.displayName, tag: tag, detail: reason)
            return (nil, [Self.itemError(item, reason, refusal: payload)])
        case .proceed(let inspected):
            probedObject = inspected == .unestablished ? nil : inspected
        }

        let token = await registry.registerObservations(report.claims)

        do {
            // WHICH FOLDER HOLDS THIS ITEM — READ FROM A DESCRIPTOR, HERE,
            // ON THIS SIDE OF THE QUEUE HOP (PR #458 review — the P1).
            //
            // The deletion resolves exactly one path, the target's parent,
            // and it resolves it after `removeItemConcurrently` hops to a
            // background queue — measured at 0.095 / 0.097 / 0.126 ms, which
            // is an eternity for a `rename(2)` + `mkdir(2)` pair. Nothing
            // else here binds that folder: `admitContainer` binds the
            // CONTAINER ROOT to the session snapshot, and a target is a
            // strict DESCENDANT of it, so for the ordinary
            // `<dev-root>/proj/node_modules` shape the directory the deletion
            // actually opens (`proj`) is bound by nothing at all.
            //
            // Taken FIRST, before the rechecks below, because everything
            // after the capture is what the binding covers; taken last it
            // would cover only the hop. It fails closed and costs nothing to
            // do so — the removal performs the identical open a moment later,
            // so an open that fails here would have failed there.
            let admittedParent = try DepthSafeRemoval.admittedParent(
                directory: target.deletingLastPathComponent(),
                displayPath: target.path, provider: provider
            )
            // TOCTOU narrowing, immediately pre-delete: the SAME no-follow
            // + snapshot-identity admission re-runs (a container swapped
            // between the checks above and here is refused), then the
            // containment chain re-validates.
            let recheck = try pathGuard.admitContainer(origin, snapshot: snapshot)
            try pathGuard.validateRemovableItem(target, inside: recheck)
            // THE PROBE'S BINDING, FIRST PASS — A PATH CHECK, WHICH IS NOT
            // THE PROOF (PR #458 review — the P1).
            //
            // The comment that stood here claimed "detecting the swap and
            // then deleting by path anyway is structurally impossible". It
            // was false: the deletion carried on by path, this check was the
            // last thing between the sweep and a replacement directory, and
            // a fixture that wins the race against this one `lstat` deleted
            // a `Photos Library.photoslibrary` the app never opened while
            // reporting SUCCESS and the OTHER tree's byte count.
            //
            // What is true: the probe holds a DESCRIPTOR, so its verdict is
            // a fact about an OBJECT, while every check above — container
            // admission, containment, deny list, mount — is a fact about a
            // PATH that a replacement at the same name satisfies. Which is
            // why the verdict now travels INTO the deletion
            // (`expecting:` below) and is proved there against the inode it
            // opens. This check is the earlier, cheaper, better-worded
            // refusal; it is not the one that closes the window.
            if let probedObject,
               !probedObjectStillAtTarget(probedObject, target: target) {
                let detail = "\(target.path): the folder at this path is no "
                    + "longer the one that was inspected — it was replaced "
                    + "between the safety check and the deletion; refused, "
                    + "re-scan required"
                logRefusal(label: item.displayName, tag: "content-drift",
                           detail: detail)
                return (nil, [Self.itemError(item, detail)])
            }
            if moveToTrash {
                // A trash failure is an item error — it never falls through
                // to a permanent delete (R11).
                //
                // AND THE VERDICT GOES HERE TOO (PR #458 review — the P1's
                // other half). This is the GUI's DEFAULT disposal
                // (`CacheoutViewModel.moveToTrash = true`), so it is the path
                // most deletions actually take; before this it ran behind
                // nothing but the `lstat` above, which is the layer the swap
                // fixture beats by one syscall. `trashItem` cannot be handed a
                // descriptor, so `TrashDisposal` proves the object on BOTH
                // sides of it and undoes a disposal it cannot prove — see that
                // file for the window that remains and its measurement.
                if let probedObject {
                    try await TrashDisposal.dispose(
                        target, expecting: probedObject, provider: provider,
                        containedIn: admittedParent,
                        via: { try await self.trash($0, provingImmediatelyBefore: $1) }
                    )
                } else {
                    // NO LEAF VERDICT — WHICH IS NOT THE SAME AS NOTHING TO
                    // BIND (PR #458 review — the P1 that survived three
                    // rounds). The note that stood here justified handing a
                    // bare URL to the mover with a fact about the ROLLBACK:
                    // "`admittedParent` is not used here on purpose: this arm
                    // never rolls anything back, so there is no destination to
                    // prove." That reasoned about the wrong object. The
                    // question is not what the UNDO would restore into, it is
                    // which folder the DISPOSAL resolves the target's name
                    // in — and `admittedParent`, captured a few lines up from
                    // a descriptor, answers exactly that. Measured with two
                    // real `rename(2)`s at the seam, `moveToTrash: true`: the
                    // stranger's tree went to the Trash and the report read
                    // `entries=[exactBytes: 4096, .trash]`, `errors=[]`.
                    //
                    // So the container binding goes here too, and the
                    // disposal binds the leaf under it. Once it does, this arm
                    // rolls back like the other one — which is the second
                    // reason the old note was wrong about itself.
                    try await TrashDisposal.dispose(
                        target, containedIn: admittedParent,
                        provider: provider,
                        via: { try await self.trash($0, provingImmediatelyBefore: $1) }
                    )
                }
            } else {
                // Item mode deletes the target ITSELF — never its
                // contents-with-parent-preserved (R1/R15). The UNRESOLVED
                // spelling: a symlink target is removed AS a link (R4).
                //
                // AND THE VERDICT GOES WITH IT. This is where the binding
                // actually lands: the removal opens the target and proves
                // the OPENED INODE is `probedObject` before it unlinks
                // anything.
                try await Self.removeItemConcurrently(
                    at: target, expecting: probedObject, provider: provider,
                    containedIn: admittedParent
                )
            }
        } catch {
            if error is PathGuardError {
                logRefusal(
                    label: item.displayName, tag: Self.refusalTag(error),
                    detail: "\(target.path): \(error.localizedDescription)"
                )
            } else if let failure = error as? DepthSafeRemoval.Failure,
                      failure.cause == .notTheInspectedObject {
                // The SAME event as the path check above — same tag, so the
                // log does not report a swap caught one layer down as
                // something else entirely.
                logRefusal(
                    label: item.displayName, tag: "content-drift",
                    detail: "\(target.path): \(error.localizedDescription)"
                )
            } else if let failure = error as? DepthSafeRemoval.Failure,
                      failure.cause == .notTheAdmittedContainer {
                // A DIFFERENT EVENT, SO A DIFFERENT TAG. `content-drift` says
                // the item changed; this says the item is where it always was
                // and the FOLDER THAT HOLDS IT was replaced — which is what
                // the user has to go and look at, and which the cleanup log
                // must not blur into the other.
                logRefusal(
                    label: item.displayName, tag: "container-drift",
                    detail: "\(target.path): \(error.localizedDescription)"
                )
            } else if error is TrashDisposal.Failure {
                // Same event again, one disposal over: a swap the Trash arm
                // caught (before its move, or after it and undone) is the same
                // thing happening to the user as one the permanent arm caught.
                logRefusal(
                    label: item.displayName, tag: "content-drift",
                    detail: "\(target.path): \(error.localizedDescription)"
                )
            }
            // Failed deletions never accept: `token` is abandoned, no entry
            // is produced, and no bytes are reported.
            return (nil, [Self.itemError(item, error.localizedDescription)])
        }

        let accepted = await registry.acceptSuccessful(token)
        logCleanup(
            label: "\(item.scannerID)/\(item.displayName)",
            bytesFreed: accepted.exactBytes + accepted.estimatedUpToBytes
        )
        return (
            CleanupReport.Entry(
                itemID: item.id, scannerID: item.scannerID,
                displayName: item.displayName,
                exactBytes: accepted.exactBytes,
                estimatedUpToBytes: accepted.estimatedUpToBytes,
                disposal: moveToTrash ? .trash : .permanent
            ),
            []
        )
    }

    // MARK: - Composite item mode (.gitWorktreeReclaim, fn-5.4)

    /// Build the composite performer for ONE item, handing it this cleaner's
    /// own primitives: the guard, the sizer, the trash seam, the deletion
    /// primitive, the cleanup log, and the pre-delete revalidator seam bound
    /// to THIS item's authorization entry.
    ///
    /// A factory rather than a stored property because three of the seams are
    /// per-item or per-run (`moveToTrash`, the item's label, its
    /// authorization) — and because the performer must be unbuildable without
    /// the runner and the session snapshot, which the dispatch arm has just
    /// proven present.
    private func makePerformer(
        for item: ReclaimableItem,
        runner: any GitCommandRunning,
        snapshot: ContainerSnapshot,
        moveToTrash: Bool,
        authorization: String?
    ) -> WorktreeReclaimPerformer {
        let sizer = self.sizer
        // The removal seam now needs the provider (it proves the folder it
        // opens), and the closure must not capture `self`.
        let provider = self.provider
        let handler = self.trashHandler
        let label = item.displayName
        return WorktreeReclaimPerformer(
            pathGuard: pathGuard,
            provider: provider,
            snapshot: snapshot,
            runner: runner,
            mapper: GitWorktreeAdminMapper(identity: provider),
            measure: { url, mode, knownInodes in
                sizer.measure(at: url, mode: mode, knownInodes: knownInodes)
            },
            gitTimeout: gitTimeout,
            moveToTrash: moveToTrash,
            // THE RAW MOVER, AND THE LANDING URL IT ANSWERS WITH. The
            // performer never calls it directly — it goes through
            // `TrashDisposal.dispose(_:containedIn:provider:via:)`, the same
            // no-leaf-verdict overload the item and contents arms above use,
            // against the container binding the performer captures before its
            // rechecks.
            // THE PROOF CROSSES THE HOP WITH IT (PR #460 codex r6, D1) —
            // `TrashDisposal.Mover`'s contract, and the reason this seam takes
            // two arguments. `trashItem` requires the main actor; the
            // performer's last-instant re-proof and the disposal's leaf
            // binding both run on THIS side of that hop, so before this the
            // interval between them and the move was the main thread's queue
            // depth (MEASURED, n=5, under 120 ms main-thread work items:
            // median 175.736 ms then, 0.004 ms now — see
            // `testTheTrashProofAndTheMoveAreNotSeparatedByTheMainThreadQueue`
            // for the command and the full samples).
            trash: { url, prove in
                try await MainActor.run {
                    try prove()
                    return try handler(url)
                }
            },
            removeTree: { url, admittedParent in
                // `expecting: nil` is STATED, not defaulted (fn-6's item path
                // states its own the same way): `git_worktrees` registers no
                // `preDeleteRevalidator`, so this deletion has no leaf verdict
                // to prove — the binding it does carry is the CONTAINER one
                // the performer captured before its rechecks.
                try await Self.removeItemConcurrently(
                    at: url, expecting: nil, provider: provider,
                    containedIn: admittedParent
                )
            },
            revalidate: { [self] subject in
                preDeleteRefusal(for: subject, authorization: authorization)
            },
            logRefusal: { [self] tag, detail in
                logRefusal(label: label, tag: tag, detail: detail)
            },
            logCleaned: { [self] bytesFreed in
                logCleanup(
                    label: "\(item.scannerID)/\(label)", bytesFreed: bytesFreed
                )
            }
        )
    }

    // MARK: - Refusal classification

    /// Stable log tag for a refusal — switched over the TYPED
    /// `PathGuardError` cases, never derived from message strings. Internal
    /// (fn-5.4) so the composite performer classifies its own PathGuard
    /// refusals through the same switch.
    static func refusalTag(_ error: Error) -> String {
        guard let guardError = error as? PathGuardError else { return "error" }
        switch guardError {
        case .deniedFilesystemRoot: return "filesystem-root"
        case .deniedVolumeRoot: return "volume-root"
        case .deniedHomeDirectory: return "home-directory"
        case .deniedProtectedChild: return "protected-child"
        case .outsideCategoryPolicy: return "outside-policy"
        case .notAConfiguredContainer: return "not-a-container"
        case .isRootItself: return "root-itself"
        case .notADescendant: return "not-a-descendant"
        case .crossDevice: return "cross-device"
        case .containerUnavailable: return "container-unavailable"
        case .notATraversableDirectory: return "not-a-traversable-directory"
        }
    }

    /// Human-readable reason a `.denied` item was refused — classified off
    /// the typed `ScanError.Kind`, never by matching message strings.
    private static func deniedRefusalReason(for scanError: ScanError?) -> String {
        let label: String
        switch scanError?.kind {
        case .admissionRefused: label = "admission refused at scan time"
        case .tccDenied: label = "macOS privacy (TCC) denial"
        case .permissionDenied: label = "permission denial"
        case .other: label = "scan failure"
        case nil: label = "no measurable access"
        }
        var reason = "refused: the scan could not measure this item (\(label))"
        if let message = scanError?.message, !message.isEmpty {
            reason += " — \(message)"
        }
        return reason
    }

    // MARK: - Deletion primitives

    /// Run a custom clean command via /usr/bin/env with a 30-second timeout.
    private func runCleanCommand(_ args: [String]) throws {
        guard !args.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // HOME anchors to the same injected home as discovery, admission,
        // and logging — a command that consults $HOME must see the fixture
        // home in tests, never the real account (mirrors the probe
        // environment in `CacheCategory`).
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin",
            "HOME": home.path
        ]

        try process.run()

        // Bounded poll — NEVER `waitUntilExit()` observed from a helper
        // thread (the previous DispatchGroup pattern): `waitUntilExit` can
        // miss its termination wakeup under concurrent process
        // spawning/reaping (see `Process.waitForExit(within:)`), so a
        // trivially-successful command was misreported as timed out after
        // the full 30s — and the helper thread stayed blocked forever.
        // Timeout contract unchanged: 30 seconds, `terminate()` on expiry,
        // same error text, then the exit-status check.
        guard process.waitForExit(within: 30) else {
            process.terminate()
            throw NSError(domain: "CacheCleaner", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Clean command timed out after 30s"])
        }

        guard process.terminationStatus == 0 else {
            throw NSError(domain: "CacheCleaner", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Clean command exited with status \(process.terminationStatus)"])
        }
    }

    /// Synchronous disk I/O offloaded to a GCD background queue so the actor
    /// (and the cooperative thread pool) never blocks on a large unlink.
    ///
    /// THE DELETION IS DESCRIPTOR-RELATIVE, and that is the fix rather than a
    /// detail (PR #458 review — the stranding class that MOVED). Inspection
    /// went descriptor-relative and could then read trees past `PATH_MAX`;
    /// `FileManager.removeItem(at:)` composes an absolute path per entry and
    /// cannot, so the codebase began producing items that were probed CLEAN
    /// and COMPLETE and were nonetheless undeletable forever — measured,
    /// NSCocoaErrorDomain 514 / ENAMETOOLONG, in 0.03 s, every time, with a
    /// message blaming an "invalid file name". Both halves of one core now
    /// traverse the same way, so neither can address a tree the other
    /// cannot: `DepthSafeRemoval` reaches exactly what the probe reaches.
    ///
    /// AND THE HOP IS WHY THE INSPECTION VERDICT TRAVELS WITH IT (PR #458
    /// review — the P1). `expecting` is not plumbing: this queue hop sits
    /// between the caller's last path check and the deletion, and it is not
    /// a syscall wide. Measured through this method, from the last
    /// `identity(of: target)` to the deletion's first question about a
    /// DESCRIPTOR — which is already past `open(parent)` and `openat(leaf)`,
    /// so it under-states the window — 0.095 / 0.097 / 0.126 ms over three
    /// runs before the fix, at the seam
    /// `testTargetReplacedAfterTheFinalPathCheckIsRefused` still prints.
    /// That is an eternity for a `rename(2)` + `mkdir(2)` loop, and it is
    /// where the deletion used to acquire a descriptor it never asked the
    /// identity of.
    ///
    /// AND SO DOES THE CONTAINER BINDING (PR #458 review — the P1 the round
    /// that built `containedIn:` left at zero call sites). The deletion's ONE
    /// path resolution is the target's parent, and it happens on the far side
    /// of this hop: a `rename(2)` pair inside those 0.095–0.126 ms puts a
    /// stranger's directory at that path, after which every
    /// descriptor-relative proof below is self-consistent INSIDE THE
    /// STRANGER. `containedIn` is the identity the caller read from a
    /// descriptor on THIS side, and it has no default here either — the hop
    /// is the whole reason the parameter exists, so a caller that reaches it
    /// without stating a binding must not compile.
    nonisolated private static func removeItemConcurrently(
        at url: URL,
        expecting inspected: UserDataProbeResult.InspectedRoot?,
        provider: FileSystemIdentityProvider,
        containedIn admittedParent: DepthSafeRemoval.AdmittedParent
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try DepthSafeRemoval.remove(
                        at: url, expecting: inspected, provider: provider,
                        containedIn: admittedParent
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Move one URL to the Trash via the injectable seam (production:
    /// `FileManager.trashItem`, which requires the main actor), answering
    /// WHERE IT LANDED — `nil` when the disposal would not say.
    @discardableResult
    private func trash(
        _ url: URL, provingImmediatelyBefore prove: () throws -> Void
    ) async throws -> URL? {
        let handler = trashHandler
        // THE PROOF RIDES ACROSS THE HOP (PR #460 codex r6, D1). `trashItem`
        // requires the main actor, so every caller's last proof used to be
        // separated from the move by the MAIN THREAD'S QUEUE DEPTH — MEASURED
        // through the production composition with 120 ms work items held on
        // the main thread, median 175.736 ms between the last pre-move
        // `probeChild` and the mover (n=5), against 0.004 ms with the proof
        // placed here. `TrashDisposal.Mover` is the contract: run `prove()` on the
        // far side of the hop, immediately before the move, and move nothing
        // if it throws.
        return try await MainActor.run {
            try prove()
            return try handler(url)
        }
    }

    // MARK: - Logging

    /// The log helpers are `nonisolated` (fn-5.4): they read only the
    /// immutable injected `home` and append to a file under it, so the
    /// composite performer can log from its own execution context without an
    /// actor hop mid-deletion. Every existing isolated caller is unchanged.
    nonisolated private func logCleanup(label: String, bytesFreed: Int64) {
        let size = ByteCountFormatter.sharedFile.string(fromByteCount: bytesFreed)
        appendLog("Cleaned \(label): \(size)")
    }

    nonisolated private func logRefusal(label: String, tag: String, detail: String) {
        appendLog("REFUSED [\(tag)] \(label): \(detail)")
    }

    /// A version-drift sibling admission is legitimate but noteworthy — log
    /// which declared root vouched for it.
    nonisolated private func logDriftAdmission(_ admitted: AdmittedRoot, label: String) {
        guard admitted.viaSiblingDrift else { return }
        appendLog(
            "ADMITTED [version-drift] \(label): \(admitted.resolvedURL.path)"
            + " (declared: \(admitted.matchedDeclaredRoot.path))"
        )
    }

    nonisolated private func appendLog(_ message: String) {
        let logDir = home.appendingPathComponent(".cacheout")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let dirFd = logDir.withUnsafeFileSystemRepresentation { pathPtr -> Int32 in
            guard let pathPtr = pathPtr else { return -1 }
            return open(pathPtr, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
        }
        guard dirFd >= 0 else { return }
        defer { close(dirFd) }
        guard fchmod(dirFd, 0o700) == 0 else { return }

        let entry = "[\(ISO8601DateFormatter.shared.string(from: Date()))] \(message)\n"

        // THIS OPEN CANNOT CARRY `O_DIRECTORY` — it creates a regular file —
        // so it is the WRITE-SIDE twin of the scanner's lock-probe hazard
        // (PR #459 review r4, the third blocking-open site): `O_WRONLY` on a
        // FIFO planted at this name blocks until a READER appears. Measured
        // on this platform: the identical flag set without `O_NONBLOCK` did
        // not return in 2s against `mkfifo`; every admission and refusal of a
        // clean logs through here inside this actor, so that block wedges the
        // clean and every later message to the actor. `O_NONBLOCK` splits the
        // FIFO into two measured halves, and the flag alone covers only one:
        //   - no reader: the open fails ENXIO, the `fd != -1` guard drops the
        //     line — best-effort by design, like every earlier silent return
        //     in this method;
        //   - a reader present: the open SUCCEEDS (`fstat` reports `S_IFIFO`),
        //     so without the kind gate below the log would stream into
        //     someone else's pipe.
        // A bound AF_UNIX socket never gets this far (the open fails
        // EOPNOTSUPP, measured); a device node that opens is refused by the
        // same kind gate. `O_NONBLOCK` changes nothing for the regular file
        // this log actually is.
        let fd = openat(
            dirFd, "cleanup.log",
            O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
            0o600
        )

        guard fd != -1 else { return }

        var status = stat()
        guard fstat(fd, &status) == 0,
              FileSystemIdentityProvider.fileKind(from: status) == .regularFile
        else {
            close(fd)
            return
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let data = entry.data(using: .utf8) ?? Data()

        if #available(macOS 10.15.4, *) {
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            handle.write(data)
            handle.closeFile()
        }
    }
}
