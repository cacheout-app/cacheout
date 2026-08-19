/// # EphemeralTempScanner — Ephemeral Temp-Dir Enumeration Core (fn-6.2)
///
/// One `ReclaimableItem` per STALE first-level entry of the three ephemeral
/// temp roots fn-6.1 resolves (`/private/tmp`, the per-user `…/T` and `…/C`
/// containers). Field basis: 2.4G of month-old agent-session scratchpads under
/// `/private/tmp/claude-501/` survived a month and several reboots, because
/// the BSD `periodic` reaper is gone from modern macOS and nothing replaced it
/// for that location.
///
/// The scanner CONSUMES fn-6.1 (`EphemeralTempRoot`, `EphemeralTempSweepConfig`)
/// and the as-built substrate (`DirectorySizer`, `PathGuard`,
/// `FileSystemIdentityProvider`, the fn-2 item model). Registration, CLI flags
/// and docs are fn-6.4's; deletion semantics are fn-6.3's — nothing here.
///
/// A value type, not a Swift `actor`, deliberately: the epic's word "actor"
/// names the scanner UNIT, and the canonical per-item template it pins
/// (`OrphanedCachesScanner`, and `BuildArtifactsScanner` beside it) is an
/// all-immutable `@unchecked Sendable` struct. There is no mutable state to
/// isolate here, and real actor isolation would add hops the `SpaceScanner`
/// protocol does not ask for.
///
/// ## Stage order (PINNED — epic r3 F6, extended r4/r5)
///
/// scanner-wide trigger gate → per-root gate/admission/listing → per-entry
/// kind dispatch → ownership gate → staleness pre-filter → cooperative lock
/// probe → `.deletionTarget` sizing → freshness re-check → outcome mapping.
///
/// Two orderings inside it are load-bearing: a candidate already known IN USE
/// is never traversed or sized, and the post-sizing re-checks run BEFORE the
/// outcome mapping — a tree that is fresh BY EITHER HALF of the staleness rule
/// offers nothing to reclaim, so it is not listed even when its sizing hit
/// denials (those denials still surface through the per-root accounting).
///
/// BOTH halves are re-checked after sizing (PR #459 review r1): the entry's
/// OWN mtime, which is a REQUIRED input of the two-stage rule and which the
/// sizer never reads, and `SizeReport.newestContentDate`, which merges
/// regular-file mtimes only. Re-checking only the second left the first
/// decided by timing alone — the same filesystem fact yielding "silently
/// excluded" or "STALE and bulk-selectable" depending on which side of one
/// `lstat` the change landed.
///
/// ## Trigger policy (epic D11 r5 — the WHOLE scanner)
///
/// The scanner runs ONLY on `.userInitiated` scans. On `.automatic` it defers
/// for ALL THREE roots: no enumeration, no sizing, no items, no issues. The
/// condition is the derived `ScanContext.includeProtectedRoots`, reused
/// deliberately rather than re-derived.
///
/// HOW THE DEFERRAL IS EXPRESSED (PR #459 review r1). By NON-PARTICIPATION
/// (`participates(in:)`), not by returning an empty outcome. An empty
/// `ScanOutcome` carries no "not inspected" representation — it is
/// indistinguishable from "the roots are empty" — and the consumer acted on
/// that reading: `CacheoutViewModel.reconcile` replaces the scanner's whole
/// entry, so an automatic refresh erased the previously displayed temp
/// findings, their issues AND the user's selections while every file was
/// still on disk. Non-participation reuses the session-subset machinery: the
/// scanner is not run, the prior outcome and its ticks stay, and the R9
/// freshness gate keeps those retained rows visible-but-non-cleanable until
/// the next completed user-initiated session. The `scan` guard remains as
/// defense-in-depth for direct invocation.
///
/// The temp roots are not themselves TCC-gated, so the reason is different:
/// TCC authorization is per-PROCESS/code-identity, NOT per-UID. A same-UID
/// process with lesser filesystem authorization can stage the swap windows
/// below inside these same-user-writable roots and steer a PATH-BASED
/// enumerator into a TCC-protected tree — which would fire a privacy prompt
/// from a background refresh, and the background no-prompt guarantee
/// (`ScanTrigger`, `SpaceScanner.swift:40-51`) is absolute.
///
/// ## Swap windows: what is closed, what is an ACCEPTED residual (epic D10)
///
/// Sizing uses `DirectorySizer.Mode.deletionTarget`, NEVER `.scanRoot`:
/// `.scanRoot` fully resolves the leaf before dispatch
/// (`DirectorySizer.swift:50-52`), so an entry swapped directory→symlink
/// between the pre-filter gates and sizing would make the sizer enumerate an
/// arbitrary EXTERNAL target. `.deletionTarget` lstat-dispatches the leaf
/// without following it (`:53-56`). That closes the BETWEEN-STAGES window —
/// and nothing more. Three windows REMAIN, and are accepted residuals:
///
/// - **W1** pre-filter lstat → pre-filter walk;
/// - **W2** the sizer's own `probeKind` → its path-based enumerator open, plus
///   Foundation's per-level descent (deep enumeration descends BY PATH);
/// - **W3** the root-level `probeKind` gate → the bounded `readdir` root
///   listing — the roots themselves are same-user-replaceable.
///
/// What a swap landing inside these can and cannot do (PR #459 review r4 —
/// the previous census said "never deletion" of a same-kind swap, which was
/// measured false before the identity pin existed):
///
/// - A CANDIDATE swapped between stage 1's staleness `lstat` and the
///   post-sizing re-read is SILENTLY SKIPPED, not emitted: stage 1's
///   (device, inode) is carried as `gatedIdentity` and the stage-(6a) re-read
///   must match it, so the scan record can only ever name the object stage 1
///   gated, the lock probe cleared and the sizer walked.
/// - What survives inside W1/W2: external metadata ENUMERATION INTO SIZING,
///   and — for an ABA revert, where the gated inode stands at the name at
///   both observations with a different tree in between — a MIXED size figure
///   on the object stage 1 really did gate. Disclosure, not deletion of an
///   unvetted object.
/// - Deletion destroys only the RECORDED object: admission re-runs no-follow
///   (`CacheCleaner.removeGuardedItem`'s `admitContainer` +
///   `validateRemovableItem` pair), deletion removes the UNRESOLVED leaf
///   (`removeItemConcurrently`, and `TrashDisposal` on the other arm), and
///   this scanner's `preDeleteRevalidator` (foot of this file) re-establishes
///   the entry's own gates from a HELD DESCRIPTOR immediately before the
///   destructive call and refuses any object whose identity is not the
///   scan-recorded one.
///
/// The path-based-substrate residual class exists in every as-built per-item
/// scanner (`OrphanedCachesScanner.swift:334-355`). Descriptor (fd) anchoring
/// is the recorded deferred alternative — it is shared-substrate surgery on
/// `DirectorySizer` and belongs to a roadmap-level hardening that benefits all
/// per-item scanners at once. NOTHING here claims a swap is impossible.
///
/// ## In-use detection: honest scope (epic D2 revised)
///
/// The AGE gate is the primary in-use defense. The cooperative lock probe is a
/// narrow supplement: `open(O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK)` + a kind
/// gate on the descriptor + `flock(LOCK_EX|LOCK_NB)` detects only ADVISORY
/// `flock` holders on the top-level candidate inode ITSELF. A process holding a
/// DESCENDANT file open for ordinary reading is NOT detected — v1 has no fd
/// enumeration (deferred: O(pids×fds), partial without root). EWOULDBLOCK is
/// the ONLY in-use signal; an open FAILURE is never "in use". `O_NONBLOCK` is
/// there because this open cannot carry `O_DIRECTORY` (regular-file candidates
/// must open too), so without it a FIFO planted at a candidate name wedges the
/// scan forever — see `cooperativeLockProbe`.
///
/// ## Denial classification by OPERATION + PROVENANCE (epic D8 r6)
///
/// A blanket "temp-root EPERM means permission-denied" rewrite is RETRACTED
/// (it was wrong twice: the residual windows mean traversal can genuinely land
/// in a TCC-protected tree, and sticky-directory semantics govern
/// unlink/rename — not lstat traversal). Classification happens at THIS layer;
/// `DirectorySizer` is untouched. By operation class:
///
/// - **(a) chain-bearing traversal errors** (this scanner's own Foundation
///   throws) apply `DirectorySizer.classifyDenial`'s `NSUnderlyingErrorKey`
///   signal: chain-EPERM ⇒ `.tccDenied` PRESERVED (a real grant hint),
///   chain-EACCES or bare Cocoa 257 ⇒ `.permissionDenied`, else `.unreadable`.
/// - **(b) raw-errno probes** (`probeKind`, the pre-filter's lstat/opendir,
///   `ownerProbe`, the lock probe's `open`): EACCES ⇒ `.permissionDenied`
///   (unambiguous); EPERM ⇒ NEUTRAL `.unreadable` — the cause is NOT
///   establishable from a bare errno, so neither `.tccDenied` nor
///   `.permissionDenied` may be asserted; anything else ⇒ `.unreadable`.
/// - **(c) post-sizing `SizeDenial`s**: `.permission` ⇒ permission-denied;
///   `.tcc` ⇒ NEUTRAL `.other`-kind `ScanError` with the detail preserved,
///   because `SizeDenial.Kind.tcc` CONFLATES chain-proven denials
///   (`DirectorySizer.swift:405-406`) with raw-probe guesses (:427); the only
///   surviving discriminator is a detail STRING, and classification derived
///   from message text is forbidden house doctrine
///   (`CacheCleaner.refusalTag` :1014-1016 switches the TYPED error).
///
/// ENOENT on a child is a purely OBSERVABLE race contract: silently skipped —
/// no item, no denial, no issue. There is no race counter.
///
/// ## Own-process safety (epic D9)
///
/// The AGE gate, and nothing else. The formerly-planned own-temp inode
/// exclusion was INERT — this app is not sandboxed, so `NSTemporaryDirectory()`
/// IS the `T` root and a first-level candidate can never share its parent
/// container's inode. Verified at implementation: `Sources/` has ZERO
/// `NSTemporaryDirectory`/`FileManager.temporaryDirectory` call sites, so the
/// app creates no first-level `T` artifacts at all; anything the running
/// session writes is fresh by construction.

import Foundation
import Darwin

/// `@unchecked Sendable` under the house scanner discipline: every stored
/// property is an immutable `let`; `FileSystemIdentityProvider`,
/// `DirectorySizer` and `PathGuard` hold no mutable state; every stored
/// closure is `@Sendable` by type.
struct EphemeralTempScanner: @unchecked Sendable {

    /// Stable scanner slug — the CLI address prefix (`ephemeral_tmp:<item-id>`),
    /// the GUI section key, and the `stableID` preimage's scanner half. Matches
    /// the address grammar `[a-z0-9_]+`. PERMANENT external contract;
    /// registration lands in fn-6.4.
    static let registeredID = "ephemeral_tmp"

    /// The ONE sizing mode every candidate is measured with (see the header:
    /// `.scanRoot` would resolve a swapped leaf and enumerate outside the
    /// root). Named once so no call site can drift.
    static let candidateSizingMode: DirectorySizer.Mode = .deletionTarget

    /// PRODUCTION cap on the staleness pre-filter's inspected entries. It
    /// bounds worst-case work on a hostile or enormous tree; it is NOT a
    /// sample. A cap hit means NOT stale (refusing to list is the safe
    /// direction), so the value has to be comfortably above real field
    /// payloads — a month-old multi-GB scratchpad holds thousands of files,
    /// and calling it "not stale" because the walk gave up would make the
    /// scanner useless exactly where it exists to help.
    static let defaultPrefilterEntryLimit = 20_000

    /// PRODUCTION cap on the first-level ROOT listing (PR #459 review r4,
    /// codex C3 — AVAILABILITY). `/private/tmp` is world-writable, so any
    /// local user controls this population, and the eager
    /// `contentsOfDirectory` listing plus the per-name sort ran as ONE
    /// uninterruptible synchronous stretch on the scan's cooperative-pool
    /// worker — measured on a staged ~494k-entry root this session: 6.8 s
    /// list + 16.4 s sort, transient RSS 5.7 MB → 8.24 GB, with no
    /// cancellation point anywhere inside. The bounded `readdir` read at
    /// this cap on the SAME root: 99 ms, +2 MB. Real machines measured
    /// 14/213/401 first-level entries across the three roots, so the cap is
    /// ~50× the largest observed population. A cap hit is DISCLOSED as a
    /// root-level issue, and it is NOT a deterministic strand: it gates only
    /// the VISIBILITY of never-listed entries (never the deletion of an
    /// emitted item), and cleaning the listed items itself shrinks the
    /// population, so repeated scan+clean cycles genuinely converge below
    /// the cap — unlike the orphaned-caches fixed depth cap, a retry here
    /// CAN differ.
    static let defaultRootEntryLimit = 20_000

    // MARK: - Seams

    /// The cooperative candidate-lock probe's outcome (epic D2 revised).
    enum LockProbe: Equatable {
        /// No advisory `flock` holder on the candidate inode — the lock was
        /// taken and immediately dropped. NOT a claim about descendants.
        case available
        /// EWOULDBLOCK — the ONE in-use signal.
        case inUse
        /// NOTHING THIS SCANNER LISTS STANDS AT THE NAME ANY MORE — the
        /// silent-skip disposition, shared by two arms. (PR #459 review r4:
        /// the r3 doc here claimed all three special kinds arrive through a
        /// successful open and share this disposition — measured false for
        /// sockets, twice over. Per kind, under this exact flag set:)
        ///
        /// - The open FAILED benignly: ENOENT/ENOTDIR (gone) or ELOOP
        ///   (swapped to a symlink after dispatch — `O_NOFOLLOW` refusing to
        ///   open it is the point).
        /// - The open SUCCEEDED but `fstat` reports a kind this scanner never
        ///   lists. Which kinds actually get here, measured:
        ///   - a FIFO opens under `O_NONBLOCK` and fstats `S_IFIFO` — skipped;
        ///   - a device node whose driver admits the open fstats
        ///     `S_IFCHR`/`S_IFBLK` (measured: `/dev/null`) — skipped; one
        ///     whose driver refuses (measured: `/dev/tty` with no controlling
        ///     terminal, ENXIO) is `.failed`, the visible denial accounting;
        ///   - a bound AF_UNIX SOCKET never reaches this arm at all:
        ///     `open(2)` fails EOPNOTSUPP (errno 102, measured, with and
        ///     without `O_NONBLOCK`), so a socket is `.failed` — a VISIBLE
        ///     refusal, not this silent skip.
        ///   Root-level `probeKind` already skips `.other` silently, so the
        ///   kinds that DO open get the same disposition when they arrive in
        ///   the swap window between that probe and this one.
        case vanished
        /// The `open` failed for another reason — NEVER "in use"; routed to
        /// the same denial accounting as any other raw-errno probe.
        case failed(errno: Int32)
    }

    /// Injection seam for the lock probe — one branch per test cell.
    typealias LockProber = @Sendable (URL) -> LockProbe

    /// Injection seam for the ONE first-level enumeration per root. Exists so
    /// the trigger gate's "nothing was enumerated at all" contract is
    /// ASSERTABLE, and so the chain-bearing denial class (a Cocoa error
    /// wrapping a POSIX one) can be exercised — a real single-uid fixture can
    /// produce a chain-EACCES throw but never a chain-EPERM one.
    ///
    /// The shape is BOUNDED BY CONSTRUCTION (PR #459 review r4, codex C3):
    /// the previous `(URL) throws -> [URL]` return type forced every
    /// implementation — injected or production — to materialize the full
    /// array before the scanner saw one entry. Basenames and a truncation
    /// flag, never URLs: the scan rebuilds each entry under the DECLARED
    /// canonical root spelling anyway.
    typealias DirectoryLister =
        @Sendable (URL, Int) throws -> (names: [String], truncated: Bool)

    /// Injection seam for stage-2 sizing. Carries the MODE so a test can
    /// assert what production passes (`.deletionTarget`), and gives the
    /// between-stages fixtures (symlink swap, late-arriving fresh file, the
    /// post-sizing outcome rows) their staging point.
    typealias CandidateSizer = @Sendable (URL, DirectorySizer.Mode) -> SizeReport

    // MARK: - Stored state (all construction state — never `ScanContext`)

    /// The resolved roots, canonical spellings verbatim (fn-6.1). Injectable:
    /// no unit test ever reads a real temp root.
    let roots: [EphemeralTempRoot]
    /// Anchor for this scanner's own `PathGuard` (injectable — zero real
    /// `$HOME` reads in tests).
    let home: URL
    /// Size floor + stale age, resolved at CONSTRUCTION by frozen contract
    /// (thresholds never ride `ScanContext`).
    let thresholds: EphemeralTempSweepConfig.Thresholds

    private let provider: FileSystemIdentityProvider
    /// This scanner's OWN guard, whose container roots are exactly its
    /// declared `trustedContainerRoots` (scan-time admission is read-only and
    /// snapshot-free).
    private let pathGuard: PathGuard
    private let sizer: DirectorySizer
    private let prefilterEntryLimit: Int
    /// Cap on the first-level root listing (see `defaultRootEntryLimit`).
    private let rootEntryLimit: Int
    /// Injected clock — a PROVIDER, not a `Date`: the scanner is long-lived
    /// and each scan dates content against its own "now".
    private let now: @Sendable () -> Date
    private let lockProbe: LockProber
    private let listDirectory: DirectoryLister
    /// `nil` in production — the real `DirectorySizer` is called directly.
    private let candidateSizer: CandidateSizer?

    init(
        roots: [EphemeralTempRoot],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        thresholds: EphemeralTempSweepConfig.Thresholds =
            EphemeralTempSweepConfig.defaultThresholds,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider(),
        prefilterEntryLimit: Int =
            EphemeralTempScanner.defaultPrefilterEntryLimit,
        rootEntryLimit: Int = EphemeralTempScanner.defaultRootEntryLimit,
        now: @escaping @Sendable () -> Date = { Date() },
        // Closure literals, not bare static-function references: a static
        // `func` value is not inferred `@Sendable`, and the warning it raises
        // is a real Swift 6 error in waiting.
        lockProbe: @escaping LockProber = {
            EphemeralTempScanner.cooperativeLockProbe($0)
        },
        listDirectory: @escaping DirectoryLister = {
            try EphemeralTempScanner.boundedFirstLevelNames(of: $0, limit: $1)
        },
        candidateSizer: CandidateSizer? = nil
    ) {
        self.roots = roots
        self.home = home
        self.thresholds = thresholds
        self.provider = provider
        self.pathGuard = PathGuard(
            home: home, containerRoots: roots.map(\.url), provider: provider
        )
        self.sizer = DirectorySizer(provider: provider)
        self.prefilterEntryLimit = prefilterEntryLimit
        self.rootEntryLimit = rootEntryLimit
        self.now = now
        self.lockProbe = lockProbe
        self.listDirectory = listDirectory
        self.candidateSizer = candidateSizer
    }

    /// The PRODUCTION first-level listing — BOUNDED (PR #459 review r4, codex
    /// C3): a `readdir` loop that stops at `limit`, never the eager
    /// `contentsOfDirectory` (both of its overloads materialize the WHOLE
    /// directory before any cap can apply — `boundedChildNames`'s own trap
    /// note; measured this session on a staged ~494k-entry root, the eager
    /// list + sort ran 6.8 s + 16.4 s uninterruptible with an 8.24 GB
    /// transient RSS, while this read at the 20,000 cap returned in 99 ms
    /// holding +2 MB). `readdir` skips nothing, preserving the retired
    /// listing's `options: []` semantics — dotfile scratch directories are
    /// real payload (the sweep-scanner lesson: a hidden-file skip hid a 23G
    /// class).
    ///
    /// The FAILURE arm re-asks through `firstLevelEntries` to harvest the
    /// chain-bearing Cocoa error the class-(a) denial classification needs —
    /// a raw `opendir` errno is class (b) and may not claim TCC. That call
    /// fails AT OPEN, before materializing anything, so the eager path stays
    /// unreachable on the success path; the one way through it is the
    /// open-failed-then-cleared race, where success means the materialization
    /// already happened and the cap is applied to what it returned.
    static func boundedFirstLevelNames(
        of root: URL, limit: Int
    ) throws -> (names: [String], truncated: Bool) {
        switch boundedChildNames(of: root, limit: limit) {
        case .names(let names, let truncated):
            return (names, truncated)
        case .failed:
            let children = try firstLevelEntries(of: root)
            let names = children.map(\.lastPathComponent)
            guard names.count > limit else { return (names, false) }
            return (Array(names.prefix(limit)), true)
        }
    }

    /// The CHAIN-ERROR HARVEST arm of `boundedFirstLevelNames`, and nothing
    /// else (PR #459 review r4 — this WAS the production listing, and its
    /// unbounded eager materialization is why it no longer is).
    static func firstLevelEntries(of root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: []
        )
    }

    // MARK: - Protocol surface (the conformance sits at the foot of this file)

    var id: String { Self.registeredID }
    var displayName: String { "Ephemeral Temp Files" }

    /// The canonical root spellings, declared at REGISTRATION — this is HOW
    /// the container reaches the cleaner (the runtime unions scanner-declared
    /// roots into PathGuard's delete-time admission; nothing item-side can
    /// widen it). fn-6.1 canonicalized each root exactly once, so the origin
    /// claim on every item, the root records, and the identity parent chains
    /// all speak ONE spelling.
    var trustedContainerRoots: [URL] { roots.map(\.url) }

    /// THE TRIGGER POLICY, EXPRESSED AS NON-PARTICIPATION (PR #459 review r1).
    /// A pure predicate: it walks no root, opens nothing and checks no
    /// cancellation.
    ///
    /// This is where the `.automatic` deferral lives. Returning an empty
    /// `ScanOutcome` from `scan` instead is what the scanner used to do, and
    /// it was not a deferral at all: an empty outcome ASSERTS the roots are
    /// empty, and the consumer believed it — `reconcile` replaced the
    /// scanner's whole entry, so a user who scanned, saw the temp findings and
    /// ticked some watched the section empty itself, the issues disappear and
    /// the ticks drop at the next automatic refresh, while every file was
    /// still on disk and no temp root had been opened.
    func participates(in context: ScanContext) -> Bool {
        context.includeProtectedRoots
    }

    /// One scan: trigger gate → per root (gate, admit, list) → per entry
    /// (dispatch, ownership, staleness, lock, size, freshness, map).
    ///
    /// `context.categoryFilter` is ignored (it scopes `CategoryScanner` only).
    /// Cancellation is checked between roots and between entries — partial
    /// results are returned rather than discarded.
    func scan(context: ScanContext) async -> ScanOutcome {
        // TRIGGER GATE (epic D11 r5) — the WHOLE scanner, all three roots.
        //
        // DEFENSE IN DEPTH FOR A CALLER THAT BYPASSES THE RUNTIME (PR #459
        // review r2). The enforcement point is `SpaceScannerRuntime
        // .scanValidatedSession`, which filters on `participates(in:)` for
        // EVERY caller of a session; this guard is what makes the
        // no-enumeration promise hold for code that constructs a scanner and
        // calls `scan` directly, which the tests do and which nothing stops a
        // future call site from doing. Do not delete it on the ground that the
        // session layer handles it: the session layer handles SESSIONS.
        //
        // Note what an empty outcome does and does not say: it carries no "not
        // inspected" representation, so it cannot express a deferral to a
        // consumer — which is the reason the participation seam exists and why
        // this arm is a last resort rather than the policy.
        //
        // The comment that stood here called this "exactly like a skipped
        // TCC-protected search root". Mechanically true, and that is the
        // problem rather than the reassurance: the TCC skip
        // (`ProjectTreeWalker`'s bare `continue`) erases previously displayed
        // build-artifacts findings and their selections on an automatic
        // refresh in the same way, measured, whenever a dev root sits under a
        // protected directory. That is a separate defect, not a precedent.
        guard context.includeProtectedRoots else {
            return ScanOutcome(items: [], errors: [])
        }

        let now = self.now()
        // STRICTLY older than this instant is stale; at-or-after it is fresh.
        // The same boundary governs the pre-filter and the post-sizing
        // freshness re-check, so the two can never disagree.
        let cutoff = now.addingTimeInterval(-thresholds.staleAge)
        let euid = geteuid()

        var items: [ReclaimableItem] = []
        var issues: [ScanIssue] = []
        // One denial per filesystem object per scan — a candidate that failed
        // at the ownership gate must not be counted again by a later stage.
        var deniedPaths = Set<String>()
        // Dedupe by the LEAF-PRESERVING identity, consulted BEFORE the
        // expensive stages so one filesystem object is locked and sized at
        // most once per scan even when two declared roots alias each other.
        var seenIdentities = Set<String>()

        func record(_ cause: DenialCause, at url: URL, _ note: String) {
            guard deniedPaths.insert(url.path).inserted else { return }
            issues.append(Self.denialIssue(cause, at: url, note: note))
        }

        for root in roots {
            if Task.isCancelled { break }

            // ROOT GATE, no-follow (R11 + the symlink-root rule). Scan-time
            // ABSENCE is a SILENT skip — including the construction-to-scan
            // disappearance race AND absence landing in this probe's own
            // probe-to-list window (r4, codex C5: the listing catch below
            // holds up the second half — it used to report a vanished root
            // as `.unreadable`): temp roots churn by design, and a spurious
            // issue for a legitimately vanished root trains users to ignore
            // issues. A PRESENT but unreadable root is the opposite case and
            // must stay visible (a silent zero there is the TCC-silent-zero
            // defect class fn-1 exists to prevent).
            switch provider.probeKind(of: root.url) {
            case .absent:
                continue
            case .failed(let code):
                record(.rawErrno(code), at: root.url,
                       "\(root.label) could not be inspected")
                continue
            case .kind(.directory):
                break
            case .kind(let kind):
                issues.append(ScanIssue(
                    url: root.url, kind: .symlinkRoot,
                    detail: "\(root.label) is not a real directory "
                        + "(\(Self.describe(kind))) — never traversed"
                ))
                continue
            }

            // Scan-time traversal admission (read-only, snapshot-free): the
            // shared container-root policy refuses `/`, volume roots and
            // `$HOME` in any spelling, from ONE definition.
            do {
                _ = try pathGuard.admitSearchRoot(root.url)
            } catch {
                issues.append(ScanIssue(
                    url: root.url, kind: .containerRefused,
                    detail: error.localizedDescription
                ))
                continue
            }

            let listing: (names: [String], truncated: Bool)
            do {
                listing = try listDirectory(root.url, rootEntryLimit)
            } catch {
                // TWO dispositions (PR #459 review r4, codex C5 — this catch
                // used to make every throw visible, so a root vanishing in
                // the probe-to-list window produced exactly the spurious
                // issue R11 exists to prevent):
                //
                // 1. ABSENCE — chain-ENOENT/ENOTDIR, the same definition
                //    `probeKind` uses — is the R11 SILENT skip at ANY
                //    scan-time instant, matching every other seam in this
                //    file (kind dispatch, ownership, the pre-filter walk,
                //    the lock probe, the post-sizing re-read). The code is
                //    recovered from the error already in hand via the house
                //    chain walk — never a re-probe (a second racy read that
                //    misclassifies a recreated name) and never message text.
                if let code = DirectorySizer.underlyingPOSIXCode(of: error),
                   code == ENOENT || code == ENOTDIR {
                    continue
                }
                // 2. A root that IS present but refuses enumeration is a
                //    classified, VISIBLE issue — never empty-looking
                //    success. This is the one chain-bearing operation class
                //    (a), so a provenance-backed TCC signal is preserved.
                record(.cocoaChain(error), at: root.url,
                       "\(root.label) could not be listed")
                continue
            }

            // A truncated listing is DISCLOSED, never silent (the silent
            // half would be a bounded cousin of the TCC-silent-zero class).
            // Not a strand: the cap gates only the VISIBILITY of never-listed
            // entries — no emitted item's deletion ever waits on it — and
            // temp populations churn by design, so cleaning the listed items
            // itself lets a later scan see further. The wording states that
            // FACT and never promises a bare "re-scan and retry" (the
            // deterministic-bound lesson: promise a retry only where a retry
            // can differ, and say WHY it can).
            if listing.truncated {
                let detail = listing.names.count == rootEntryLimit
                    ? "\(root.label) holds more than \(rootEntryLimit) "
                        + "first-level entries — only the first "
                        + "\(rootEntryLimit) the directory returned were "
                        + "inspected; clearing entries, including cleaning "
                        + "the items listed here, lets a later scan see the "
                        + "rest"
                    : "\(root.label) could not be enumerated completely — "
                        + "only \(listing.names.count) first-level entries "
                        + "were readable; what follows covers those"
                issues.append(ScanIssue(
                    url: root.url, kind: .enumerationTruncated, detail: detail
                ))
            }

            // utf8-lexicographic, the same comparator the pre-filter walk
            // uses — never the locale-collating String `<`, whose cost on an
            // adversarial population was the measured 16 s sort tail.
            for name in listing.names.sorted(by: {
                $0.utf8.lexicographicallyPrecedes($1.utf8)
            }) {
                if Task.isCancelled { break }
                // Build under the DECLARED canonical root: the listing hands
                // back bare basenames, and identity/display/deletion must all
                // speak the root spelling this scanner declared.
                let entry = root.url.appendingPathComponent(name)

                // (1) KIND DISPATCH, no-follow.
                let kind: FileSystemIdentityProvider.FileKind
                switch provider.probeKind(of: entry) {
                case .absent:
                    // ENOENT contract: no item, no denial, no issue.
                    continue
                case .failed(let code):
                    record(.rawErrno(code), at: entry,
                           "temp entry could not be inspected")
                    continue
                case .kind(let probed):
                    kind = probed
                }
                switch kind {
                case .directory, .regularFile:
                    break
                case .symlink, .other:
                    // Sockets/FIFOs/devices and symlinks are skipped SILENTLY
                    // at root level (epic D4): `/private/tmp` holds live
                    // top-level sockets, and a symlink's target is not ours.
                    continue
                }

                // Identity FIRST (leaf-preserving): the dedupe key, the
                // display identity and the `stableID` preimage are all this
                // one derivation — canonical PARENT chain + UNRESOLVED leaf.
                let identity = provider.resolveTargetKeepingLeaf(entry)
                guard seenIdentities.insert(identity.path).inserted else {
                    continue
                }

                // (2) OWNERSHIP GATE — world-writable root only (epic D12).
                if root.writability == .worldWritable {
                    switch provider.ownerProbe(of: entry) {
                    case .owner(let uid) where uid != euid:
                        // Genuinely OBSERVED foreign ownership: silently
                        // excluded. Sticky-directory rules make it
                        // undeletable, so an item would claim bytes the
                        // cleaner deterministically cannot free — and a
                        // per-entry issue for ordinary multi-user background
                        // noise would bury the real denials below.
                        continue
                    case .owner:
                        break
                    case .absent:
                        // Same silent contract as ENOENT-on-child.
                        continue
                    case .failed(let code):
                        record(.rawErrno(code), at: entry,
                               "temp entry ownership could not be established")
                        continue
                    }
                }

                // (3) STALENESS PRE-FILTER (stage 1).
                let verdict: StalenessVerdict
                switch kind {
                case .directory:
                    verdict = directoryStaleness(of: entry, cutoff: cutoff)
                case .regularFile:
                    verdict = fileStaleness(of: entry, cutoff: cutoff)
                case .symlink, .other:
                    continue // unreachable — filtered above
                }
                // The (device, inode) STAGE 1 GATED — what the lock probe
                // clears and the sizing walk is ABOUT. Stage (6a) proves its
                // own re-read against this, which is what binds the emitted
                // report to the object the whole pipeline inspected (PR #459
                // review r4, codex C1).
                let gatedIdentity: FileSystemIdentityProvider.Identity
                switch verdict {
                case .notStale, .vanished:
                    continue
                case .denied(let url, let cause):
                    record(cause, at: url,
                           "staleness of \(entry.lastPathComponent) could not "
                            + "be established")
                    continue
                case .stale(_, let identity):
                    // The payload date is deliberately DROPPED here: stage 1
                    // read it before the pre-filter walk and before sizing, and
                    // stage (6a) below re-reads it afterwards. Carrying the
                    // pre-walk value forward is what made the evidence string
                    // report an mtime that was already false. The IDENTITY is
                    // the opposite case: it must be the PRE-walk observation,
                    // because it exists to prove the post-sizing read saw the
                    // same object stage 1 did.
                    gatedIdentity = identity
                }

                // (4) COOPERATIVE LOCK PROBE — after the pre-filter, BEFORE
                // sizing: a candidate already known in use is never traversed
                // or sized.
                switch lockProbe(entry) {
                case .available:
                    break
                case .inUse:
                    continue
                case .vanished:
                    continue
                case .failed(let code):
                    record(.rawErrno(code), at: entry,
                           "temp entry could not be opened for the in-use check")
                    continue
                }

                // (5) SIZING — always `.deletionTarget` (see `measure`).
                let report = measure(entry)

                // (6a) OWN-MTIME RE-PROBE (PR #459 review r1). The stage-1
                // truth table makes the entry's OWN mtime a REQUIRED input —
                // "fresh own mtime + all contents old" is NOT stale — and
                // stage 1 read it ONCE, before the pre-filter walk and before
                // the entire sizing walk. `SizeReport.newestContentDate`
                // cannot cover for it: it merges REGULAR-FILE mtimes only
                // (`DirectorySizer.recordRegularFile` is its sole writer), so
                // a `mkdir`/`unlink`/`rename`/symlink/socket landing in the
                // candidate during sizing bumps the entry's own mtime and
                // contributes NOTHING to `newestContentDate`.
                //
                // Without this, the identical filesystem fact yielded opposite
                // verdicts on timing alone: "not stale, silently excluded" one
                // microsecond before the stage-1 read, "STALE, badged and
                // BULK-selectable" one microsecond after. `isStale` is the key
                // of the section's one-click "Select Stale" button, so
                // its honesty is load-bearing.
                //
                // The same no-follow read (`leafDate` → `lstat`) and the SAME
                // `cutoff`, so the two halves can never disagree on the
                // boundary. It is placed BEFORE the content check so the cheap
                // single `lstat` short-circuits and so a suppression names the
                // right cause.
                //
                // CLAIM SCOPE: this NARROWS the window from
                // "pre-filter → end of sizing" to "end of sizing → emission".
                // It does not close it — the mtime can change between emission
                // and the user's click — and like every other read in this
                // scanner it is path-based (W1/W2/W3).
                let sizedOwnDate: Date
                // THE SCAN'S RECORDED IDENTITY (PR #459 review r2, pinned r4)
                // — read from the SAME `lstat` as the re-probed mtime, so the
                // two can never describe different objects, and PROVEN EQUAL
                // to `gatedIdentity` below, so it is also the object stage 1
                // gated, the lock probe cleared and the sizer walked. It rides
                // the item to the delete-time re-check, which refuses any
                // OTHER object standing at this name. What stays open after
                // the pin: an ABA revert (the same inode observed here and at
                // stage 1 with a different tree standing in between — the
                // accepted path-based W2 interior, whose worst case is a mixed
                // size figure on the object stage 1 really did gate) and the
                // emission→click window the delete-time re-check covers.
                let sizedIdentity: FileSystemIdentityProvider.Identity
                switch leafDate(of: entry) {
                case .vanished:
                    // The observable-race contract, unchanged: no item, no
                    // denial, no issue.
                    continue
                case .failed(let cause):
                    // FAIL CLOSED, matching stage 1's direction exactly: an
                    // unprovable staleness is "not stale, and VISIBLE". A
                    // permission change or an out-of-domain metadata read
                    // mid-scan must not silently downgrade to "still stale".
                    record(cause, at: entry,
                           "staleness of \(entry.lastPathComponent) could not "
                            + "be re-established after sizing")
                    continue
                case .dated(let own, _, let probed):
                    // THE IDENTITY PIN (PR #459 review r4, codex C1). This
                    // `lstat` is a fresh resolution of the NAME. Without the
                    // pin, a same-kind swap landing anywhere from stage 1's
                    // read through this one bound the REPLACEMENT's identity
                    // to a report that sized the ORIGINAL (or a mix), and the
                    // delete-time identity re-check then "proved" exactly the
                    // wrong object — measured: an old, unlocked, user-owned
                    // 8 KiB directory renamed onto a sized 64 KiB name was
                    // emitted with the original's bytes and revalidated
                    // `.allow` on the replacement's inode. A mismatch is the
                    // vanished/silent-skip contract: nothing the scan gated
                    // stands at the name, and a re-scan sees whatever does.
                    guard probed == gatedIdentity else { continue }
                    guard own < cutoff else {
                        // Same shape as the content arm below: suppressed as
                        // fresh, with any sizing denials still surfaced so
                        // visibility survives without a lying row.
                        if let ranked = Self.rankedDenial(report.denials) {
                            record(.sizing(ranked), at: entry,
                                   "\(entry.lastPathComponent) was excluded "
                                    + "because it was modified while it was "
                                    + "being measured, but part of it could "
                                    + "not be read")
                        }
                        continue
                    }
                    sizedOwnDate = own
                    sizedIdentity = probed
                }

                // (6) FRESHNESS RE-CHECK, before any outcome mapping. Positive
                // evidence of freshness disqualifies the candidate REGARDLESS
                // of report cleanliness: an item exists to offer deletion of
                // stale payload, and a fresh tree offers none. A nil
                // `newestContentDate` (nothing was enumerable) is not
                // evidence and passes through to the mapping.
                if let newest = report.newestContentDate, newest >= cutoff {
                    // Visibility survives without a lying item row: the
                    // suppressed candidate's sizing denials still surface.
                    if let ranked = Self.rankedDenial(report.denials) {
                        record(.sizing(ranked), at: entry,
                               "\(entry.lastPathComponent) was excluded as "
                                + "fresh, but part of it could not be read")
                    }
                    continue
                }

                // (7) OUTCOME MAPPING (+ the clean-walk floor). `ownDate` is
                // the RE-READ one: the `newestContentDate == nil` evidence
                // branch prints "last modified N days ago" from it, and the
                // pre-filter's value would be a literal false statement about
                // an entry touched during sizing.
                if let item = reclaimableItem(
                    entry: entry, identity: identity, root: root,
                    report: report, ownDate: sizedOwnDate,
                    scannedIdentity: sizedIdentity, now: now
                ) {
                    items.append(item)
                }
            }
        }

        return ScanOutcome(items: items, errors: issues)
    }

    // MARK: - Stage 2 sizing

    /// Stage-2 sizing through the ONE pinned mode. The seam exists so tests
    /// can observe the mode and stage between-stages races; production calls
    /// the shared sizer directly.
    ///
    /// WHY `.deletionTarget`, and WHAT IT DOES NOT BUY (epic D10 — the honest
    /// claim scope, restated at the call site it governs): the mode makes the
    /// sizer lstat-dispatch the leaf without following it, so an entry swapped
    /// directory→symlink after the pre-filter verdict sizes 0 and is never
    /// walked — that BETWEEN-STAGES window is closed. The substrate's own
    /// windows are NOT: (W1) the pre-filter's lstat → its walk, (W2) the
    /// sizer's `probeKind` → its path-based enumerator open plus every
    /// per-level descent, (W3) the root `probeKind` gate → the first-level
    /// listing. Those are ACCEPTED residuals whose worst case is external
    /// metadata enumeration into a displayed size — never deletion, which
    /// re-admits no-follow and removes the unresolved leaf. Nothing here makes
    /// a swap impossible, and no test may claim it does.
    private func measure(_ entry: URL) -> SizeReport {
        if let candidateSizer {
            return candidateSizer(entry, Self.candidateSizingMode)
        }
        return sizer.measure(at: entry, mode: Self.candidateSizingMode)
    }

    // MARK: - Staleness pre-filter (stage 1, R1)

    /// Stage-1 verdict for one candidate.
    private enum StalenessVerdict {
        /// Both inputs held; the payload carries the entry's own mtime for
        /// evidence when sizing dates nothing, and the (device, inode) the
        /// SAME stage-1 `lstat` saw — the identity every later stage is
        /// pinned to (PR #459 review r4, codex C1). The lstat already
        /// returned it; before the pin it was read and DISCARDED here.
        case stale(ownDate: Date, identity: FileSystemIdentityProvider.Identity)
        /// Not listed, silently: a fresh own mtime, a fresh file found inside,
        /// a cap hit without a fresh hit, or a regular file under the floor.
        case notStale
        /// ENOENT on the candidate itself — the observable race contract.
        case vanished
        /// The verdict is UNPROVABLE (a denial mid-probe): not stale, and
        /// visible.
        case denied(URL, DenialCause)
    }

    /// The TWO-stage staleness rule's stage 1 for a DIRECTORY candidate
    /// (epic D6 — do not collapse it):
    ///
    /// | entry own mtime | inspected regular files      | verdict          |
    /// |-----------------|------------------------------|------------------|
    /// | old             | all old (walk completed)     | STALE → stage 2  |
    /// | old             | ≥1 fresh (early exit)        | NOT stale        |
    /// | fresh           | all old                      | NOT stale        |
    /// | old             | none (empty tree)            | vacuously stale  |
    /// | any             | cap hit, no fresh hit        | NOT stale        |
    /// | any             | denial mid-probe             | NOT stale + issue|
    ///
    /// The empty-old-directory cell reaches stage 2 and is then never listed:
    /// zero allocated bytes cannot meet a positive size floor on a clean walk.
    /// Special-casing emptiness here would fork the rule for zero payoff.
    ///
    /// Intermediate DIRECTORY mtimes are deliberately not inputs (the same
    /// blind spot the sizer accepts). The entry's OWN mtime IS an input, which
    /// makes this rule STRICTER than `SizeReport.newestContentDate` — that
    /// merges regular-file mtimes only and never reads directory mtimes
    /// (`DirectorySizer.recordRegularFile` is its ONLY writer; the enumerator's
    /// `.directory` arm records mount boundaries and nothing else).
    ///
    /// WHICH HALF IS RE-MEASURED, AND WHEN (PR #459 review r2 — the wording
    /// here claimed "both halves are measured as of sizing completion", which
    /// is true of only one of them).
    ///
    /// The OWN-MTIME half IS re-measured at sizing completion: `scan` re-reads
    /// it after the sizing walk with this same `leafDate` and this same
    /// cutoff. That is what closes the case the previous comment described
    /// without owning — because `newestContentDate` is blind to the own mtime,
    /// a `mkdir`/`unlink`/`rename`/symlink/socket landing in the candidate
    /// DURING sizing used to defeat the stricter half entirely.
    ///
    /// The CONTENT half is only as fresh as the walk that collected it.
    /// `SizeReport.newestContentDate` is accumulated per regular file AS the
    /// sizing enumerator passes it, and stage 1's `walkForFreshContent` runs
    /// entirely BEFORE sizing and never re-runs — neither is re-read
    /// afterwards. So a write to `X/a/b/live.log` after the enumerator has
    /// left `X/a/b` bumps `b`'s mtime, not `X`'s: the post-sizing own-mtime
    /// re-probe reads old, `newestContentDate` never saw the file, and the row
    /// still ships `isStale: true`. Intermediate DIRECTORY mtimes are not
    /// inputs anywhere in this scanner, which is what leaves that escape open.
    /// It is narrowed at DELETE time, not here: `preDeleteRevalidator` walks
    /// the tree again from a held descriptor immediately before removal.
    private func directoryStaleness(
        of entry: URL, cutoff: Date
    ) -> StalenessVerdict {
        switch leafDate(of: entry) {
        case .vanished:
            return .vanished
        case .failed(let cause):
            return .denied(entry, cause)
        case .dated(let ownDate, _, let identity):
            // Metadata churn on the entry itself disqualifies it before any
            // walk: the own-mtime input fails, so the contents do not matter.
            guard ownDate < cutoff else { return .notStale }
            return walkForFreshContent(
                entry, cutoff: cutoff, ownDate: ownDate, identity: identity
            )
        }
    }

    /// Stage 1 for a REGULAR-FILE candidate: its OWN allocation must meet the
    /// floor and its OWN mtime must be older than the cutoff. One no-follow
    /// `lstat` answers both.
    private func fileStaleness(
        of entry: URL, cutoff: Date
    ) -> StalenessVerdict {
        switch leafDate(of: entry) {
        case .vanished:
            return .vanished
        case .failed(let cause):
            return .denied(entry, cause)
        case .dated(let date, let allocatedBytes, let identity):
            guard allocatedBytes >= thresholds.sizeFloorBytes,
                  date < cutoff
            else { return .notStale }
            return .stale(ownDate: date, identity: identity)
        }
    }

    /// The bounded, EARLY-EXIT, no-follow walk under a directory candidate:
    /// it stops at the FIRST regular file at-or-newer than the cutoff. Nothing
    /// here sizes anything — the one sizing walk is stage 2's.
    ///
    /// Every not-proven-exhaustive outcome (cap hit, truncated read) returns
    /// NOT stale: refusing to list is the safe direction. A denial mid-probe
    /// returns `.denied` — the staleness of a tree we cannot read is
    /// unprovable, and the denial must be visible.
    private func walkForFreshContent(
        _ root: URL, cutoff: Date, ownDate: Date,
        identity: FileSystemIdentityProvider.Identity
    ) -> StalenessVerdict {
        var visited = 0
        var stack: [URL] = [root]

        while let directory = stack.popLast() {
            let remaining = prefilterEntryLimit - visited
            guard remaining > 0 else { return .notStale }

            switch Self.boundedChildNames(of: directory, limit: remaining) {
            case .failed(let code):
                if code == ENOENT || code == ENOTDIR {
                    // The branch vanished mid-walk — the benign race, skipped
                    // like any other ENOENT.
                    continue
                }
                return .denied(directory, .rawErrno(code))
            case .names(let names, let truncated):
                // More entries remained than the budget could read (or the
                // read could not be proven exhaustive): "every file is old"
                // is unproven, so the safe direction wins.
                if truncated { return .notStale }
                var pending: [URL] = []
                for name in names.sorted(by: {
                    $0.utf8.lexicographicallyPrecedes($1.utf8)
                }) {
                    guard visited < prefilterEntryLimit else {
                        return .notStale
                    }
                    visited += 1
                    let child = directory.appendingPathComponent(name)
                    switch provider.probeKind(of: child) {
                    case .absent:
                        continue
                    case .failed(let code):
                        return .denied(child, .rawErrno(code))
                    case .kind(.regularFile):
                        switch leafDate(of: child) {
                        case .vanished:
                            continue
                        case .failed(let cause):
                            return .denied(child, cause)
                        case .dated(let date, _, _):
                            // The newest-content rule: ONE fresh file
                            // anywhere below disqualifies the whole entry.
                            if date >= cutoff { return .notStale }
                        }
                    case .kind(.directory):
                        pending.append(child)
                    case .kind(.symlink), .kind(.other):
                        // Never followed; neither carries content of its own
                        // to date (the sizer ignores them for
                        // `newestContentDate` too).
                        continue
                    }
                }
                // Pushed reversed so the DFS drains children in the ascending
                // order they were sorted into.
                stack.append(contentsOf: pending.reversed())
            }
        }
        return .stale(ownDate: ownDate, identity: identity)
    }

    /// One no-follow `lstat` read as "when was this last modified, and how
    /// much does the leaf itself allocate".
    private enum LeafDate {
        /// The mtime, the leaf's own allocation, and the (device, inode) the
        /// SAME `lstat` saw — one read, so the three can never describe
        /// different objects (PR #459 review r2: the identity is what the
        /// delete-time re-check proves the entry against).
        case dated(
            Date,
            allocatedBytes: Int64,
            identity: FileSystemIdentityProvider.Identity
        )
        case vanished
        case failed(DenialCause)
    }

    /// `leafMetadata` collapses absence, failure and out-of-domain metadata
    /// into one nil, so the nil path re-probes: the ENOENT contract and the
    /// errno classification both depend on telling those apart.
    private func leafDate(of url: URL) -> LeafDate {
        if let metadata = provider.leafMetadata(of: url) {
            return .dated(
                Self.modificationDate(of: metadata),
                allocatedBytes: metadata.allocatedBytes,
                identity: FileSystemIdentityProvider.Identity(
                    device: metadata.device, inode: metadata.inode
                )
            )
        }
        switch provider.probeKind(of: url) {
        case .absent:
            return .vanished
        case .failed(let code):
            return .failed(.rawErrno(code))
        case .kind:
            // Present and lstat-able, yet its metadata is outside the pinned
            // value domains — undatable, so its staleness is unprovable.
            return .failed(.metadataUnavailable)
        }
    }

    /// The integer `lstat` mtime as a `Date`. Nanoseconds are in `[0, 1e9)` by
    /// `LeafMetadata`'s own domain guarantee.
    static func modificationDate(
        of metadata: FileSystemIdentityProvider.LeafMetadata
    ) -> Date {
        Date(
            timeIntervalSince1970: TimeInterval(metadata.modifiedSeconds)
                + TimeInterval(metadata.modifiedNanoseconds) / 1_000_000_000
        )
    }

    /// BOUNDED directory read: at most `limit` basenames plus whether the read
    /// was PROVEN exhaustive; the errno when the directory could not even be
    /// opened.
    ///
    /// `opendir`/`readdir` rather than `FileManager`, deliberately: both
    /// `contentsOfDirectory` overloads materialize the WHOLE directory before
    /// any cap can apply, which would let one hostile directory defeat the
    /// bound of the very probe whose contract is to stay cheap — the exact
    /// trap `ValuablesDetector.boundedChildNames` was written for. It is
    /// re-implemented here rather than shared because that helper is private
    /// to its own bounded probe and widening it is shared-substrate surgery
    /// this task does not carry; a later consolidation is the right home.
    ///
    /// Three traps this must not fall into: `readdir` returns nil for BOTH
    /// end-of-stream and error (errno is the only discriminator, so it is
    /// cleared before every call); an undecodable basename fails CLOSED
    /// (`String(validatingCString:)` — a U+FFFD-repaired name would address a
    /// DIFFERENT path, and an `lstat` of that lie would report "absent",
    /// letting the walk call a tree all-old while a fresh file went
    /// uninspected); and `.`/`..` are skipped while hidden entries are kept.
    private enum BoundedRead {
        case names([String], truncated: Bool)
        case failed(errno: Int32)
    }

    private static func boundedChildNames(
        of directory: URL, limit: Int
    ) -> BoundedRead {
        guard let handle = opendir(directory.path) else {
            return .failed(errno: errno)
        }
        defer { closedir(handle) }
        var names: [String] = []
        var truncated = false
        while true {
            errno = 0
            guard let entry = readdir(handle) else {
                if errno != 0 { truncated = true }
                break
            }
            let decoded = withUnsafeBytes(of: entry.pointee.d_name) {
                raw -> String? in
                guard let base = raw.bindMemory(to: CChar.self).baseAddress
                else { return nil }
                return String(validatingCString: base)
            }
            guard let name = decoded, !name.isEmpty else {
                // Undecodable: the directory is already unproven, and reading
                // on would let a directory full of such names spend the whole
                // budget.
                truncated = true
                break
            }
            if name == "." || name == ".." { continue }
            guard names.count < limit else {
                truncated = true
                break
            }
            names.append(name)
        }
        return .names(names, truncated: truncated)
    }

    // MARK: - Cooperative lock probe (R6, epic D2 revised)

    /// The PRODUCTION probe:
    /// `open(O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK)` — valid for files AND
    /// directories on Darwin — then a kind gate on the descriptor, then a
    /// non-blocking exclusive `flock`. EWOULDBLOCK is the only in-use answer;
    /// a successful lock is dropped immediately (closing the descriptor would
    /// drop it anyway, but the release is explicit so the scan never holds a
    /// lock while it sizes).
    ///
    /// `O_NONBLOCK` IS AN AVAILABILITY GUARD, NOT A PERFORMANCE HINT
    /// (PR #459 review r3). This open cannot carry `O_DIRECTORY` — a
    /// regular-file candidate must open too — so it is the driver's `open`
    /// that runs, and a FIFO with no writer standing at this name BLOCKS
    /// FOREVER. Measured on this platform: without `O_NONBLOCK` this exact
    /// flag set did not return in 3s against `mkfifo`, and a REAL
    /// `scanner.scan(context:)` driven through it never returned; with the
    /// flag the open returns immediately and `fstat` reports `S_IFIFO`. The
    /// scan body runs directly on a Swift cooperative-pool worker with no
    /// timeout anywhere downstream, so a block here consumes that thread for
    /// the life of the process and strands the whole scan session (the
    /// `SpaceScanner` task group never drains, so `CacheoutViewModel`'s
    /// re-entrancy guard — which gates every later scan AND every `clean()` —
    /// is never released, and the CLI/MCP consumer hangs identically).
    /// `/private/tmp` is world-writable: the sticky bit stops another user
    /// renaming your entry, but once its owner unlinks the name any user may
    /// `mkfifo` it. This is the scan-time twin of the delete-time re-open in
    /// `revalidateTempEntry`, which carries the same flag for the same reason.
    ///
    /// An `open` FAILURE is never "in use": ENOENT/ENOTDIR/ELOOP are race
    /// skips (ELOOP means the entry became a symlink after dispatch — the
    /// no-follow flag refusing to open it is the point), and everything else
    /// joins the raw-errno denial accounting. Any OTHER `flock` errno means
    /// "no advisory holder proven" and the candidate proceeds.
    ///
    /// Scope, honestly: this sees advisory `flock` holders on the CANDIDATE
    /// INODE only. It does not and cannot see a process holding a descendant
    /// file open for ordinary reading. It also cannot bound the time the
    /// `open` itself takes on a slow or wedged filesystem — `O_NONBLOCK`
    /// removes the FIFO/device wait, not an unresponsive vnode.
    static func cooperativeLockProbe(_ url: URL) -> LockProbe {
        let descriptor = open(
            url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR || code == ELOOP {
                return .vanished
            }
            return .failed(errno: code)
        }
        defer { close(descriptor) }

        // THE KIND GATE ON THE SUCCESSFUL OPEN (PR #459 review r3) — the
        // scan-time twin of `revalidateTempEntry`'s gate (0). `O_NONBLOCK`
        // converts "hang" into "opened a FIFO"; without this arm that FIFO
        // would fall through to the `flock` below, which answers ENOTSUP
        // (45, MEASURED — not EWOULDBLOCK, 35), so the ternary would report
        // `.available` and carry a special file on to sizing and emission.
        // `.vanished` is the right disposition and not a new one: root-level
        // `probeKind` already skips `.other` silently, and everything this
        // probe can be asked about arrived through that same filter.
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let code = errno
            return .failed(errno: code)
        }
        switch FileSystemIdentityProvider.fileKind(from: status) {
        case .regularFile, .directory:
            break
        case .symlink, .other:
            return .vanished
        }

        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return .available
        }
        return errno == EWOULDBLOCK ? .inUse : .available
    }

    // MARK: - Denial classification (R5, epic D8 r6)

    /// WHERE a denial came from — the operation class its classification is
    /// derived from (see the file header). Never a bare errno on its own: the
    /// provenance is what makes `.tccDenied` assertable or not.
    private enum DenialCause {
        /// Raw-errno probes: `probeKind`, `ownerProbe`, the pre-filter's
        /// `lstat`/`opendir`, the lock probe's `open`.
        case rawErrno(Int32)
        /// A Foundation throw carrying the Cocoa/POSIX `NSUnderlyingErrorKey`
        /// chain — the ONLY provenance-bearing signal available.
        case cocoaChain(Error)
        /// Present and lstat-able, but its metadata is unusable.
        case metadataUnavailable
        /// A `SizeDenial` from the stage-2 walk, folded into the per-root
        /// accounting (freshness-suppressed candidates).
        case sizing(SizeDenial)
    }

    /// The ONE classifier — kind + detail, per operation class. No blanket
    /// rewrite in either direction (epic D8 r6).
    private static func classify(
        _ cause: DenialCause, at url: URL
    ) -> (kind: ScanIssue.Kind, detail: String) {
        switch cause {
        case .rawErrno(let code):
            let text = String(cString: strerror(code))
            switch code {
            case EACCES:
                // Unambiguous BSD permissions.
                return (.permissionDenied, "\(url.path): \(text)")
            case EPERM:
                // NEUTRAL on purpose: a bare errno carries no provenance, so
                // neither a privacy denial nor a filesystem refusal may be
                // asserted. Sticky-directory rules govern unlink/rename — they
                // prove nothing about an lstat traversal.
                return (.unreadable, "\(url.path): \(text) — the cause could "
                        + "not be established (a privacy denial and a "
                        + "filesystem refusal are indistinguishable here)")
            default:
                return (.unreadable, "\(url.path): \(text)")
            }
        case .cocoaChain(let error):
            // The provenance-bearing class: preserve a chain-proven TCC
            // signal — it is a real grant hint, and rewriting it would
            // suppress the user's remedy.
            let denial = DirectorySizer.classifyDenial(error, at: url)
            switch denial.kind {
            case .tcc:
                return (.tccDenied, "\(url.path): \(denial.detail)")
            case .permission:
                return (.permissionDenied, "\(url.path): \(denial.detail)")
            // `.unaddressablePath` joins the neutral arm (PR #458 added the
            // case; this scanner predates it). It means the tree is nested
            // deeper than an absolute path can address, so the SIZER could
            // not read it — `.unreadable` is the honest kind, and the detail
            // carries the real cause. Deletion is unaffected: the remover is
            // descriptor-relative and handles such trees whole.
            case .metadata, .other, .unaddressablePath:
                return (.unreadable, "\(url.path): \(denial.detail)")
            }
        case .metadataUnavailable:
            return (.unreadable, "\(url.path): metadata unavailable")
        case .sizing(let denial):
            // `SizeDenial.Kind.tcc` conflates chain-proven denials with
            // raw-probe guesses and the only discriminator is a message
            // string, so it stays NEUTRAL here; the detail is preserved
            // verbatim so nothing is hidden.
            switch denial.kind {
            case .permission:
                return (.permissionDenied,
                        "\(denial.url.path): \(denial.detail)")
            case .tcc, .metadata, .other, .unaddressablePath:
                return (.unreadable, "\(denial.url.path): \(denial.detail)")
            }
        }
    }

    private static func denialIssue(
        _ cause: DenialCause, at url: URL, note: String
    ) -> ScanIssue {
        let classified = classify(cause, at: url)
        return ScanIssue(
            url: url, kind: classified.kind,
            detail: "\(note) — \(classified.detail)"
        )
    }

    /// The denial that wins the item's single `scanError` slot.
    ///
    /// `.permission` outranks `.tcc` here — deliberately INVERTED against the
    /// orphaned-caches precedence, whose rationale ("the TCC grant hint is the
    /// most actionable error") does not transfer: under epic D8 r6 a
    /// `.tcc`-kinded `SizeDenial` is NOT assertable as a TCC denial at this
    /// surface, so it maps to a neutral error, and letting it outrank a
    /// provably actionable permission denial would hide the actionable one.
    private static func rankedDenial(_ denials: [SizeDenial]) -> SizeDenial? {
        denials.first { $0.kind == .permission } ?? denials.first
    }

    // MARK: - Item mapping (R8 + R12)

    /// One surviving candidate → one `ReclaimableItem`, or `nil` when a CLEAN
    /// walk left it under the size floor.
    ///
    /// POST-SIZING OUTCOME TABLE (R12) — a clean pre-filter does not guarantee
    /// a clean sizing walk (concurrent churn), and mapping is preferred over
    /// suppression because visibility is the doctrine here. Spam is
    /// structurally impossible: systematic denials (other users' 0700 dirs)
    /// die at the PRE-FILTER, so this table only ever covers the
    /// pre-filter→sizing race window.
    ///
    /// | sizing result                   | state             | components | record            | scanError        |
    /// |---------------------------------|-------------------|------------|-------------------|------------------|
    /// | ANY mount boundary              | `.denied`         | ZERO       | `.deniedUnmeasured`| names the boundary|
    /// | denial(s), measured something   | `.partiallyDenied`| real       | `.measured`       | classified denial |
    /// | denial(s), measured nothing     | `.denied`         | ZERO       | `.deniedUnmeasured`| classified denial |
    /// | clean walk                      | `.measured`       | real       | `.measured`       | NONE              |
    ///
    /// The size FLOOR is trusted only on a clean walk: an anomaly row is
    /// emitted regardless of the floor, because an unmeasurable tree cannot be
    /// honestly floor-evaluated. `.empty` is therefore unreachable — a clean
    /// walk that measured nothing cannot meet a positive floor (this is what
    /// keeps the vacuously-stale empty-old-directory cell off the list).
    private func reclaimableItem(
        entry: URL,
        identity: URL,
        root: EphemeralTempRoot,
        report: SizeReport,
        ownDate: Date,
        scannedIdentity: FileSystemIdentityProvider.Identity,
        now: Date
    ) -> ReclaimableItem? {
        let hasBoundary = report.rootMountBoundary
            || !report.mountBoundaries.isEmpty
        let measuredAnything = report.itemCount > 0 || report.measuredBytes > 0

        let state: ScanState
        if hasBoundary {
            state = .denied
        } else if !report.denials.isEmpty {
            state = measuredAnything ? .partiallyDenied : .denied
        } else {
            // CLEAN walk: the only arm the floor governs.
            guard report.measuredBytes >= thresholds.sizeFloorBytes else {
                return nil
            }
            state = .measured
        }
        let deletable = state == .measured || state == .partiallyDenied

        // Exactly ONE root record; `.deniedUnmeasured` iff nothing deletable
        // was established. `requestedURL` is the UNRESOLVED entry (the
        // deletion input), `resolvedURL` the leaf-preserving identity the item
        // also displays — the validator binds all three to one capture.
        let record = RootScanRecord(
            requestedURL: entry,
            resolvedURL: identity,
            status: state == .denied ? .deniedUnmeasured : .measured
        )

        return ReclaimableItem(
            id: ReclaimableItem.stableID(
                scannerID: Self.registeredID, canonicalPath: identity.path
            ),
            scannerID: Self.registeredID,
            displayName: entry.lastPathComponent,
            // The byte split rides VERBATIM from the `.deletionTarget` report:
            // temp roots can hold hardlinks, whose bytes MAY not be freed by
            // deleting one link — forcing `estimatedUpToBytes` to zero would
            // claim a certainty the walk did not establish. A non-deletable
            // state publishes ZERO components: every consumer reads them as
            // "deletion frees these", and deletion is refused.
            exactBytes: deletable ? report.exactAllocatedBytes : 0,
            estimatedUpToBytes: deletable ? report.estimatedUpToBytes : 0,
            // Only the honest sparse direction (logical exceeding allocated —
            // deletion frees LESS than the apparent size); block-rounding
            // noise stays nil.
            logicalBytes: deletable
                && report.logicalBytes > report.measuredBytes
                ? report.logicalBytes : nil,
            itemCount: deletable ? report.itemCount : 0,
            url: identity,
            declaredDisplayPath: entry.path,
            rootRecords: [record],
            state: state,
            scanError: Self.scanError(
                for: report, candidate: entry, hasBoundary: hasBoundary
            ),
            // Temp payload is another process's business until the user says
            // otherwise: never `.safe`.
            risk: .review,
            evidence: Self.evidence(
                root: root, report: report, ownDate: ownDate, now: now
            ),
            rebuildNote: nil,
            // `.removeItem` — the entry ITSELF is deleted (the Trash toggle is
            // honored by the cleaner like any other item, fn-6.3).
            action: .removeItem,
            admission: .containerItem(
                originContainer: root.url, requestedTargetURL: entry
            ),
            // Never preselected. Note the opt-in is not strictly per entry:
            // the section ships a "Select Stale" button whose handler
            // selects EVERY `isStale == true` selectable row in one click
            // (`ScannerItemSection.swift` → `CacheoutViewModel.selectStale`),
            // so `isStale` is a BULK-SELECTION KEY and its honesty is
            // load-bearing.
            defaultSelected: false,
            // WHAT THIS FLAG ACTUALLY DOES (PR #459 review r1 — the previous
            // comment here asserted a mechanism this code does not have).
            //
            // It is the CLI SMART-CLEAN EXCLUSION and nothing else: the only
            // two consumers are `CacheoutViewModel.safeAutoSelectable` (which
            // also requires `risk == .safe`, so `.review` already excludes
            // temp items there) and `CLIHandler.smartCleanCandidates`, which
            // DOES admit `.review` items — so this `false` is the one thing
            // keeping temp entries out of an unattended smart clean.
            //
            // IT HAS NO BEARING ON THE DELETE-TIME REVALIDATOR DISPATCH. That
            // dispatch (`CacheCleaner.preDeleteOutcome`) reads the scanner-ID
            // registry and the item's `requiresPreDeleteRevalidation` marker;
            // it never reads this flag. The ten `build_artifacts` rules ship
            // `automaticCleanEligible: false` and every one of their items is
            // revalidated. Temp items are revalidated too — see
            // `preDeleteRevalidator` at the foot of this file.
            automaticCleanEligible: false,
            // Every emitted item passed the two-stage staleness rule AND the
            // post-sizing freshness re-check. Their AS-OF times differ and the
            // comment here used to flatten them (PR #459 review r2): the
            // entry's OWN mtime is re-read at sizing COMPLETION, while the
            // content half is only as fresh as the walk that collected it —
            // `newestContentDate` is accumulated per file DURING sizing and
            // stage 1's walk ran before it. See `directoryStaleness` for the
            // escape that leaves open. Both are re-established against the
            // current filesystem immediately before deletion by
            // `preDeleteRevalidator` — this flag is a scan-time fact, not a
            // delete-time one.
            isStale: true,
            // The BRACES half of the belt-and-braces dispatch: this scanner
            // declares a revalidator whose applicability is "every temp item",
            // so every emitted item must carry the marker or
            // `SpaceScanner.revalidationMarkerViolation` malforms the whole
            // outcome.
            requiresPreDeleteRevalidation: true,
            // THE OBJECT THIS ROW IS ABOUT (PR #459 review r2; r4 closed its
            // front edge). Without it the delete-time re-check re-established
            // four PROPERTIES of whatever stood at the name and never asked
            // whether it was the same thing — a replacement's inode got bound
            // and destroyed while the row quoted the scanned entry's bytes.
            // r2's capture point was the POST-sizing lstat, so a swap landing
            // before it recorded the replacement and the row was a chimera
            // (the sized object's bytes, the replacement's identity); since
            // r4 the identity is pinned to STAGE 1's observation, so this
            // value provably names the object every scan stage inspected.
            scannedTargetIdentity: scannedIdentity
        )
    }

    /// The single `scanError`, TOTAL by construction for every denied-family
    /// state (a `.denied`/`.partiallyDenied` item with a nil error is a
    /// state-coherence violation that malforms the WHOLE outcome).
    ///
    /// A mount boundary wins the slot per the R12 table: no grant lifts it,
    /// and it is why the item publishes zero components at all.
    private static func scanError(
        for report: SizeReport, candidate: URL, hasBoundary: Bool
    ) -> ScanError? {
        if hasBoundary {
            // `mountBoundaries.first` is empty exactly when the boundary IS
            // the candidate root, so the fallback keeps this total.
            let boundary = report.mountBoundaries.first ?? candidate
            var message = report.rootMountBoundary
                ? "\(boundary.path): entry is a mount point — not measured; "
                    + "deletion would be refused"
                : "mount boundary at \(boundary.path) — subtree not measured; "
                    + "deletion would be refused"
            if report.itemCount > 0 || report.measuredBytes > 0 {
                let floor = CleanupReport.componentPhrase(
                    exact: report.exactAllocatedBytes,
                    estimatedUpTo: report.estimatedUpToBytes
                )
                message += " (\(floor) measured beside the boundary is not "
                    + "reclaimable while the boundary remains)"
            }
            return ScanError(kind: .other, message: message)
        }
        guard let ranked = rankedDenial(report.denials) else { return nil }
        // Per-kind classification (epic D8 r6, class (c)): a `.permission`
        // denial is assertable; a `.tcc`-kinded one is NOT at this surface, so
        // it becomes a NEUTRAL `.other` with its detail preserved verbatim.
        return ScanError(
            kind: ranked.kind == .permission ? .permissionDenied : .other,
            message: "\(ranked.url.path): \(ranked.detail)"
        )
    }

    /// The item's one evidence string: where it lives, how old its newest
    /// dated content is, and the root's NON-CONTRACTUAL OS-cleanup line
    /// (fn-6.1, epic D7 revised — nothing here promises what macOS will or
    /// will not delete, and no observed reaper mechanics appear in shipped
    /// copy).
    private static func evidence(
        root: EphemeralTempRoot, report: SizeReport, ownDate: Date, now: Date
    ) -> String {
        let ageLine: String
        if let newest = report.newestContentDate {
            ageLine = "newest content is \(days(from: newest, to: now)) days old"
        } else {
            // Nothing datable was enumerated (an empty, denied or
            // boundary-voided tree): the entry's own mtime is the honest
            // figure, and it is labelled as such.
            ageLine = "last modified \(days(from: ownDate, to: now)) days ago"
        }
        return "in \(root.label); \(ageLine); \(root.cleanupEvidence)"
    }

    /// Whole days between two instants, floored at 0 (a clock that moved
    /// backwards must not print a negative age).
    private static func days(from date: Date, to now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(date) / 86_400))
    }

    private static func describe(
        _ kind: FileSystemIdentityProvider.FileKind
    ) -> String {
        switch kind {
        case .regularFile: return "regular file"
        case .directory: return "directory"
        case .symlink: return "symlink"
        case .other: return "special file"
        }
    }

    // MARK: - Delete-time revalidation (PR #459 review r1)

    /// This scanner's DELETE-TIME revalidator, following the
    /// `build_artifacts` precedent exactly (`BuildArtifactsScanner.swift`).
    ///
    /// WHY IT EXISTS — the decision it replaces. Epic D1 recorded that these
    /// items "are simply never applicable" to the revalidation seam because
    /// they set `automaticCleanEligible: false`, carry no marker and declare
    /// no revalidator. Only the THIRD conjunct did any work: the dispatch
    /// (`CacheCleaner.preDeleteOutcome`) is keyed by `item.scannerID` and
    /// reads the marker; it never reads `automaticCleanEligible` (the ten
    /// `automaticCleanEligible: false` build-artifact rules whose items ALL
    /// revalidate are the counter-example in this same repo). So the residual
    /// was accepted on a mechanism the code did not have, and what actually
    /// routed temp items around the seam was the nil revalidator alone.
    ///
    /// WHAT THE NIL COST. With no verdict the cleaner set `probedObject =
    /// nil`, which (a) skipped the final identity check entirely, (b) made
    /// `DepthSafeRemoval.proveInspectedRoot` return without comparing an
    /// inode, and (c) routed the GUI's DEFAULT Trash disposal to the
    /// identity-blind `TrashDisposal.dispose(_:containedIn:…)` overload, which
    /// binds whatever stands at the name NOW. Nothing between the scan and the
    /// destructive call re-read a single fact about the entry's CONTENT: the
    /// four gates that made deletion acceptable (ownership, the two-stage
    /// staleness rule, the cooperative lock probe, the freshness re-check) all
    /// ran at scan time and none of them re-ran.
    ///
    /// WHAT THIS DOES. Every temp item is re-inspected from a HELD
    /// DESCRIPTOR, in the scan's pinned order, with the object's own identity
    /// checked first: kind → RECORDED IDENTITY → ownership → own-mtime
    /// staleness → cooperative `flock` → the size-floor qualification →
    /// fresh content below (for a directory the floor is judged on the walk's
    /// own deduped allocated sum, so it comes with the content verdict —
    /// PR #459 review r4, codex C4: the list here used to omit the floor,
    /// which the file arm re-checked and the directory arm did not). Any of
    /// them failing is a fail-closed `.refuse` with a CLEARABLE sentence —
    /// these conditions are non-deterministic, so the "re-scan" remedy the UI
    /// prints genuinely can differ (unlike a fixed depth cap, which a re-scan
    /// reproduces identically for ever).
    ///
    /// THE IDENTITY CHECK IS WHAT MAKES THE OTHERS MEAN ANYTHING (PR #459
    /// review r2). Ownership, staleness, the lock probe and the content walk
    /// each re-establish a PROPERTY of whatever now answers to the name; only
    /// `item.scannedTargetIdentity` says it is the same OBJECT. Without it an
    /// old, unlocked, user-owned tree moved onto the name after the scan
    /// passed all four gates and was deleted in the scanned entry's place.
    ///
    /// WHAT IS ACTUALLY CONSTRUCTION STATE, stated exactly (the comment here
    /// used to claim "the SAME clock … so scan-time and delete-time can never
    /// disagree on the boundary"): the THRESHOLDS and the CLOCK SOURCE are
    /// construction state; the BOUNDARY IS NOT. Production injects
    /// `now: { Date() }`, so `cutoff = now() - staleAge` is re-evaluated on
    /// every verdict and ADVANCES between scan and delete — in the PERMISSIVE
    /// direction, since a later cutoff makes more things count as stale. An
    /// entry that was stale at scan time is therefore still stale here unless
    /// it was touched; the boundary can never move the other way. Tests inject
    /// a fixed clock, which is what pins the thresholds side.
    ///
    /// AND THE ALLOW CARRIES A BINDING. `.directory(identity)` is the `fstat`
    /// of the descriptor this revalidation held open the whole time — not a
    /// re-`lstat` of the path, which is exactly what an attacker re-points.
    /// That is what makes `probedObject` non-nil in the cleaner, which is what
    /// makes the removal prove the inode it opens and the Trash arm prove the
    /// object on both sides of the move. A revalidator that refused correctly
    /// but returned `.unestablished` would bind nothing, and per house
    /// doctrine that is not a binding at all.
    var preDeleteRevalidator: PreDeleteRevalidator? {
        Self.preDeleteRevalidator(
            roots: roots, thresholds: thresholds, provider: provider,
            prefilterEntryLimit: prefilterEntryLimit, now: now
        )
    }

    /// The revalidator VALUE, constructible without a scanner instance so a
    /// cleaner built directly (tests, headless paths) can register exactly
    /// what production registers.
    ///
    /// APPLICABILITY: `{ _ in true }` — EVERY temp item, no flag anywhere in
    /// the predicate (the `build_artifacts` rule verbatim). The predicate is
    /// pure and does no I/O: it is also called during scan-time validation.
    static func preDeleteRevalidator(
        roots: [EphemeralTempRoot],
        thresholds: EphemeralTempSweepConfig.Thresholds,
        provider: FileSystemIdentityProvider,
        prefilterEntryLimit: Int =
            EphemeralTempScanner.defaultPrefilterEntryLimit,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> PreDeleteRevalidator {
        // The ownership gate is scoped by the DECLARED writability class, the
        // same way the scan scopes it — captured here as a plain path set so
        // the closure stays `Sendable` and reads no scanner state.
        let worldWritableRoots = Set(
            roots.filter { $0.writability == .worldWritable }.map(\.url.path)
        )
        let staleAge = thresholds.staleAge
        let sizeFloorBytes = thresholds.sizeFloorBytes
        let entryLimit = prefilterEntryLimit
        return PreDeleteRevalidator(
            requiresRevalidation: { _ in true },
            revalidate: { item, _ in
                guard case .containerItem(let origin, let target) =
                        item.admission
                else {
                    // Structurally unreachable (the validator and the cleaner
                    // both refuse a `.removeItem` item without the container
                    // descriptor) — fail closed rather than assume a target.
                    return .refuse(
                        reason: "refused: a temp item without a "
                            + "container-item target cannot be re-inspected "
                            + "before deletion",
                        valuables: [], acknowledgementToken: nil
                    )
                }
                guard let scanned = item.scannedTargetIdentity else {
                    // FAIL CLOSED. Every item this scanner emits records one
                    // (see `reclaimableItem` — since r4 pinned to the object
                    // STAGE 1 gated, not merely the post-sizing lstat's), so
                    // an item reaching here without it was not produced by
                    // this scanner's scan — and an identity the re-check
                    // cannot compare is one it cannot prove.
                    return .refuse(
                        reason: "\(target.path): this temp item carries no "
                            + "record of the object the scan inspected, so "
                            + "the delete-time re-check cannot prove it is "
                            + "still the same one — refused, nothing deleted; "
                            + "re-scan required",
                        valuables: [], acknowledgementToken: nil
                    )
                }
                return revalidateTempEntry(
                    at: target,
                    scanned: scanned,
                    ownershipGated: worldWritableRoots.contains(origin.path),
                    cutoff: now().addingTimeInterval(-staleAge),
                    sizeFloorBytes: sizeFloorBytes,
                    entryLimit: entryLimit,
                    provider: provider
                )
            }
        )
    }

    /// The delete-time re-inspection of ONE candidate, anchored on a
    /// descriptor held for the whole verdict.
    private static func revalidateTempEntry(
        at target: URL,
        scanned: FileSystemIdentityProvider.Identity,
        ownershipGated: Bool,
        cutoff: Date,
        sizeFloorBytes: Int64,
        entryLimit: Int,
        provider: FileSystemIdentityProvider
    ) -> PreDeleteVerdict {
        func refuse(_ reason: String) -> PreDeleteVerdict {
            .refuse(reason: reason, valuables: [], acknowledgementToken: nil)
        }

        // THE HELD DESCRIPTOR. One syscall, so there is no window between
        // deciding what stands here and taking hold of it. `O_NOFOLLOW` is
        // what makes the answer trustworthy: an entry swapped for a symlink
        // since the scan fails here (ELOOP) instead of being followed. Valid
        // for directories AND regular files on Darwin.
        //
        // (PR #459 review r3: the sentence that stood here called this "the
        // same open the scan's own lock probe performs". When it was written
        // the two flag sets differed by exactly `O_NONBLOCK` — the flag this
        // very block is about — and the one it named as identical was the one
        // that could block. `cooperativeLockProbe` now carries `O_NONBLOCK`
        // too, so the flag sets ARE identical again; naming the relationship
        // is left to that function's own comment rather than restated here,
        // where it can drift a second time.)
        //
        // `O_NONBLOCK` IS AN AVAILABILITY GUARD, NOT A PERFORMANCE HINT
        // (PR #459 review r2). This open cannot carry `O_DIRECTORY` — a
        // regular-file candidate must open too — so it is the driver's `open`
        // that runs, and a FIFO standing at this name BLOCKS FOREVER waiting
        // for a writer. Measured on this platform: the identical flag set
        // without `O_NONBLOCK` did not return in 3s against `mkfifo`; with it
        // the open returns immediately and `fstat` reports `S_IFIFO`.
        // `/private/tmp` is world-writable (this scanner's own root comment
        // notes it holds live top-level sockets), so any user can plant one at
        // a scanned name. There is no timeout anywhere downstream:
        // `CacheCleaner` is an `actor` and `preDeleteOutcome` calls
        // `revalidate` synchronously, so a block here wedges the clean and
        // every later message to that actor for the life of the process.
        // `O_NONBLOCK` changes nothing for a directory or a regular file; it
        // only converts "hang" into "opened, and refused below as the wrong
        // kind of object". `DepthSafeRemoval` documents the `O_DIRECTORY`
        // half of the same hazard.
        let descriptor = open(
            target.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            let code = errno
            return refuse(
                "\(target.path): this temp entry could not be re-opened for "
                    + "its delete-time re-check "
                    + "(\(String(cString: strerror(code)))) — refused, "
                    + "nothing deleted; re-scan required"
            )
        }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            return refuse(
                "\(target.path): this temp entry would not describe itself at "
                    + "delete time — refused, nothing deleted; re-scan required"
            )
        }
        // (0) THE KIND GATE, and it is a DELETE-TIME fact (PR #459 review r2).
        // The comment that stood on the trailing arm called a special file
        // "unreachable, because the scan never emits one" — a scan-time fact
        // asserted inside the one function whose entire premise is that
        // scan-time facts expire. It is reachable: a FIFO opens successfully
        // under `O_NONBLOCK` (that is what the flag is for), and so does a
        // device node whose driver admits the open (measured: `/dev/null`);
        // `fileKind(from:)` maps every non-REG/DIR/LNK `S_IFMT` to `.other`.
        // (A bound AF_UNIX socket never gets this far — `open(2)` fails
        // EOPNOTSUPP, errno 102, measured with and without `O_NONBLOCK` — so
        // it is refused ABOVE at the open, not here; r3's comment claimed it
        // arrived through a successful open, which was false.) `.symlink` is
        // the one arm the open really does foreclose — `O_NOFOLLOW` fails
        // ELOOP — but it costs nothing to refuse both here, and refusing at
        // the top means the regular-file and directory arms below are
        // reached only by objects this scanner can actually have listed.
        let kind = FileSystemIdentityProvider.fileKind(from: status)
        switch kind {
        case .regularFile, .directory:
            break
        case .symlink, .other:
            return refuse(
                "\(target.path): this temp entry is no longer the kind of "
                    + "object that was scanned — refused, nothing deleted; "
                    + "re-scan required"
            )
        }

        // The IDENTITY that travels in the verdict is read through the
        // provider, because that is what `DepthSafeRemoval.proveInspectedRoot`
        // and `TrashDisposal` compare it against — one accessor on both sides,
        // so a test override can never manufacture a divergence production
        // cannot produce.
        guard let identity = provider.identity(ofDescriptor: descriptor) else {
            return refuse(
                "\(target.path): this temp entry would not identify itself at "
                    + "delete time — refused, nothing deleted; re-scan required"
            )
        }

        // (0b) IS THIS THE OBJECT THE SCAN INSPECTED? (PR #459 review r2;
        // literal since r4 — the recorded identity was previously only the
        // POST-sizing lstat's observation, which a swap during sizing could
        // make the replacement's; the scan now pins it to stage 1's, so
        // "the object the scan inspected" means every stage of it.)
        //
        // Every other gate in this function re-establishes a PROPERTY of
        // whatever stands at the name; none of them asks whether it is the
        // same THING. Without this comparison a replacement was caught only
        // EMERGENTLY — when it happened to be fresh, locked or foreign-owned.
        // `mv /some/old/tree /private/tmp/old-scratch` (old, unlocked,
        // user-owned) passed all four, and the `.allow` below then bound the
        // REPLACEMENT's inode, so the deletion proved the wrong object and
        // destroyed it while the row still quoted the scanned entry's bytes
        // and age.
        //
        // Compared against the (device, inode) the SCAN recorded on the item,
        // read from the descriptor this verdict holds — not a path `lstat`,
        // which is what a replacement re-points. A directory that was never
        // replaced keeps its inode, so this refuses only genuine replacement;
        // a legitimately re-created entry IS a different object and refusing
        // it is the point. The refusal is CLEARABLE by re-scanning, like every
        // other refusal here.
        guard identity == scanned else {
            return refuse(
                "\(target.path): a different \(describe(kind)) now stands at "
                    + "this temp entry's name — it is not the one that was "
                    + "scanned; refused, nothing deleted. Re-scan to see what "
                    + "is there now"
            )
        }

        // (1) OWNERSHIP, re-established from the HELD DESCRIPTOR (never a
        // path `stat`, which is what gets re-pointed). Under a world-writable
        // root a foreign-owned entry is undeletable by sticky-directory rules
        // anyway; refusing here names the reason instead of letting the
        // remover fail with a bare errno. An unreadable uid is unprovable, and
        // unprovable is not "ours".
        if ownershipGated {
            guard let owner = provider.ownerUID(ofDescriptor: descriptor),
                  owner == geteuid()
            else {
                return refuse(
                    "\(target.path): this temp entry no longer belongs to you "
                        + "— refused, nothing deleted; re-scan required"
                )
            }
        }

        // (2) OWN-MTIME STALENESS, the required half of the two-stage rule
        // (see `directoryStaleness`'s truth table: a fresh own mtime
        // disqualifies an entry whose every regular file is old). Writing a
        // file into a directory bumps the directory's own mtime, so this alone
        // catches a reactivated scratch directory.
        guard let metadata = FileSystemIdentityProvider
            .leafMetadata(from: status)
        else {
            return refuse(
                "\(target.path): this temp entry's modification time is "
                    + "outside the readable range, so its staleness cannot be "
                    + "re-established — refused, nothing deleted"
            )
        }
        let ownDate = modificationDate(of: metadata)
        guard ownDate < cutoff else {
            return refuse(
                "\(target.path): this temp entry was modified again after the "
                    + "scan — it is newer than the staleness threshold; "
                    + "refused, nothing deleted. Re-scan to see its current "
                    + "state"
            )
        }

        // (3) THE COOPERATIVE LOCK PROBE, on the descriptor already held —
        // strictly better than the scan's, which had to re-open by path.
        // EWOULDBLOCK is still the ONLY in-use signal; any other `flock`
        // failure proves no advisory holder and is not a refusal.
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
        } else if errno == EWOULDBLOCK {
            return refuse(
                "\(target.path): this temp entry is locked by a running "
                    + "process — it is in use again; refused, nothing deleted. "
                    + "Re-scan once the process has finished"
            )
        }

        guard kind == .directory else {
            // A REGULAR FILE — the only other kind gate (0) admits. It has no
            // contents to walk; its own allocation is the floor input stage 1
            // used.
            guard metadata.allocatedBytes >= sizeFloorBytes else {
                return refuse(
                    "\(target.path): this temp file has shrunk below the size "
                        + "threshold since the scan — refused, nothing "
                        + "deleted; re-scan required"
                )
            }
            // `.noDirectoryTree` is the honest binding for a non-directory
            // leaf: the deletion's `ENOTDIR` arm proves no directory tree has
            // appeared at this name since, and the Trash arm's `look` (an
            // `O_DIRECTORY` open) agrees. It is the SAME verdict the sweep's
            // probe returns for the same shape.
            return .allow(inspected: .noDirectoryTree)
        }

        var budget = entryLimit
        // DELETE-TIME ALLOCATION rides the walk for free (PR #459 review r4,
        // codex C4): the walk already demands `LeafMetadata` for every
        // regular file and the probe already returns its identity, so the
        // sum costs zero extra syscalls and zero budget. Deduped by inode
        // WITHIN the walk, matching the scan's hardlink accounting
        // (`DirectorySizer`'s within-walk dedupe).
        var deleteTimeAllocatedBytes: Int64 = 0
        var seenInodes = Set<FileSystemIdentityProvider.Identity>()
        switch freshContentBelow(
            descriptor: descriptor, at: target, cutoff: cutoff,
            budget: &budget, allocatedBytes: &deleteTimeAllocatedBytes,
            seenInodes: &seenInodes, provider: provider
        ) {
        case .allOld:
            // THE FLOOR, re-established for the DIRECTORY arm too (r4, codex
            // C4 — the file arm above refused the identical drift while a
            // directory whose nested payload vanished after the scan sailed
            // to `.allow`, executing an offer the scan would refuse to make:
            // the floor is the entry's QUALIFICATION gate for both kinds,
            // at the scan's stage 1 for files and its outcome mapping for
            // directories). Evaluated only on `.allOld`, i.e. a walk
            // proven exhaustive within budget, and the refusal CONVERGES:
            // a re-scan measures the shrunk tree below the floor and
            // declines to list it, so the row disappears instead of
            // re-offering. A partially-denied item reaches here only once
            // its denial has cleared, at which point a fresh scan would
            // also decline a below-floor tree — same semantics. Residual at
            // measured scope: `st_blocks*512` agreed with
            // `totalFileAllocatedSize` on 3/3 probes (plain, sparse-zero,
            // decmpfs-compressed); a filesystem where the two straddle the
            // exact floor could refuse a boundary-sitting offer until
            // re-scan.
            guard deleteTimeAllocatedBytes >= sizeFloorBytes else {
                return refuse(
                    "\(target.path): this temp directory has shrunk below "
                        + "the size threshold since the scan — refused, "
                        + "nothing deleted; re-scan required"
                )
            }
            // THE BINDING. `fstat` of the descriptor this whole verdict
            // was taken through — the deletion proves the inode it opens
            // is this one, on both the permanent and the Trash arm.
            return .allow(inspected: .directory(identity))
        case .freshContent(let url):
            return refuse(
                "\(target.path): fresh content (\(url.lastPathComponent)) "
                    + "was written inside this temp entry since the scan "
                    + "— refused, nothing deleted. Re-scan to see its "
                    + "current state"
            )
        case .unprovable(let detail):
            return refuse(
                "\(target.path): this temp entry's contents could not be "
                    + "fully re-inspected at delete time (\(detail)) — "
                    + "refused, nothing deleted (an inspection that could "
                    + "not finish is treated like a change since scan); "
                    + "re-scan required"
            )
        }
    }

    /// The delete-time answer to "is anything below this entry fresh?".
    private enum DeleteTimeFreshness {
        /// Every regular file below was proven older than the cutoff.
        case allOld
        /// The first at-or-newer regular file, which ends the walk.
        case freshContent(URL)
        /// The walk could not be proven exhaustive — a denial, an
        /// undescribable entry, or the entry budget. NEVER "still stale".
        case unprovable(String)
    }

    /// The DESCRIPTOR-RELATIVE twin of `walkForFreshContent`: the same
    /// early-exit rule (the FIRST regular file at-or-newer than the cutoff
    /// disqualifies the whole entry) and the same entry budget, but every
    /// level below the held root is reached by `fstatat`/`openat` on the
    /// descriptor above it rather than by re-resolving a path. Containment in
    /// the held parent inode is the proof; nothing here re-reads a path.
    ///
    /// Recursion, not an explicit stack, holds exactly one descriptor per
    /// level of the CURRENT DFS path (closed on the way back out). An
    /// `openat` that fails for any reason other than a vanished branch —
    /// including descriptor exhaustion — makes the verdict UNPROVABLE, and
    /// unprovable refuses.
    ///
    /// The budget cannot STRAND a real offer, but listed entries DO reach it
    /// (PR #459 review r4 — the sentence here claimed an entry whose tree
    /// exceeds the budget "is never listed and never reaches this code",
    /// conflating scan-time with delete-time tree shape, the precise
    /// conflation the kind gate's own comment condemns): a listed entry's
    /// tree can GROW past the budget between scan and delete — mkdir spam in
    /// a nested subdirectory bumps no root mtime and adds no fresh regular
    /// file — and then arrives here, where the budget refusal takes it. No
    /// strand: a re-scan's stage-1 walk declines to list the overgrown tree,
    /// so the refusal converges.
    ///
    /// `allocatedBytes` accumulates the walk's DEDUPED regular-file
    /// allocation (r4, codex C4) so the caller can re-establish the size
    /// floor: metadata is already mandatory per regular file, and the probe
    /// already returns identity — zero extra syscalls, zero budget spent.
    ///
    /// `logical` URLs are composed for the refusal message and for the
    /// provider's test seam only — they address nothing.
    private static func freshContentBelow(
        descriptor: Int32,
        at directory: URL,
        cutoff: Date,
        budget: inout Int,
        allocatedBytes: inout Int64,
        seenInodes: inout Set<FileSystemIdentityProvider.Identity>,
        provider: FileSystemIdentityProvider
    ) -> DeleteTimeFreshness {
        guard budget > 0 else {
            return .unprovable("more entries than the inspection budget")
        }
        let read = boundedChildNames(
            ofDescriptor: descriptor, limit: budget, provider: provider
        )
        let names: [String]
        switch read {
        case .failed(let code):
            if code == ENOENT || code == ENOTDIR {
                // The branch vanished mid-walk — the benign race, and there is
                // nothing fresh in a branch that is not there.
                return .allOld
            }
            return .unprovable(String(cString: strerror(code)))
        case .names(let read, let truncated):
            if truncated {
                return .unprovable("a directory could not be read in full")
            }
            names = read
        }

        var pending: [String] = []
        for name in names.sorted(by: {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        }) {
            guard budget > 0 else {
                return .unprovable("more entries than the inspection budget")
            }
            budget -= 1
            let child = directory.appendingPathComponent(name)
            switch provider.probeKind(
                inDirectory: descriptor, named: name, logical: child
            ) {
            case .absent:
                continue
            case .failed(let code):
                return .unprovable(String(cString: strerror(code)))
            case .kind(let kind, let childIdentity, let metadata):
                switch kind {
                case .regularFile:
                    guard let metadata else {
                        return .unprovable(
                            "\(name) would not describe its modification time"
                        )
                    }
                    if modificationDate(of: metadata) >= cutoff {
                        return .freshContent(child)
                    }
                    // Two links to one inode count once, exactly as the
                    // scan's sizer counts them (r4, codex C4).
                    if seenInodes.insert(childIdentity).inserted {
                        allocatedBytes += metadata.allocatedBytes
                    }
                case .directory:
                    pending.append(name)
                case .symlink, .other:
                    // Never followed; neither carries content of its own to
                    // date (the scan's walk ignores them for the same reason).
                    continue
                }
            }
        }

        for name in pending {
            // THE CARRYING FORM (PR #459 review r2). The raw-`Int32`
            // `openChildDirectory` leaves its code in the GLOBAL `errno`, and
            // `FileSystemIdentityProvider` documents that twin as existing
            // precisely because "a test override (or any intervening call) can
            // clobber" it before the caller reads it — which matters here,
            // where ENOENT/ENOTDIR is a benign vanished branch and every other
            // code makes the whole verdict UNPROVABLE, i.e. a refusal.
            let childDescriptor: Int32
            switch provider.openChildDirectoryCarryingErrno(
                inDirectory: descriptor, named: name,
                logical: directory.appendingPathComponent(name)
            ) {
            case .opened(let opened):
                childDescriptor = opened
            case .failed(let code):
                if code == ENOENT || code == ENOTDIR { continue }
                return .unprovable(String(cString: strerror(code)))
            }
            defer { close(childDescriptor) }
            let below = freshContentBelow(
                descriptor: childDescriptor,
                at: directory.appendingPathComponent(name),
                cutoff: cutoff, budget: &budget,
                allocatedBytes: &allocatedBytes, seenInodes: &seenInodes,
                provider: provider
            )
            if case .allOld = below { continue }
            return below
        }
        return .allOld
    }

    /// The BOUNDED read of an already-open directory — `boundedChildNames`'s
    /// descriptor-relative twin, with the identical three traps handled
    /// (`readdir` returning nil for both end-of-stream and error; an
    /// undecodable basename failing CLOSED; `.`/`..` skipped, hidden entries
    /// kept).
    ///
    /// `openSelfForEnumeration` rather than `fdopendir(descriptor)` directly:
    /// `fdopendir` TAKES OWNERSHIP of the descriptor it is handed and
    /// `closedir` would close the anchor this walk is standing on.
    private static func boundedChildNames(
        ofDescriptor descriptor: Int32, limit: Int,
        provider: FileSystemIdentityProvider
    ) -> BoundedRead {
        let enumeration = provider.openSelfForEnumeration(descriptor)
        guard enumeration >= 0 else { return .failed(errno: errno) }
        guard let handle = fdopendir(enumeration) else {
            let code = errno
            close(enumeration)
            return .failed(errno: code)
        }
        defer { closedir(handle) }
        var names: [String] = []
        var truncated = false
        while true {
            errno = 0
            guard let entry = readdir(handle) else {
                if errno != 0 { truncated = true }
                break
            }
            let decoded = withUnsafeBytes(of: entry.pointee.d_name) {
                raw -> String? in
                guard let base = raw.bindMemory(to: CChar.self).baseAddress
                else { return nil }
                return String(validatingCString: base)
            }
            guard let name = decoded, !name.isEmpty else {
                truncated = true
                break
            }
            if name == "." || name == ".." { continue }
            guard names.count < limit else {
                truncated = true
                break
            }
            names.append(name)
        }
        return .names(names, truncated: truncated)
    }
}

// MARK: - SpaceScanner conformance

/// Registration is fn-6.4's (`SpaceScannerRuntime.production`); the witnesses
/// are the members above — including `preDeleteRevalidator`, which this
/// scanner DOES declare (PR #459 review r1). The runtime captures it at
/// registration into the scanner-ID-keyed registry the cleaner dispatches on.
extension EphemeralTempScanner: SpaceScanner {}
