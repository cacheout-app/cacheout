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
/// is never traversed or sized, and the freshness re-check runs BEFORE the
/// post-sizing outcome mapping (a fresh tree offers nothing to reclaim, so it
/// is not listed even when its sizing hit denials — those denials still surface
/// through the per-root accounting).
///
/// ## Trigger policy (epic D11 r5 — the WHOLE scanner)
///
/// The scanner runs ONLY on `.userInitiated` scans. On `.automatic` it defers
/// for ALL THREE roots: no enumeration, no sizing, no items, no issues — the
/// exact silent semantics TCC-protected search roots already have (a deferral
/// is not an anomaly; the roots are scanned when the user asks). The gate is
/// the derived `ScanContext.includeProtectedRoots` (`SpaceScanner.swift:75`),
/// reused deliberately rather than re-derived.
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
/// - **W3** the root-level `probeKind` gate → `contentsOfDirectory` listing —
///   the roots themselves are same-user-replaceable.
///
/// A swap landing inside these causes EXTERNAL METADATA ENUMERATION INTO
/// SIZING at most — never deletion: delete-time admission re-runs no-follow
/// (`CacheCleaner.swift:971-972`), deletion removes the UNRESOLVED leaf
/// (:978-983), and the validator binds the deletion target to the scan record.
/// The identical residual class exists in every as-built per-item scanner
/// (`OrphanedCachesScanner.swift:334-355`). Descriptor (fd) anchoring is the
/// recorded deferred alternative — it is shared-substrate surgery on
/// `DirectorySizer` and belongs to a roadmap-level hardening that benefits all
/// per-item scanners at once. NOTHING here claims a swap is impossible.
///
/// ## In-use detection: honest scope (epic D2 revised)
///
/// The AGE gate is the primary in-use defense. The cooperative lock probe is a
/// narrow supplement: `open(O_RDONLY|O_CLOEXEC|O_NOFOLLOW)` + `flock(LOCK_EX|
/// LOCK_NB)` detects only ADVISORY `flock` holders on the top-level candidate
/// inode ITSELF. A process holding a DESCENDANT file open for ordinary reading
/// is NOT detected — v1 has no fd enumeration (deferred: O(pids×fds), partial
/// without root). EWOULDBLOCK is the ONLY in-use signal; an open FAILURE is
/// never "in use".
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

    // MARK: - Seams

    /// The cooperative candidate-lock probe's outcome (epic D2 revised).
    enum LockProbe: Equatable {
        /// No advisory `flock` holder on the candidate inode — the lock was
        /// taken and immediately dropped. NOT a claim about descendants.
        case available
        /// EWOULDBLOCK — the ONE in-use signal.
        case inUse
        /// ENOENT/ENOTDIR (gone) or ELOOP (swapped to a symlink after
        /// dispatch): the documented race skip.
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
    typealias DirectoryLister = @Sendable (URL) throws -> [URL]

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
        now: @escaping @Sendable () -> Date = { Date() },
        // Closure literals, not bare static-function references: a static
        // `func` value is not inferred `@Sendable`, and the warning it raises
        // is a real Swift 6 error in waiting.
        lockProbe: @escaping LockProber = {
            EphemeralTempScanner.cooperativeLockProbe($0)
        },
        listDirectory: @escaping DirectoryLister = {
            try EphemeralTempScanner.firstLevelEntries(of: $0)
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
        self.now = now
        self.lockProbe = lockProbe
        self.listDirectory = listDirectory
        self.candidateSizer = candidateSizer
    }

    /// The PRODUCTION first-level listing: `options: []` deliberately — never
    /// `.skipsHiddenFiles`, because dotfile scratch directories are real
    /// payload (the sweep-scanner lesson: a hidden-file skip hid a 23G class).
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

    /// One scan: trigger gate → per root (gate, admit, list) → per entry
    /// (dispatch, ownership, staleness, lock, size, freshness, map).
    ///
    /// `context.categoryFilter` is ignored (it scopes `CategoryScanner` only).
    /// Cancellation is checked between roots and between entries — partial
    /// results are returned rather than discarded.
    func scan(context: ScanContext) async -> ScanOutcome {
        // TRIGGER GATE (epic D11 r5) — the WHOLE scanner, all three roots.
        // A deferral is not an anomaly: no items AND no issues, exactly like
        // a skipped TCC-protected search root.
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
            // disappearance race: temp roots churn by design, and a spurious
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

            let children: [URL]
            do {
                children = try listDirectory(root.url)
            } catch {
                // A root that lstats as a directory but refuses enumeration
                // is a classified, VISIBLE issue — never empty-looking
                // success. This is the one chain-bearing operation class
                // (a), so a provenance-backed TCC signal is preserved.
                record(.cocoaChain(error), at: root.url,
                       "\(root.label) could not be listed")
                continue
            }

            for child in children.sorted(by: {
                $0.lastPathComponent < $1.lastPathComponent
            }) {
                if Task.isCancelled { break }
                // Rebuild under the DECLARED canonical root: the enumeration's
                // own URLs carry Foundation's resolution of the directory
                // argument, and identity/display/deletion must all speak the
                // root spelling this scanner declared.
                let entry = root.url
                    .appendingPathComponent(child.lastPathComponent)

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
                let ownDate: Date
                switch verdict {
                case .notStale, .vanished:
                    continue
                case .denied(let url, let cause):
                    record(cause, at: url,
                           "staleness of \(entry.lastPathComponent) could not "
                            + "be established")
                    continue
                case .stale(let date):
                    ownDate = date
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

                // (7) OUTCOME MAPPING (+ the clean-walk floor).
                if let item = reclaimableItem(
                    entry: entry, identity: identity, root: root,
                    report: report, ownDate: ownDate, now: now
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
        /// evidence when sizing dates nothing.
        case stale(ownDate: Date)
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
    /// (`DirectorySizer.swift:349-355` vs :282-293) — so the stage-2
    /// cross-check is one-directional by construction.
    private func directoryStaleness(
        of entry: URL, cutoff: Date
    ) -> StalenessVerdict {
        switch leafDate(of: entry) {
        case .vanished:
            return .vanished
        case .failed(let cause):
            return .denied(entry, cause)
        case .dated(let ownDate, _):
            // Metadata churn on the entry itself disqualifies it before any
            // walk: the own-mtime input fails, so the contents do not matter.
            guard ownDate < cutoff else { return .notStale }
            return walkForFreshContent(entry, cutoff: cutoff, ownDate: ownDate)
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
        case .dated(let date, let allocatedBytes):
            guard allocatedBytes >= thresholds.sizeFloorBytes,
                  date < cutoff
            else { return .notStale }
            return .stale(ownDate: date)
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
        _ root: URL, cutoff: Date, ownDate: Date
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
                        case .dated(let date, _):
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
        return .stale(ownDate: ownDate)
    }

    /// One no-follow `lstat` read as "when was this last modified, and how
    /// much does the leaf itself allocate".
    private enum LeafDate {
        case dated(Date, allocatedBytes: Int64)
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
                allocatedBytes: metadata.allocatedBytes
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

    /// The PRODUCTION probe: `open(O_RDONLY|O_CLOEXEC|O_NOFOLLOW)` — valid for
    /// files AND directories on Darwin — then a non-blocking exclusive
    /// `flock`. EWOULDBLOCK is the only in-use answer; a successful lock is
    /// dropped immediately (closing the descriptor would drop it anyway, but
    /// the release is explicit so the scan never holds a lock while it sizes).
    ///
    /// An `open` FAILURE is never "in use": ENOENT/ENOTDIR/ELOOP are race
    /// skips (ELOOP means the entry became a symlink after dispatch — the
    /// no-follow flag refusing to open it is the point), and everything else
    /// joins the raw-errno denial accounting. Any OTHER `flock` errno means
    /// "no advisory holder proven" and the candidate proceeds.
    ///
    /// Scope, honestly: this sees advisory `flock` holders on the CANDIDATE
    /// INODE only. It does not and cannot see a process holding a descendant
    /// file open for ordinary reading.
    static func cooperativeLockProbe(_ url: URL) -> LockProbe {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR || code == ELOOP {
                return .vanished
            }
            return .failed(errno: code)
        }
        defer { close(descriptor) }
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
            // Never preselected: the user opts in per entry, against the
            // displayed age evidence.
            defaultSelected: false,
            // LOAD-BEARING INVARIANT (epic D1), not cosmetic: `false` routes
            // these items AROUND the delete-time revalidator dispatch — this
            // scanner declares NO `preDeleteRevalidator`, and the cleaner's
            // orphaned-caches-keyed probe (`CacheCleaner.swift:939-940`) is
            // not a temp-dir probe. Flipping this to `true` without first
            // writing a temp-specific revalidation would silently enter the
            // WRONG probe path.
            automaticCleanEligible: false,
            // Every emitted item passed the two-stage staleness rule AND the
            // post-sizing freshness re-check.
            isStale: true
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
}

// MARK: - SpaceScanner conformance

/// Registration is fn-6.4's (`SpaceScannerRuntime.production`); the witnesses
/// are the members above. No `preDeleteRevalidator` is declared — the default
/// nil is the D1 invariant's other half.
extension EphemeralTempScanner: SpaceScanner {}
