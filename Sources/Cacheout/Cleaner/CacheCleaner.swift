/// # CacheCleaner — Guarded Cache Deletion + Honest Freed-Bytes Accounting
///
/// An `actor` that deletes cache trees — permanently or to the Trash — with
/// every deletion target passing through `PathGuard` (D4) and every freed
/// byte measured at delete time, never assumed from pre-scan totals (D1).
///
/// ## Unified entry (fn-2.3)
///
/// `clean(items:moveToTrash:)` is THE one clean path: every selected
/// `ReclaimableItem` — category aggregate, per-item scanner row, command
/// category — flows through ONE dispatch on `ReclaimAction`, with PathGuard
/// enforced at this chokepoint via each item's admission descriptor and
/// per-root records. The pre-unification category-vs-node_modules fork is
/// gone; `clean(results:nodeModules:moveToTrash:)` survives only as a THIN
/// adapter for its own compatibility tests — the ViewModel (fn-2.4) and the
/// CLI (fn-2.6) both consume `clean(items:)` directly now (deletable once
/// those tests migrate onto item fixtures).
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
/// - **Permanent delete** (`moveToTrash: false`): `FileManager.removeItem()`
///   offloaded to a background queue. Contents of category roots are removed
///   individually (the root itself survives so tools/apps can recreate it).
/// - **Move to Trash** (`moveToTrash: true`): the injectable `@MainActor`
///   trash seam (production: `FileManager.trashItem`, which talks to Finder).
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

// MARK: - CacheCleaner

actor CacheCleaner {

    /// Injectable Trash seam. Production moves the URL to the Trash via
    /// Finder; tests record or redirect so nothing outside a fixture root is
    /// ever trashed. `@MainActor` because `trashItem` talks to Finder.
    typealias TrashHandler = @Sendable @MainActor (URL) throws -> Void

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
    private nonisolated let trashHandler: TrashHandler

    /// - Parameters:
    ///   - home: home directory admission policies and the deny list anchor
    ///     to, and where `.cacheout/cleanup.log` lives (injectable — tests
    ///     pass a fixture home; production the real one).
    ///   - containerRoots: configured container roots for delete-time
    ///     `.removeItem` admission. `nil` uses the node_modules scanner's
    ///     default list for `home`, keeping delete-time admission in
    ///     lockstep with discovery.
    ///   - containerSnapshot: the producing scan session's container
    ///     identity snapshot; `nil` refuses every `.removeItem` deletion
    ///     (fail-closed — category admission is unaffected).
    ///   - provider: identity provider shared with `PathGuard` and the sizer
    ///     (tests may subclass to inject devices/kinds).
    ///   - trashHandler: Trash seam; `nil` uses `FileManager.trashItem`.
    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        containerRoots: [URL]? = nil,
        containerSnapshot: ContainerSnapshot? = nil,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider(),
        trashHandler: TrashHandler? = nil
    ) {
        self.home = home
        self.provider = provider
        self.sizer = DirectorySizer(provider: provider)
        self.pathGuard = PathGuard(
            home: home,
            containerRoots: containerRoots
                ?? NodeModulesScanner.defaultSearchRoots(home: home),
            provider: provider
        )
        self.containerSnapshot = containerSnapshot
        self.trashHandler = trashHandler ?? { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
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
    /// EVERY item regardless of state; (2) well-formed `.missing` skip;
    /// (3) non-`.missing` category-backed zero-record refusal; (4) state
    /// eligibility (`.denied` refusal, `.empty` no-op, aggregate
    /// `.commands`/`.removeContents` zero-measured skip); (5) action
    /// dispatch.
    func clean(items: [ReclaimableItem], moveToTrash: Bool) async -> CleanupReport {
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

            // (2) Well-formed `.missing`: nothing resolved on this machine
            // — nothing to do, no entry, no error. Skipping BEFORE dispatch
            // also keeps an empty record set from vacuously passing
            // `.commands` re-admission (round 8).
            if item.state == .missing { continue }

            // (3) A non-`.missing` category-backed item with ZERO root
            // records can only be a construction bug — never vacuously
            // admissible (rounds 11-12). Exhaustive over the action so a
            // future case is a compile-time decision.
            switch item.action {
            case .removeContents, .commands:
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
                    registry: registry, moveToTrash: moveToTrash
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

    // MARK: Clean — compatibility adapter (pre-unification callers)

    /// THIN adapter with NO production caller left (the ViewModel migrated
    /// in fn-2.4, the CLI in fn-2.6): builds `ReclaimableItem`s and
    /// forwards to `clean(items:moveToTrash:)` — ONE dispatch, no second
    /// code path. Survives for its own compatibility tests; deletable once
    /// they migrate onto item fixtures.
    func clean(
        results: [ScanResult],
        nodeModules: [NodeModulesItem] = [],
        moveToTrash: Bool
    ) async -> CleanupReport {
        var items: [ReclaimableItem] = []
        var preRefusals: [CleanupReport.ItemError] = []

        for result in results where result.isSelected {
            items.append(CategoryScanner.item(
                from: result, rootRecords: compatibilityRecords(for: result)
            ))
        }

        for nmItem in nodeModules where nmItem.isSelected {
            let resolved = provider.canonicalize(nmItem.nodeModulesPath)
            let id = ReclaimableItem.stableID(
                scannerID: NodeModulesScanner.registeredID,
                canonicalPath: resolved.path
            )
            // Item-mode admission requires origin-container provenance — an
            // item that cannot name the configured search root it was
            // discovered under is refused, not trusted. The unified
            // descriptor makes the container non-optional, so the refusal
            // lands here in the adapter (scanner-built items always carry
            // provenance).
            guard let origin = nmItem.originContainer else {
                let reason = "refused: item carries no origin-container provenance"
                preRefusals.append(CleanupReport.ItemError(
                    key: ItemKey(
                        scannerID: NodeModulesScanner.registeredID, itemID: id
                    ),
                    displayName: nmItem.projectName,
                    message: reason
                ))
                logRefusal(label: nmItem.projectName, tag: "no-provenance",
                           detail: "\(nmItem.nodeModulesPath.path): \(reason)")
                continue
            }
            items.append(ReclaimableItem(
                id: id,
                scannerID: NodeModulesScanner.registeredID,
                displayName: nmItem.projectName,
                exactBytes: nmItem.sizeBytes,
                estimatedUpToBytes: 0,
                logicalBytes: nil,
                itemCount: 0,
                url: resolved,
                declaredDisplayPath: nmItem.nodeModulesPath.path,
                rootRecords: [RootScanRecord(
                    requestedURL: nmItem.nodeModulesPath,
                    resolvedURL: resolved,
                    status: .measured
                )],
                state: .measured,
                scanError: nil,
                risk: .review,
                evidence: "",
                rebuildNote: nil,
                action: .removeItem,
                // Frozen arm (epic round 6): the UNRESOLVED discovered path
                // is the deletion target — leaf never resolved.
                admission: .containerItem(
                    originContainer: origin,
                    requestedTargetURL: nmItem.nodeModulesPath
                ),
                defaultSelected: false,
                automaticCleanEligible: false,
                isStale: nil
            ))
        }

        let report = await clean(items: items, moveToTrash: moveToTrash)
        guard !preRefusals.isEmpty else { return report }
        return CleanupReport(
            disposal: report.disposal,
            entries: report.entries,
            errors: report.errors + preRefusals
        )
    }

    /// Root records for compatibility `ScanResult`s built WITHOUT the
    /// fn-2.1 scan-time capture (pre-capture fixtures and legacy paths):
    /// synthesize from the category's delete-time resolution — exactly the
    /// roots the pre-unification cleaner operated on, admitted by the same
    /// policy either way. Results that DO carry records keep them verbatim
    /// (root-snapshot rule: the cleaner never re-evaluates
    /// `resolvedPaths` for captured items).
    private func compatibilityRecords(for result: ScanResult) -> [RootScanRecord] {
        guard result.rootRecords.isEmpty, result.state != .missing else {
            return result.rootRecords
        }
        return result.category.resolvedPaths(home: home).map { url in
            RootScanRecord(
                requestedURL: url,
                resolvedURL: provider.canonicalize(url),
                status: .measured
            )
        }
    }

    // MARK: - Structural refusal (defense in depth, rounds 11-13)

    /// The action/descriptor shapes the runtime validator rejects, refused
    /// HERE independently — a chokepoint that trusts its caller's
    /// validation is not a chokepoint. Exhaustive over `ReclaimAction` (a
    /// future case must decide its descriptor requirement at compile time).
    /// The non-`.missing` zero-record rule is check (3) in `clean(items:)`
    /// — it is state-aware and therefore ordered AFTER the `.missing` skip.
    private static func structuralRefusal(of item: ReclaimableItem) -> String? {
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
        }
    }

    private static func itemError(
        _ item: ReclaimableItem, _ message: String
    ) -> CleanupReport.ItemError {
        CleanupReport.ItemError(
            key: item.key, displayName: item.displayName, message: message
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
                    child, of: admitted, registry: registry,
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
                try await trash(child)
            } else {
                try await Self.removeItemConcurrently(
                    at: child, fileManager: fileManager
                )
            }
        } catch {
            if error is PathGuardError {
                logRefusal(
                    label: label, tag: Self.refusalTag(error),
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
    /// RESIDUAL, STATED: the window between this `lstat` and the deletion
    /// syscall is irreducible for as long as the deletion takes a path.
    /// What it costs is unchanged from every other path check in this
    /// method; what it buys is that the probe's whole inspection window —
    /// the entire bounded walk, which is orders of magnitude longer — is no
    /// longer part of the exposure.
    private func probedObjectStillAtTarget(
        _ inspected: UserDataProbeResult.InspectedRoot, target: URL
    ) -> Bool {
        switch inspected {
        case .directory(let identity):
            return provider.identity(of: target) == identity
        case .noDirectoryTree:
            // The clean verdict rested on there being no directory TREE of
            // ours at that name (absent, symlink, regular file, special) —
            // deletion removes the leaf as-is. A directory standing there
            // now is a tree the probe never opened.
            return provider.kind(of: target) != .directory
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
    /// registry is the caller's per-SCANNER instance.
    private func removeGuardedItem(
        _ item: ReclaimableItem, origin: URL, target: URL,
        registry: InodeAccountingRegistry, moveToTrash: Bool
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

        // DELETE-TIME SAFETY REVALIDATION (PR #456 review): the snapshot
        // admission above binds the CONTAINER's identity, not the entry's —
        // a sweep entry removed and recreated at the same name since the
        // scan passes every check so far while holding content the scan
        // never inspected. An orphaned-caches item still carrying the CLEAN
        // PROMISE (`automaticCleanEligible` is set by the classifier ONLY
        // when the scan-time user-data probe found nothing AND completed)
        // therefore re-runs the same bounded no-follow probe here,
        // immediately pre-delete, and is refused unless the promise
        // re-establishes — fail-closed, the scan-time doctrine ("an
        // inspection that could not finish is treated like a caution")
        // applied at delete time. Non-eligible sweep items reach this point
        // only through conscious per-item confirmation against DISPLAYED
        // caution evidence (the verified-Photos-library field case);
        // re-refusing them on the same disclosed state would make them
        // permanently undeletable, so they keep the epic's accepted
        // conscious-confirmation TOCTOU residual. Direction-safe either
        // way: a revalidation can only REFUSE, never widen admission — a
        // forged `automaticCleanEligible == false` merely opts back into
        // today's behavior. The scanner-keyed coupling is deliberate and
        // minimal (the scanner owns its probe; the cleaner owns the
        // chokepoint) — generalize into a per-scanner revalidator seam when
        // fn-4/fn-5 scanners need one.
        // WHAT THE PRE-DELETE PROBE'S VERDICT IS ABOUT, carried to the
        // deletion itself (PR #458 review r7). `nil` when no probe ran.
        var probedObject: UserDataProbeResult.InspectedRoot?
        if item.scannerID == OrphanedCachesScanner.registeredID,
           item.automaticCleanEligible {
            let probe = OrphanedCachesScanner.preDeleteUserDataProbe(
                at: target, provider: provider
            )
            probedObject = probe.inspected
            if !probe.matches.isEmpty {
                let names = probe.matches.joined(separator: ", ")
                let detail = "\(target.path): contents changed since scan — "
                    + "user-data-shaped content (\(names)) present at delete "
                    + "time; refused, re-scan required"
                logRefusal(label: item.displayName, tag: "content-drift",
                           detail: detail)
                return (nil, [Self.itemError(item, detail)])
            }
            if !probe.complete {
                // Remediation guidance is derived from WHAT ACTUALLY
                // OBSTRUCTED the probe (PR #458 review), never from a
                // blanket claim about the whole class. This message has now
                // been wrong in both directions: it first prescribed
                // "re-scan required" for causes a re-scan reproduces
                // exactly, then — over-correcting — asserted the opposite
                // for a set that includes a mid-walk race and transient I/O,
                // which a re-scan clears routinely. Both FLATTENED causes
                // that genuinely differ, and the second flattening is the
                // more dangerous one: it steers a user toward the riskier
                // explicit-confirmation path over a disk hiccup. The walk
                // now distinguishes its causes
                // (`UserDataProbeObstruction`), so the guidance can simply
                // say which one happened and what clears it.
                let detail = "\(target.path): couldn't fully inspect "
                    + "contents at delete time — refused (an inspection that "
                    + "could not finish is treated like a change since "
                    + "scan). "
                    + OrphanedCachesScanner.remediationGuidance(
                        for: probe.obstructions
                    )
                logRefusal(label: item.displayName, tag: "content-drift",
                           detail: detail)
                return (nil, [Self.itemError(item, detail)])
            }
        }

        let token = await registry.registerObservations(report.claims)

        do {
            // TOCTOU narrowing, immediately pre-delete: the SAME no-follow
            // + snapshot-identity admission re-runs (a container swapped
            // between the checks above and here is refused), then the
            // containment chain re-validates.
            let recheck = try pathGuard.admitContainer(origin, snapshot: snapshot)
            try pathGuard.validateRemovableItem(target, inside: recheck)
            // THE PROBE'S BINDING, AT THE LAST INSTANT BEFORE THE DELETE.
            //
            // Detecting a swap inside the probe and then deleting by path
            // anyway would be no fix at all. The probe holds a DESCRIPTOR,
            // so its verdict is a fact about an OBJECT; every check above —
            // container admission, containment, deny list, mount — is a fact
            // about a PATH, and a replacement directory created at the
            // target's name after the probe satisfies all of them while
            // holding content nobody inspected. This is where the path is
            // proven to still name the object the verdict is about.
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
                try await trash(target)
            } else {
                // Item mode deletes the target ITSELF — never its
                // contents-with-parent-preserved (R1/R15). The UNRESOLVED
                // spelling: a symlink target is removed AS a link (R4).
                try await Self.removeItemConcurrently(
                    at: target, fileManager: fileManager
                )
            }
        } catch {
            if error is PathGuardError {
                logRefusal(
                    label: item.displayName, tag: Self.refusalTag(error),
                    detail: "\(target.path): \(error.localizedDescription)"
                )
            }
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

    // MARK: - Refusal classification

    /// Stable log tag for a refusal — switched over the TYPED
    /// `PathGuardError` cases, never derived from message strings.
    private static func refusalTag(_ error: Error) -> String {
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
    nonisolated private static func removeItemConcurrently(at url: URL, fileManager: FileManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try fileManager.removeItem(at: url)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Move one URL to the Trash via the injectable seam (production:
    /// `FileManager.trashItem`, which requires the main actor).
    private func trash(_ url: URL) async throws {
        let handler = trashHandler
        try await MainActor.run { try handler(url) }
    }

    // MARK: - Logging

    private func logCleanup(label: String, bytesFreed: Int64) {
        let size = ByteCountFormatter.sharedFile.string(fromByteCount: bytesFreed)
        appendLog("Cleaned \(label): \(size)")
    }

    private func logRefusal(label: String, tag: String, detail: String) {
        appendLog("REFUSED [\(tag)] \(label): \(detail)")
    }

    /// A version-drift sibling admission is legitimate but noteworthy — log
    /// which declared root vouched for it.
    private func logDriftAdmission(_ admitted: AdmittedRoot, label: String) {
        guard admitted.viaSiblingDrift else { return }
        appendLog(
            "ADMITTED [version-drift] \(label): \(admitted.resolvedURL.path)"
            + " (declared: \(admitted.matchedDeclaredRoot.path))"
        )
    }

    private func appendLog(_ message: String) {
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

        let fd = openat(dirFd, "cleanup.log", O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)

        guard fd != -1 else { return }

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
