/// # OrphanedCachesScanner — ~/Library/Caches Sweep Enumeration Core (fn-3.1)
///
/// A 31G leaked directory (`com.apple.SwiftUI.Drag-<UUID>` holding a complete
/// Photos-library copy) sat in `~/Library/Caches`, invisible to the fixed
/// category allowlist (FIELD-EVIDENCE-2026-08-06 scenario 4). An allowlist
/// only reclaims what its authors have already seen leak — this scanner
/// enumerates the caches directory and explains what it finds.
///
/// The file holds two layers: the PROTOCOL-INDEPENDENT enumeration half
/// (fn-3.1 — per-entry FACTS, no judgments) and the fn-3.4 assembly — the
/// `SpaceScanner` conformance that pipes facts → classifier (fn-3.2, with
/// fn-3.3's resolver as its predicate) → `ReclaimableItem`s, plus the
/// config surface (`OrphanedCachesSweepConfig`). Registration lives in
/// `SpaceScannerRuntime.production`.
///
/// ## Rules the enumeration enforces
///
/// - **ROOT GATE, no-follow**: the sweep root is `lstat`ed BEFORE any
///   enumeration and must be a REAL directory. A symlink root is NEVER
///   traversed (`contentsOfDirectory` would happily walk wherever a
///   `~/Library/Caches` symlink points); it surfaces as a distinct
///   scanner-level outcome (fn-3.4 maps it to `ScanIssue.Kind.symlinkRoot`).
///   A missing root is honest empty facts; an unreadable root is a CLASSIFIED
///   scanner-level error — never an empty-looking success (D6).
/// - **Hidden/dot entries included** (D3 lesson: `.skipsHiddenFiles` hid a
///   23G class).
/// - **Per-entry sizing uses `.deletionTarget` mode**, not `.scanRoot`:
///   sweep entries are untrusted dynamic names — a symlink entry pointing at
///   `~/Documents` must size 0 and never be walked (`.scanRoot` would fully
///   resolve it and enumerate Documents).
/// - **One sizing walk** (fn-1 R7): size, item count, denials, mount
///   boundaries, AND newest-content mtime all come from the single shared
///   `DirectorySizer` walk. The user-data probe below is a separate BOUNDED
///   CLASSIFICATION probe — it computes no sizes, never touches
///   `DirectorySizer`, and exists only to collect pattern-match hints; it
///   must stay that way.
/// - **Facts pass through, never collapse**: per-entry `SizeDenial`s and
///   mount boundaries ride the facts verbatim — a denied entry with zero
///   measured bytes must stay distinguishable from a genuinely-empty entry
///   (FIELD-EVIDENCE cross-cutting: `du` on a TCC-protected dir returned
///   8.0K for a multi-GB tree).
///
/// ## Category-owned exclusion (R3)
///
/// Entries already owned by an existing `CacheCategory` are filtered out
/// BEFORE the facts list is returned (no double listing or double counting).
/// The exclusion set is built from DECLARED discovery roots plus — for
/// `.probed` entries the category scan will actually attempt — the probe's
/// own resolved path, under ONE gate (PR #456 review, two rounds): a
/// `.probed` entry contributes NOTHING while its `requiresTool` is ABSENT,
/// because a missing tool makes `CacheCategory.resolvedPaths(home:)` skip
/// the whole discovery entry (probe and fallbacks alike), so the category
/// scan provably does not own those roots this session — and the stale
/// cache an uninstalled tool left behind (the exact case this epic exists
/// for) must surface HERE instead of being invisible to both surfaces.
/// While the tool IS present (or no tool is required), the category scan
/// WILL run the probe and scan wherever it resolves — so the sweep runs the
/// SAME bounded probe during exclusion-set construction and excludes an
/// in-scope result even when it is not among the declared fallbacks
/// (`brew --cache` pointed at a custom `~/Library/Caches/CustomBrew` must
/// not be listed by both surfaces and cleaned twice). Probe stdout is
/// nondeterministic input, which is tolerable here ONLY because of the
/// direction it can fail: an exclusion root can HIDE a sweep row, never
/// widen deletion — and a probe that fails/times out simply contributes no
/// root (the entry surfaces; visibility, not a deletion grant). Tool
/// presence is the same bounded `which` check the category scan gates on;
/// both checks and probe runs are memoized per enumeration.

import Foundation
import Darwin

// MARK: - Facts model

/// One first-level sweep entry's FACTS — measurements and observations only,
/// no tier/risk/evidence judgments (those are fn-3.2's).
struct SweptCacheEntry: Equatable {
    /// The entry's basename exactly as enumerated.
    let name: String
    /// The entry's UNRESOLVED spelling under the sweep root (leaf never
    /// resolved — fn-1's dual-canonicalization doctrine; this is what a
    /// deletion input must use so a symlink is removed as a link).
    let url: URL

    /// Bytes on unique inodes — deletion verifiably frees these. Mirrors
    /// `SizeReport`/`ReclaimableItem`: the split components are SEPARATE
    /// stored fields and the sum is computed, never stored — anything else
    /// risks double-counting when fn-3.4 maps to the item model.
    let exactBytes: Int64
    /// Hardlink-claimed bytes that MAY be freed ("up to").
    let estimatedUpToBytes: Int64
    /// Logical (apparent) bytes — sparse files diverge hugely.
    let logicalBytes: Int64
    /// Regular-file directory entries encountered (links, not inodes).
    let itemCount: Int
    /// Newest regular-file `contentModificationDate` in the subtree, from
    /// the same sizing walk (R8 input). Directory churn deliberately
    /// excluded.
    let newestContentDate: Date?

    /// Per-entry denials, passed through verbatim (R7): an entry with
    /// denials and zero measured bytes is NOT a genuinely-empty entry —
    /// fn-3.2/fn-3.4 must never render it as a plain 0-byte row.
    let denials: [SizeDenial]
    /// Mount boundaries inside the entry, passed through verbatim (R7):
    /// a nested boundary means the entry is only PARTIALLY sized — fn-3.2
    /// forces it off safe; the cleaner refuses boundary deletions (fn-1).
    let mountBoundaries: [URL]
    /// The entry ITSELF is a mount point — it must never masquerade as a
    /// clean/empty row (fn-3.4 maps it to non-clean state).
    let rootMountBoundary: Bool

    /// Names of user-data-shape patterns matched inside the entry (R4
    /// input — fn-3.2 turns them into the "verify the original exists"
    /// caution evidence).
    let userDataShapeMatches: [String]
    /// FAIL-CLOSED completeness (epic rule): absence of matches is only
    /// meaningful when the probe COMPLETED. False when the entry budget was
    /// exhausted before the tree was, when any branch was unreadable, or
    /// when a child's kind could not be established — fn-3.2 treats an
    /// incomplete probe like a caution (review risk, no default or
    /// automatic selection). Deliberately NOT false for a tree that is
    /// merely deep: the budget is the one bound, and manufacturing doubt
    /// the walk could have resolved is what stranded ordinary caches
    /// permanently (see `boundedUserDataShapeWalk`).
    let userDataProbeComplete: Bool

    /// The two split components summed — COMPUTED, never stored (byte-model
    /// contract; see the stored fields' doc).
    var allocatedBytes: Int64 { exactBytes + estimatedUpToBytes }
}

/// What one sweep enumeration produced. A missing root is honest empty facts
/// (`.entries([])`); the two failure cases are DISTINCT scanner-level
/// outcomes fn-3.4 maps into `ScanIssue`s (`.rootNotADirectory` →
/// `.symlinkRoot`; `.rootUnreadable` → the denial's
/// `SizeDenial.Kind.scanErrorKind` classification) — never an empty-looking
/// success (D6).
enum SweepEnumeration: Equatable {
    /// First-level facts, category-owned entries already filtered out,
    /// sorted by entry name (byte-wise ascending) for determinism.
    case entries([SweptCacheEntry])
    /// The sweep root exists but is not a real directory (symlink, regular
    /// file, or special file) — NEVER traversed. Carries the observed kind.
    case rootNotADirectory(FileSystemIdentityProvider.FileKind)
    /// The sweep root could not be enumerated (or even probed) — classified,
    /// never collapsed into empty facts.
    case rootUnreadable(SizeDenial)
}

// MARK: - User-data-shape pattern table

/// One user-data-shape pattern (R4). The table is extensible DATA, not
/// conditionals: `name` is the stable identifier recorded in the facts;
/// `glob` is an `fnmatch(3)` pattern applied to basenames at every visited
/// probe depth — CASE-INSENSITIVELY (`FNM_CASEFOLD`, PR #456 review): the
/// guard protects user content in whatever casing it was stored, and a
/// spurious extra match only forces review / refuses deletion (fail-safe).
/// The classifier's known-leak glob deliberately stays case-EXACT: leak
/// patterns name system-generated, case-stable spellings, and a case-folded
/// leak match would WIDEN the auto-clean-eligible safe tier — a case
/// variant falls to the review tiers instead.
struct UserDataShapePattern: Equatable {
    let name: String
    let glob: String
}

// MARK: - Probe obstructions (PR #458 review)

/// ONE reason a bounded user-data probe could not prove the absence of user
/// data — carrying the single fact any remediation guidance turns on:
/// **whether trying again can change it**.
///
/// The probe used to report incompleteness as a bare `Bool`, which forced
/// every surface downstream to FLATTEN causes that genuinely differ. Both
/// flattened messages this scanner has shipped were wrong in mirror-image
/// ways: "re-scan required" prescribed a retry for a bound that reproduces
/// exactly, and its replacement asserted "re-scanning will not clear this"
/// over a set that includes a mid-walk race and transient I/O — which a
/// re-scan clears routinely. Steering a user toward the riskier
/// explicit-confirmation path on a merely transient failure is the harm; so
/// the walk now DISTINGUISHES its causes rather than the message guessing.
///
/// Declaration order is the guidance order (`Comparable` is synthesized from
/// it), so a multi-cause message is deterministic.
enum UserDataProbeObstruction: CaseIterable, Comparable, Sendable {
    /// The entry budget ran out before the tree did. DETERMINISTIC for a
    /// static tree — an orphaned cache is by definition abandoned, so the
    /// next walk spends the same budget on the same entries and stops in the
    /// same place. Nothing but a policy change or an explicit per-item
    /// confirmation clears it.
    case budgetExhausted
    /// A basename that is not valid UTF-8, so the walk cannot address the
    /// entry safely (a repairing decode would name a DIFFERENT path). A
    /// property of the tree: it reproduces until the entry is renamed.
    case undecodableName
    /// A path this walk cannot address — `ENAMETOOLONG` (an absolute path
    /// past `PATH_MAX`, which only relative creation can build, and which
    /// retiring the depth cap made reachable) or `ELOOP`. A property of the
    /// PATH, so it reproduces exactly until the tree is restructured.
    case unaddressablePath
    /// A mount boundary the walk refuses to cross (either signal: a device-id
    /// change against the walk root, or the `statfs` mount-root check).
    /// CLEARABLE in the way a bound never is — unmount and the next walk
    /// reads the tree whole.
    case mountBoundary
    /// `EACCES`/`EPERM` on a directory or a child — TCC or POSIX
    /// permissions. A bare retry reproduces it; GRANTING access clears it.
    case accessDenied
    /// An I/O error, a resource shortage, an unreachable network volume, or
    /// the tree changing under the walk (a directory removed between being
    /// pushed and being popped). The genuinely RETRYABLE class: once the
    /// race or the obstruction is gone, a re-scan completes.
    case transientFailure
    /// An errno the router does not recognize. Claims NEITHER retryability
    /// nor permanence — see `OrphanedCachesScanner.obstruction(forErrno:)`
    /// for why an unknown cause gets its own class rather than falling into
    /// either default.
    case unclassifiedFailure

    /// What can actually change this — the whole point of distinguishing.
    ///
    /// Ordered LEAST → MOST demanding, with `Comparable` synthesized off
    /// that order so a mixed set can take the most demanding remedy
    /// present. Causes are CONJUNCTIVE — the user must clear every one of
    /// them — so "best available" is the wrong operator: it closes a
    /// budget-plus-transient set with "re-scan and try again" and sends the
    /// user around a loop that can never succeed.
    enum Remedy: Comparable, Sendable {
        /// A re-scan alone can succeed.
        case retryAlone
        /// A user action first (unmount, grant access, rename), then a
        /// re-scan.
        case userActionThenRetry
        /// Unknown: neither promise can be made honestly.
        case unknown
        /// Nothing available: it reproduces exactly until policy or an
        /// explicit per-item confirmation changes the outcome. (Spelled out
        /// rather than `none`, which reads as `Optional.none` at a glance.)
        case irreducible
    }

    var remedy: Remedy {
        switch self {
        case .budgetExhausted: return .irreducible
        case .undecodableName, .unaddressablePath, .mountBoundary,
             .accessDenied:
            return .userActionThenRetry
        case .transientFailure: return .retryAlone
        case .unclassifiedFailure: return .unknown
        }
    }

    /// The cause clause — what happened, and what would clear it. One
    /// sentence, composed by `OrphanedCachesScanner.remediationGuidance`.
    var guidance: String {
        switch self {
        case .budgetExhausted:
            return "This folder holds more entries than the inspection "
                + "budget allows, so part of it was never looked at."
        case .undecodableName:
            return "An entry here has a name that is not valid text, which "
                + "the inspection will not address; renaming it allows a "
                + "full inspection."
        case .unaddressablePath:
            return "Part of this folder sits at a path the inspection "
                + "cannot address — it is too long, or it resolves through "
                + "too many links; shortening or renaming it allows a full "
                + "inspection."
        case .mountBoundary:
            return "A volume is mounted inside this folder and the "
                + "inspection never crosses a mount boundary; unmounting it "
                + "allows a full inspection."
        case .accessDenied:
            return "Part of this folder could not be read; granting access "
                + "to it (Full Disk Access, or its permissions) allows a "
                + "full inspection."
        case .transientFailure:
            return "The inspection hit a temporary error, or the folder "
                + "changed while it was being read."
        case .unclassifiedFailure:
            return "The inspection failed for a reason it could not "
                + "classify."
        }
    }
}

/// One bounded user-data probe's verdict: what it matched, and — when it
/// could not finish — exactly WHY, so guidance never has to guess.
///
/// `complete` is DERIVED, never stored: absence of matches is meaningful iff
/// nothing obstructed the walk, which is the fail-closed rule the classifier
/// (R4) and the delete-time revalidation both read.
struct UserDataProbeResult: Equatable {
    /// Matched pattern NAMES in table order, deduplicated.
    let matches: [String]
    /// Deduplicated and sorted in declaration order — deterministic output
    /// for a deterministic message. Empty iff the walk finished.
    let obstructions: [UserDataProbeObstruction]

    /// FAIL-CLOSED completeness (epic rule).
    var complete: Bool { obstructions.isEmpty }

    /// The clean, finished verdict.
    static func complete(matches: [String] = []) -> UserDataProbeResult {
        UserDataProbeResult(matches: matches, obstructions: [])
    }
}

// MARK: - OrphanedCachesScanner (enumeration core)

/// `@unchecked Sendable` under the same discipline as the other scanners
/// (`SpaceScanner: Sendable`): every stored property is an immutable `let`;
/// `FileSystemIdentityProvider` and `DirectorySizer` hold no mutable state;
/// `FileManager.default` is documented thread-safe; all stored closures
/// are `@Sendable` by type.
struct OrphanedCachesScanner: @unchecked Sendable {

    /// Stable scanner slug (fn-3.4) — the CLI address prefix
    /// (`orphaned_caches:<item-id>`) and the GUI section key. PERMANENT
    /// external contract; matches the address grammar `[a-z0-9_]+`.
    static let registeredID = "orphaned_caches"

    /// The production sweep root, relative to home. First-level entries of
    /// this directory only — no `/Library/Caches` (system domain), no
    /// `~/Library/Containers` (sandboxed apps; out of scope).
    static let sweepRootRelativePath = "Library/Caches"

    /// Seeded per the epic spec (field case: a complete Photos-library copy
    /// at `<entry>/Pictures/Photos Library.photoslibrary`).
    static let userDataShapePatterns: [UserDataShapePattern] = [
        UserDataShapePattern(name: "photos-library", glob: "*.photoslibrary"),
        UserDataShapePattern(name: "documents-directory", glob: "Documents"),
        UserDataShapePattern(name: "pictures-directory", glob: "Pictures"),
    ]

    /// The PRODUCTION probe cap — ONE definition shared by the init default
    /// and the delete-time revalidation entry point
    /// (`preDeleteUserDataProbe`), so scan-time and delete-time inspection
    /// bounds can never drift apart.
    ///
    /// This is the walk's ONLY bound and the sole guarantee that it
    /// terminates (see `boundedUserDataShapeWalk`'s doc for the argument and
    /// for why a second, depth-shaped bound was removed).
    ///
    /// **Why 20,000, measured.** Driven through this very probe over the
    /// field machine's real `~/Library/Caches` (179 first-level
    /// directories), the retired depth-3/512-entry pair reported 53
    /// (29.6%) INCOMPLETE — 44 of them with nothing whatsoever obstructing
    /// the walk. The entry budget ALONE reports 21 at 512, 11 at 20,000,
    /// 10 at 50,000; the irreducible 9 are genuinely unreadable (TCC), so
    /// 20,000 leaves exactly 2 bound-truncated (1.1%). 512 was far too
    /// small for real caches, and it is just as deterministic as the depth
    /// cap was, so it stranded too.
    ///
    /// Cost is not the binding constraint: `DirectorySizer.measure`
    /// already performs an UNBOUNDED full enumeration of the very same
    /// entry at scan time, so this probe can never cost more than work
    /// being done unconditionally anyway (measured over those 179 trees:
    /// 158,597 entries for the sizing walk against 72,549 for a
    /// 20,000-budget probe) — and at DELETE time it runs for ONE item, not
    /// the whole sweep. 20,000 is also `ValuablesDetector`'s budget in the
    /// sibling scanner: one number, one doctrine. The two trees that still
    /// exceed it here (26,248 and 99,800 entries) stay honestly unproven —
    /// genuine "we could not afford to look", not manufactured doubt.
    static let defaultProbeEntryLimit = 20_000

    /// The sweep root this instance enumerates (injectable for tests; no
    /// test touches the real `$HOME` or the real `~/Library/Caches`).
    let cachesRoot: URL
    /// Anchor for exclusion-set resolution. MUST be spelled consistently
    /// with `cachesRoot` (both derive from the same home in production) —
    /// the exclusion math compares path components, so resolving roots
    /// against one spelling and sweeping another silently defeats it (the
    /// same doctrine as `CacheCategory.resolvedPaths(home:)`).
    let home: URL

    private let categories: [CacheCategory]
    private let provider: FileSystemIdentityProvider
    private let sizer: DirectorySizer
    private let fileManager = FileManager.default
    /// The user-data probe's cap — the probe is BOUNDED (only the sizing
    /// walk is complete). Injectable so tests can prove the fail-closed cap
    /// behavior without thousand-file fixtures; the DEFAULT is the shared
    /// production constant the delete-time entry point uses, so scan-time
    /// and delete-time bounds cannot drift.
    private let probeEntryLimit: Int

    /// Classification thresholds (R8) — scanner-CONSTRUCTION state by
    /// frozen contract (they never ride `ScanContext`). The composition
    /// site layers defaults → UserDefaults → CLI flags
    /// (`OrphanedCachesSweepConfig`).
    let thresholds: OrphanedCacheClassifier.Thresholds
    /// fn-3.3's tri-state resolver, injected as a plain predicate (fn-3.2's
    /// classifier contract). The default never orphan-classifies —
    /// production wires `InstalledAppResolver.status(ofBundleID:)`.
    private let installedAppStatus: @Sendable (String) -> InstalledAppStatus
    /// Injected clock for stale-age math — a PROVIDER (not a `Date`)
    /// because the scanner is long-lived and each scan must classify
    /// against its own "now".
    private let now: @Sendable () -> Date
    /// Tool-presence gate for probed-entry exclusion (R3, PR #456 review) —
    /// injectable so tests stay hermetic; the production default mirrors
    /// `CacheCategory.toolExists` (same `which`, same PATH/HOME
    /// environment, same bounded wait), because the two MUST agree on
    /// whether the category scan attempts a probed discovery entry.
    /// Consulted once per distinct tool per enumeration — for EVERY probed
    /// entry, not only those with in-scope fallbacks, because the probe of
    /// any tool-present entry can resolve into the sweep root.
    private let toolIsAvailable: @Sendable (String) -> Bool
    /// Probe runner for probed-entry exclusion (R3, PR #456 review round 3):
    /// command in, trimmed stdout path (or nil on failure/timeout/empty)
    /// out. Injectable so tests never spawn real tools; the production
    /// default IS `CacheCategory.runProbe` — the same subprocess doctrine
    /// the category scan resolves with, so the two surfaces agree on where
    /// a tool-present probed category lives. Failure direction: nil
    /// contributes no exclusion root, so the entry SURFACES in the sweep —
    /// visibility, never a deletion grant.
    private let probeResolvedPath: @Sendable (String) -> String?

    init(
        home: URL,
        cachesRoot: URL? = nil,
        categories: [CacheCategory] = CacheCategory.allCategories,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider(),
        probeEntryLimit: Int = OrphanedCachesScanner.defaultProbeEntryLimit,
        thresholds: OrphanedCacheClassifier.Thresholds =
            OrphanedCachesSweepConfig.defaultThresholds,
        installedAppStatus: @escaping @Sendable (String) -> InstalledAppStatus =
            { _ in .unknown },
        now: @escaping @Sendable () -> Date = { Date() },
        toolAvailability: (@Sendable (String) -> Bool)? = nil,
        probeResolver: (@Sendable (String) -> String?)? = nil
    ) {
        self.home = home
        self.cachesRoot = cachesRoot
            ?? home.appendingPathComponent(Self.sweepRootRelativePath)
        self.categories = categories
        self.provider = provider
        self.sizer = DirectorySizer(provider: provider)
        self.probeEntryLimit = probeEntryLimit
        self.thresholds = thresholds
        self.installedAppStatus = installedAppStatus
        self.now = now
        self.toolIsAvailable = toolAvailability
            ?? { Self.productionToolAvailability($0, home: home) }
        self.probeResolvedPath = probeResolver
            ?? { CacheCategory.runProbe($0, home: home) }
    }

    // MARK: - Enumeration

    /// Enumerate first-level entries of the sweep root and return per-entry
    /// facts. See the file header for the rules this enforces.
    func enumerateFacts() -> SweepEnumeration {
        // ROOT GATE (no-follow) — per-entry gates do not protect the root.
        switch provider.probeKind(of: cachesRoot) {
        case .absent:
            // Missing root: nothing to sweep — honest empty facts.
            return .entries([])
        case .failed(let code):
            return .rootUnreadable(
                DirectorySizer.denial(forFailedProbe: cachesRoot, errno: code)
            )
        case .kind(.directory):
            break
        case .kind(let kind):
            // Symlink / regular file / special file: NEVER traversed.
            return .rootNotADirectory(kind)
        }

        let children: [URL]
        do {
            // options: [] deliberately — hidden/dot entries INCLUDED (D3).
            children = try fileManager.contentsOfDirectory(
                at: cachesRoot, includingPropertiesForKeys: nil, options: []
            )
        } catch {
            // A root that lstats as a directory but refuses enumeration
            // (chmod 000, TCC) is a classified scanner-level error, never
            // empty facts (D6).
            return .rootUnreadable(
                DirectorySizer.classifyDenial(error, at: cachesRoot)
            )
        }

        let exclusionRoots = categoryExclusionRoots()
        var facts: [SweptCacheEntry] = []

        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            // Category-owned entries are filtered out BEFORE sizing — they
            // are the categories' rows, not the sweep's (R3: "excluded from
            // sweep output"; no double listing or double counting).
            if isCategoryOwned(child, keptRoots: exclusionRoots) { continue }

            let probe: UserDataProbeResult
            switch provider.probeKind(of: child) {
            case .absent:
                // Deleted between enumeration and probe — a benign mid-scan
                // race, not a denial.
                continue
            case .kind(.directory):
                probe = probeUserDataShapes(at: child)
            case .kind:
                // Symlink / regular file / special: no contents of their
                // own to probe — complete by construction. A symlink is
                // NEVER followed: deleting the entry removes the link, not
                // its target, so nothing deletable went uninspected.
                probe = .complete()
            case .failed(let code):
                // Cannot even establish the kind — fail closed; the sizing
                // pass below records the classified denial for the facts.
                probe = UserDataProbeResult(
                    matches: [], obstructions: [Self.obstruction(forErrno: code)]
                )
            }

            // `.deletionTarget`, not `.scanRoot`: lstat-dispatches the leaf
            // first (symlink → 0 bytes, never walked; regular file → own
            // size; directory → enumerated). Sweep entries are untrusted
            // dynamic names — the deletion-target semantics are the correct
            // ones at scan time too.
            let report = sizer.measure(at: child, mode: .deletionTarget)

            facts.append(SweptCacheEntry(
                name: child.lastPathComponent,
                url: child,
                exactBytes: report.exactAllocatedBytes,
                estimatedUpToBytes: report.estimatedUpToBytes,
                logicalBytes: report.logicalBytes,
                itemCount: report.itemCount,
                newestContentDate: report.newestContentDate,
                denials: report.denials,
                mountBoundaries: report.mountBoundaries,
                rootMountBoundary: report.rootMountBoundary,
                userDataShapeMatches: probe.matches,
                userDataProbeComplete: probe.complete
            ))
        }

        return .entries(facts)
    }

    // MARK: - Category-owned exclusion (R3)

    /// Category roots kept for exclusion, as standardized path components.
    /// Path construction mirrors BOTH `CategoryAdmissionPolicy(category:home:)`
    /// and `CacheCategory.resolvedPaths(home:)` — all three `PathDiscovery`
    /// kinds, `.staticPath` and non-`/`-prefixed probed fallbacks anchored
    /// to the injected home, probe results resolved exactly as
    /// `resolvedPaths` resolves them (`URL(fileURLWithPath:)`).
    ///
    /// Scope filter (every candidate root, declared or probed): keep ONLY
    /// roots STRICTLY below the sweep root. A root outside the sweep root,
    /// or EQUAL to it, contributes NOTHING — otherwise a category declaring
    /// e.g. `~/Library` (an ancestor of every entry), or a probe emitting
    /// the sweep root itself, would silently suppress the entire sweep.
    ///
    /// Tool gate on probed entries (PR #456 review): a `.probed` entry
    /// whose `requiresTool` is ABSENT is skipped ENTIRELY by the category
    /// scan (`CacheCategory.resolvedPaths`), probe and fallbacks alike, so
    /// excluding any of its roots here would hide the stale cache an
    /// uninstalled tool left behind from BOTH surfaces. The gate runs FIRST
    /// (it governs the whole entry), once per distinct tool per
    /// enumeration, for EVERY probed entry — not only those with in-scope
    /// fallbacks, because a tool-present probe can resolve INTO the sweep
    /// root from anywhere (production: 9 distinct tools, `which` answers in
    /// milliseconds).
    ///
    /// Probe step (PR #456 review round 3): while the tool IS present (or
    /// no tool is required) the category scan WILL run the probe and scan
    /// wherever it resolves — a result inside the sweep root that is NOT
    /// among the declared fallbacks (`brew --cache` → custom
    /// `~/Library/Caches/CustomBrew`) would otherwise be listed and sized
    /// by both surfaces and cleaned twice. So the sweep runs the SAME
    /// bounded probe (`CacheCategory.runProbe` doctrine via the injectable
    /// seam, memoized per command per enumeration) and keeps an in-scope
    /// result. Nondeterministic stdout is tolerable ONLY because exclusion
    /// is fail-safe by direction: a root can HIDE a sweep row, never widen
    /// deletion; a probe failure/timeout contributes no root and the entry
    /// surfaces (visibility, not a deletion grant). The kept set
    /// deliberately stays a SUPERSET of what the category scan captured
    /// (probe result AND all declared fallbacks, even when the probe
    /// resolved elsewhere, its result does not exist on disk, or a later
    /// fallback lost the first-match cut) — conservative against double
    /// listing, and a declared-but-uncaptured root remains attributable to
    /// its category by declaration.
    private func categoryExclusionRoots() -> [[String]] {
        let rootComponents = cachesRoot.standardizedFileURL.pathComponents
        var toolPresence: [String: Bool] = [:]
        var probeOutputs: [String: String?] = [:]
        var kept: [[String]] = []

        func keepIfInScope(_ url: URL) {
            let components = url.standardizedFileURL.pathComponents
            guard components.count > rootComponents.count,
                  components.starts(with: rootComponents)
            else { return }
            kept.append(components)
        }
        func toolPresent(_ tool: String) -> Bool {
            if let cached = toolPresence[tool] { return cached }
            let present = toolIsAvailable(tool)
            toolPresence[tool] = present
            return present
        }

        for category in categories {
            for entry in category.discovery {
                switch entry {
                case .staticPath(let relative):
                    keepIfInScope(home.appendingPathComponent(relative))
                case .absolutePath(let absolute):
                    keepIfInScope(URL(fileURLWithPath: absolute))
                case .probed(let command, let requiresTool, let fallbacks):
                    if let tool = requiresTool, !toolPresent(tool) {
                        // The category scan provably skips this whole
                        // entry — none of its roots are excluded, and
                        // the probe never runs.
                        continue
                    }
                    for fallback in fallbacks {
                        keepIfInScope(fallback.hasPrefix("/")
                            ? URL(fileURLWithPath: fallback)
                            : home.appendingPathComponent(fallback))
                    }
                    let output: String?
                    if let memoized = probeOutputs[command] {
                        output = memoized
                    } else {
                        output = probeResolvedPath(command)
                        probeOutputs[command] = output
                    }
                    if let probedPath = output, !probedPath.isEmpty {
                        keepIfInScope(URL(fileURLWithPath: probedPath))
                    }
                }
            }
        }
        return kept
    }

    /// The production tool-presence check — mirrors
    /// `CacheCategory.toolExists` exactly (same `/usr/bin/which`, same
    /// restricted PATH, same injected HOME, same bounded 2s wait), because
    /// exclusion must agree with the category scan's own gate on whether a
    /// probed discovery entry is attempted. `false` on any failure — the
    /// fallback then SURFACES in the sweep, where classification and
    /// container admission still govern it (visibility, never a deletion
    /// grant).
    private static func productionToolAvailability(
        _ tool: String, home: URL
    ) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [tool]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin",
            "HOME": home.path
        ]
        do {
            try process.run()
        } catch {
            return false
        }
        guard process.waitForExit(within: 2) else {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }

    /// Step 2 — containment, BIDIRECTIONAL, by `pathComponents` prefix,
    /// never string `hasPrefix` (`/a/bc` is not inside `/a/b`). An entry is
    /// category-owned when:
    ///
    /// (a) the entry is at-or-below a kept root (root ancestor-or-equal of
    ///     the entry — today's case, effectively equality since all current
    ///     roots sit exactly one component below Library/Caches), OR
    /// (b) a kept root is strictly below the entry (entry ancestor of the
    ///     root — the future deeper-root case, e.g. a category declaring
    ///     `Library/Caches/Google/Chrome` excludes first-level entry
    ///     `Google`).
    ///
    /// Direction (b) deliberately hides the partially-owned entry's
    /// non-category siblings rather than double-counting the category
    /// subtree — the alternative (listing the entry minus the category's
    /// slice) needs subtraction logic in sizing AND deletion that nothing
    /// today requires, since every current root sits exactly one component
    /// below Library/Caches. Revisit with subtraction only if a real
    /// deeper root ever lands.
    private func isCategoryOwned(_ entry: URL, keptRoots: [[String]]) -> Bool {
        let entryComponents = entry.standardizedFileURL.pathComponents
        for root in keptRoots {
            if entryComponents.count >= root.count,
               entryComponents.starts(with: root) {
                return true // (a) entry at-or-below the kept root
            }
            if root.count > entryComponents.count,
               root.starts(with: entryComponents) {
                return true // (b) kept root strictly below the entry
            }
        }
        return false
    }

    // MARK: - User-data-shape probe (R4 input)

    /// Bounded walk of one REAL-DIRECTORY entry — the instance (scan-time)
    /// face of the shared static core below, using the injectable
    /// per-instance cap.
    private func probeUserDataShapes(at entryURL: URL) -> UserDataProbeResult {
        Self.boundedUserDataShapeWalk(
            at: entryURL, provider: provider, entryLimit: probeEntryLimit
        )
    }

    /// DELETE-TIME REVALIDATION entry point (cleaner seam, PR #456 review):
    /// a sweep entry removed and RECREATED at the same name between scan
    /// and confirmation passes the cleaner's container-snapshot check (the
    /// snapshot binds the `~/Library/Caches` root's identity, not the
    /// entry's), so the scan-time user-data probe describes content that no
    /// longer exists. The cleaner re-runs THIS probe immediately before
    /// deleting an auto-clean-eligible sweep item and refuses unless it
    /// re-establishes the clean promise (no matches AND complete) — the
    /// same fail-closed doctrine as scan time.
    ///
    /// Kind gating mirrors the scan path exactly:
    /// - real directory → the bounded no-follow walk (the PRODUCTION cap);
    /// - symlink / regular file / special → no contents of their own —
    ///   clean and complete by construction (deletion removes the leaf
    ///   as-is, never a target's tree);
    /// - absent → clean and complete: the deletion path surfaces its own
    ///   ENOENT (frozen ghost asymmetry) — the probe must not preempt it;
    /// - unprobeable → fail closed (incomplete), attributed by errno so the
    ///   guidance can say whether a retry helps.
    static func preDeleteUserDataProbe(
        at target: URL, provider: FileSystemIdentityProvider
    ) -> UserDataProbeResult {
        switch provider.probeKind(of: target) {
        case .kind(.directory):
            return boundedUserDataShapeWalk(
                at: target, provider: provider,
                entryLimit: defaultProbeEntryLimit
            )
        case .kind:
            return .complete()
        case .absent:
            return .complete()
        case .failed(let code):
            return UserDataProbeResult(
                matches: [], obstructions: [obstruction(forErrno: code)]
            )
        }
    }

    /// errno → obstruction, in ONE place, so scan time and delete time
    /// classify identically.
    ///
    /// Every class is decided on the SAME question the guidance turns on —
    /// can a retry, unaided, change this? — rather than on how the failure
    /// felt. The previous shape answered it for `EACCES`/`EPERM` and then
    /// swept everything else into "transient", which is the fail-open
    /// pattern this codebase keeps getting bitten by: one genuinely benign
    /// cause (the mid-walk race) justifying a catch-all that then absorbs
    /// every class nobody enumerated. `ENAMETOOLONG` was the live example —
    /// reachable at all only because the depth cap is gone (e9de405) — and
    /// an unchanged tree reproduces it exactly, so "re-scan and try again"
    /// was a loop that could never terminate.
    static func obstruction(forErrno code: Int32) -> UserDataProbeObstruction {
        switch code {
        // GRANTABLE — a retry reproduces it, a grant clears it. `EPERM` is
        // what TCC returns; `EACCES` is POSIX permissions.
        case EACCES, EPERM:
            return .accessDenied

        // STRUCTURAL — a property of the PATH, reproduced by every re-scan
        // of an unchanged tree. `ENAMETOOLONG`: an absolute path past
        // `PATH_MAX`, which only relative creation (`mkdirat`) can build.
        // `ELOOP`: symlink resolution depth, reachable here only through an
        // ancestor, since this walk itself never follows a link. Clearable
        // by restructuring, never by a retry.
        case ENAMETOOLONG, ELOOP:
            return .unaddressablePath

        // GENUINELY RETRYABLE — the mid-walk race (the tree changed under
        // the walk: `ENOENT`/`ENOTDIR`, still fail-closed because a rename
        // can move content past a parent already read), I/O and media
        // errors, resource shortages, and the network/removable-volume
        // family. A later scan can find every one of these gone.
        case ENOENT, ENOTDIR, EIO, EINTR, EAGAIN, EMFILE, ENFILE, ENOMEM,
             ENODEV, ENXIO, EBUSY, ESTALE, ETIMEDOUT, ENOTCONN, ECONNRESET,
             ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH:
            return .transientFailure

        // EVERYTHING ELSE CLAIMS NEITHER. Defaulting the unknown to
        // "transient" is what this comment opened with. Defaulting it to
        // "permanent" would be just as unearned, and that direction costs
        // more: it steers the user to explicit per-item confirmation — the
        // RISKIER path — on a guess. So an unrecognized errno (`EINVAL`,
        // `EOVERFLOW`, anything a future OS adds) says exactly what is
        // true: we do not know whether this repeats. The refusal itself is
        // identical either way — only the advice differs, and unearned
        // advice is what the whole review thread is about.
        default:
            return .unclassifiedFailure
        }
    }

    /// The ONE bounded user-data-shape walk, shared by the scan-time probe
    /// and the delete-time revalidation so the two can never drift. Matches
    /// basenames against `userDataShapePatterns`, returning the matched
    /// pattern NAMES (in table order, deduplicated) and — when the walk
    /// could not finish — the ATTRIBUTED obstructions behind the
    /// fail-closed verdict.
    ///
    /// Internal rather than private ONLY so tests can drive it at a small
    /// budget; both PRODUCTION callers (`probeUserDataShapes` and
    /// `preDeleteUserDataProbe`) read `defaultProbeEntryLimit`, so the
    /// scan-time and delete-time bounds still cannot drift.
    ///
    /// ## The budget bounds what is MATERIALIZED, not just what is INSPECTED
    /// (PR #458 review)
    /// Every directory is read through `boundedChildNames`, which stops
    /// after the REMAINING budget's worth of `readdir` entries. The previous
    /// `contentsOfDirectory(at:).sorted` read and sorted every child of a
    /// directory BEFORE the per-entry guard could fire, so one cache
    /// directory with millions of entries could spike memory and stall the
    /// scan even though only `entryLimit` entries were ever inspected — the
    /// budget was a bound on ATTENTION, not on WORK. The retired depth cap
    /// had been hiding that for anything below its boundary. A directory is
    /// also no longer opened at all once the budget is spent (`remaining >
    /// 0` is checked before the read, not after it).
    ///
    /// Under truncation, WHICH entries were read is deliberately
    /// UNSPECIFIED: a directory bigger than the remaining budget is read in
    /// filesystem `readdir` order, because selecting the byte-wise smallest
    /// N would require the whole enumeration the budget exists to prevent.
    /// Nothing may depend on that membership — a truncated probe is
    /// fail-closed on every surface. Within a directory the budget could
    /// read WHOLE, order is byte-wise ascending (children first, then
    /// subdirectories descended in that same order), so a complete walk is
    /// fully deterministic.
    ///
    /// NO-CROSS rule (safety — PR #458 review, matching the sizer's own
    /// root check at `DirectorySizer.swift:205` and its within-walk check at
    /// `DirectorySizer.swift:289`): mount boundaries are never crossed, at
    /// the root or anywhere beneath it, and an uncrossed boundary makes the
    /// probe INCOMPLETE. The same two
    /// signals as everywhere else in this codebase — a device-id change
    /// against the WALK ROOT, plus the `statfs` mount-root check that
    /// catches same-`st_dev` firmlink mounts — and no third notion of
    /// "mount boundary" is invented here. Enforced INSIDE this shared core,
    /// not at a call site: at scan time the probe runs BEFORE the sizing
    /// pass that would mark the item review-only, and at delete time
    /// `preDeleteUserDataProbe` is handed a bare URL with no size report to
    /// consult, with a volume mountable between the scan and the clean.
    /// What crossing costs is real and buys nothing: up to `entryLimit`
    /// reads on network/removable/FUSE storage the user never pointed this
    /// scanner at, on an item a boundary already makes uncleanable
    /// (`CacheCleaner.swift:911`). UNCROSSED ⇒ INCOMPLETE, never "clean" —
    /// and unlike a depth cap it is CLEARABLE: unmount, and the next walk
    /// reads the tree whole.
    ///
    /// NO-FOLLOW rule (safety — mirrors `.deletionTarget` sizing): the
    /// caller lstat-gates the probe root, and every descent below is
    /// lstat-gated here; a nested symlink is matched by NAME only and never
    /// traversed. Without this, `contentsOfDirectory` on a symlink would
    /// inspect data outside ~/Library/Caches and undo the safety the sizing
    /// mode bought. An unexpanded symlink does NOT mark the probe
    /// incomplete: deleting the entry removes the link, never its target,
    /// so no deletable content went uninspected.
    ///
    /// ## ONE budget, and NO depth cap (PR #456 follow-up)
    /// The ENTRY budget is this walk's only bound, and it alone guarantees
    /// termination: a directory is pushed ONLY from inside the child loop,
    /// immediately after `visited += 1` — every descent cost one entry to
    /// DISCOVER — so at most `entryLimit` directories are ever pushed and
    /// at most `entryLimit + 1` are ever popped. That holds however deep
    /// the tree runs, and even of a hypothetical directory cycle (a symlink
    /// is `lstat`-classified and never descended, so no cycle can form
    /// through one anyway).
    ///
    /// A fixed depth cap therefore bounded NOTHING the budget did not.
    /// What it did do was manufacture INCOMPLETE verdicts on ordinary cache
    /// trees, and those verdicts were inescapable: a depth boundary is
    /// DETERMINISTIC, so every re-scan and every delete-time re-probe
    /// reproduced it. Downstream that is permanent — the classifier forces
    /// such an entry off `.safe` and sets `automaticCleanEligible = false`,
    /// which removes it from Quick Clean, `selectAllSafe` and CLI
    /// smart-clean FOREVER, over evidence claiming the contents could not
    /// be inspected when nothing had obstructed the walk. Worse for safety
    /// than for reclaim: user data BELOW the boundary was never looked at,
    /// so a buried `Photos Library.photoslibrary` produced "no matches"
    /// rather than a match. Real caches cross three levels constantly (the
    /// field machine's own `~/Library/Caches` nests fourteen deep, and 42
    /// of its 179 entries pass depth 3) — including, on that machine, a
    /// live `com.apple.SwiftUI.Drag-<UUID>` leak of just 52 entries whose
    /// only sin was reaching depth 4: the exact class this scanner exists
    /// to reclaim, held off the automatic path forever by a bound that
    /// bought nothing. Depth is now spent FROM the one budget: a tree the
    /// budget can afford is PROVEN, and only a tree it genuinely cannot
    /// afford stays unproven.
    static func boundedUserDataShapeWalk(
        at entryURL: URL,
        provider: FileSystemIdentityProvider,
        entryLimit: Int
    ) -> UserDataProbeResult {
        var matched = Set<String>()
        var obstructions = Set<UserDataProbeObstruction>()
        var visited = 0

        // MOUNT BOUNDARY AT THE ROOT, before anything is opened — the same
        // pair of signals `DirectorySizer.swift:205` applies to its own
        // root. An entry that IS a mount is not enumerated at all: not one
        // entry of the foreign filesystem is read, and the verdict is
        // INCOMPLETE precisely because we did not look.
        let rootDevice = provider.deviceID(of: entryURL)
        let parentDevice = provider.deviceID(
            of: entryURL.deletingLastPathComponent()
        )
        if (rootDevice != nil && parentDevice != nil
                && rootDevice != parentDevice)
            || provider.isMountPoint(entryURL) {
            return UserDataProbeResult(
                matches: [], obstructions: [.mountBoundary]
            )
        }

        // ACCUMULATE, NEVER PREEMPT (PR #458 review r3). Every stop below
        // records what it proved into `obstructions` and then `break`s or
        // `continue`s; the ONLY `return` past this point is the single exit
        // at the end, which carries the whole set. A guard that returns
        // ahead of the bookkeeping silently keeps whichever cause the
        // control flow reached first — exactly how the sentinel read came
        // to drop a budget exhaustion it had already proven. The root check
        // above may return early only because nothing is established yet at
        // that point.
        //
        // Depth-first, byte-wise ascending within each directory the budget
        // could read whole.
        var stack: [URL] = [entryURL]

        walk: while let dir = stack.popLast() {
            let remaining = entryLimit - visited
            guard remaining > 0 else {
                // Budget spent with directories still unexplored — and the
                // directory is NOT opened to discover that.
                obstructions.insert(.budgetExhausted)
                break walk
            }
            let names: [String]
            switch boundedChildNames(of: dir, limit: remaining) {
            case .unreadable(let cause):
                // Unreadable branch: absence of matches is unproven.
                obstructions.insert(cause)
                continue
            case .read(let read, let causes):
                // EVERY cause the read established, never just the first —
                // one read can prove several at once (PR #458 review r3).
                obstructions.formUnion(causes)
                // Sorting a slice bounded by the REMAINING budget — never a
                // whole million-entry cache directory.
                names = read.sorted {
                    $0.utf8.lexicographicallyPrecedes($1.utf8)
                }
            }
            // Descend in ascending order: collected here, pushed reversed.
            var pendingDirectories: [URL] = []

            for name in names {
                guard visited < entryLimit else {
                    // Defense in depth: the read above is already bounded by
                    // the REMAINING budget, so this cannot fire today. It
                    // stays because `visited` is the invariant that matters
                    // — anything that ever spends from the same pot
                    // mid-directory keeps the bound true through here.
                    obstructions.insert(.budgetExhausted)
                    break walk
                }
                visited += 1

                // The walk's OWN spelling, never a resolved one: the child
                // is `lstat`-probed at exactly the path the deletion would
                // remove (`contentsOfDirectory(at:)` handed back RESOLVED
                // URLs, which is the wrong path for a no-follow probe).
                let child = dir.appendingPathComponent(name)
                // FNM_CASEFOLD (PR #456 review): the guard protects user
                // content in ANY casing (`Photos Library.PHOTOSLIBRARY`,
                // `pictures`, `DOCUMENTS`) — the stored spelling is
                // arbitrary, and flags 0 compared it case-sensitively even
                // on the case-insensitive default filesystem. Fail-safe by
                // direction: casefolding here can only ADD matches, which
                // only forces review / refuses deletion. Deliberately NOT
                // mirrored by the classifier's known-leak glob (see the
                // pattern-table doc above).
                for pattern in userDataShapePatterns
                where fnmatch(pattern.glob, name, FNM_CASEFOLD) == 0 {
                    matched.insert(pattern.name)
                }

                switch provider.probeKind(of: child) {
                case .kind(.directory):
                    // MOUNT BOUNDARY: never crossed, whatever is on the far
                    // side (see the NO-CROSS rule above).
                    guard !crossesMountBoundary(
                        child, rootDevice: rootDevice, provider: provider
                    ) else {
                        // We did not look past it: unproven, exactly like
                        // an unreadable branch.
                        obstructions.insert(.mountBoundary)
                        break
                    }
                    // ALWAYS descended otherwise: discovering this directory
                    // already cost an entry, and the budget bounds
                    // everything that follows. Refusing to look past some
                    // fixed level is what stranded ordinary caches (see the
                    // doc above).
                    pendingDirectories.append(child)
                case .kind:
                    // Symlink / regular file / special: matched by name
                    // above, never descended (see the no-follow rule).
                    break
                case .absent:
                    // Vanished mid-probe — benign race: it holds nothing
                    // deletable any more.
                    break
                case .failed(let code):
                    // Could not establish the kind — fail closed, attributed.
                    obstructions.insert(obstruction(forErrno: code))
                }
            }
            stack.append(contentsOf: pendingDirectories.reversed())
        }

        // Table order, deduplicated — deterministic output for fn-3.2, and
        // obstructions in declaration order for a deterministic message.
        let names = userDataShapePatterns.map(\.name).filter(matched.contains)
        return UserDataProbeResult(
            matches: names, obstructions: obstructions.sorted()
        )
    }

    /// Does descending into `child` cross a mount boundary?
    ///
    /// The house rule VERBATIM — both signals, no third notion invented
    /// here: (a) device-id change against the WALK ROOT, which catches
    /// foreign volumes and injected test devices, and (b) the `statfs`
    /// mount-root check, required because a unified APFS volume group
    /// presents ONE `st_dev` across the system/Data pair, so a firmlink
    /// mount is invisible to (a). Identical to `DirectorySizer.swift:289`;
    /// a `nil` device on either side disables only arm (a), exactly as it
    /// does there.
    ///
    /// `child` is `lstat`-probed as a real directory before this runs, so a
    /// symlink pointing AT a volume root never reaches here (and is never
    /// followed regardless — the no-follow rule).
    private static func crossesMountBoundary(
        _ child: URL,
        rootDevice: UInt64?,
        provider: FileSystemIdentityProvider
    ) -> Bool {
        let childDevice = provider.deviceID(of: child)
        if rootDevice != nil && childDevice != nil
            && childDevice != rootDevice {
            return true
        }
        return provider.isMountPoint(child)
    }

    /// The outcome of ONE bounded directory read.
    enum BoundedDirectoryRead: Equatable {
        /// The basenames read — at most `limit` of them — and EVERY reason
        /// the rest of the directory is unproven, deduplicated and in
        /// declaration order. Empty iff the directory was PROVEN exhausted.
        ///
        /// A list rather than one slot (PR #458 review r3): a single read
        /// can establish more than one cause at once — the sentinel entry
        /// that proves the directory is over budget can ALSO be the one
        /// whose name will not decode — and a single slot silently kept
        /// whichever the control flow reached first.
        case read([String], truncatedBy: [UserDataProbeObstruction])
        /// The directory could not be opened at all.
        case unreadable(UserDataProbeObstruction)
    }

    /// BOUNDED directory read: at most `limit` basenames, plus whether the
    /// enumeration was PROVEN exhausted.
    ///
    /// `opendir`/`readdir` rather than `FileManager` on purpose — both
    /// `contentsOfDirectory` overloads materialize the WHOLE directory
    /// before any cap can apply, which is exactly the unbounded read this
    /// probe's contract forbids (PR #458 review): a cache directory with
    /// millions of entries would spike memory and stall the scan inside a
    /// walk that only ever inspects `entryLimit` of them. Reading BASENAMES
    /// also keeps the walk's own spelling: the caller appends them to ITS
    /// OWN directory URL, so a no-follow `lstat` lands on the path the
    /// deletion would remove rather than a resolved one. `.` and `..` are
    /// skipped; hidden entries are INCLUDED (user data in a dot-directory is
    /// still user data), matching the enumeration's `options: []` stance.
    ///
    /// Internal for the bound test — nothing outside this file calls it.
    ///
    /// UNDECODABLE NAMES FAIL CLOSED: `String(validatingCString:)`, never
    /// `String(cString:)`. A repairing decode substitutes U+FFFD, and the
    /// URL rebuilt from that lie names a DIFFERENT path — `probeKind` would
    /// report it absent and the probe could return "complete, nothing found"
    /// while the real entry (a `Photos Library.photoslibrary`, say) was
    /// never inspected. APFS and HFS+ reject non-UTF-8 basenames outright
    /// (EILSEQ), but a mounted exFAT/SMB/FUSE volume can deliver them. The
    /// read STOPS at the first undecodable entry: the directory is already
    /// unproven, and continuing would let a directory full of such names
    /// spend the budget for nothing.
    static func boundedChildNames(
        of directory: URL,
        limit: Int,
        decode: (UnsafePointer<CChar>) -> String? = decodedBasename(fromCString:)
    ) -> BoundedDirectoryRead {
        guard let handle = opendir(directory.path) else {
            return .unreadable(obstruction(forErrno: errno))
        }
        defer { closedir(handle) }
        var names: [String] = []
        var truncated: Set<UserDataProbeObstruction> = []

        read: while true {
            // `readdir` returns nil for BOTH end-of-stream and error; errno
            // is the only discriminator, so it is cleared before each call.
            errno = 0
            guard let entry = readdir(handle) else {
                if errno != 0 {
                    // A failed read mid-directory: the rest is unproven, and
                    // an I/O error is honestly retryable. Deliberately NOT
                    // also budget exhaustion, even at a full `names` — the
                    // read FAILED, so no further entry was ever proven to
                    // exist. Only claim what was actually established.
                    truncated.insert(obstruction(forErrno: errno))
                }
                break read
            }
            let decoded = withUnsafeBytes(of: entry.pointee.d_name) {
                raw -> String? in
                guard let base = raw.bindMemory(to: CChar.self).baseAddress
                else { return nil }
                return decode(base)
            }
            guard let name = decoded, !name.isEmpty else {
                truncated.insert(.undecodableName)
                // AND the budget, when this entry is the SENTINEL (PR #458
                // review r3). `.` and `..` both decode, so an undecodable
                // entry is always a REAL one: meeting it on a full `names`
                // proves the directory holds more than the budget allows,
                // exactly as a decodable entry there would. Losing that
                // proof to the decode guard left the walk reporting only
                // "rename it and re-inspect" — while the unchanged entry
                // count still exceeds the budget, so the next scan refuses
                // again and the irreducible remedy is never offered. The
                // causes are CONJUNCTIVE and both survive clearing the
                // other (raise the budget and this name still stops the
                // walk; rename it and the count still does), so both are
                // recorded and the remedy ordering picks the closing.
                if names.count >= limit { truncated.insert(.budgetExhausted) }
                break read
            }
            if name == "." || name == ".." { continue }
            guard names.count < limit else {
                // A real entry existed beyond the budget — the ONLY way this
                // read reports budget exhaustion, and it costs one `readdir`
                // rather than the whole directory.
                truncated.insert(.budgetExhausted)
                break read
            }
            names.append(name)
        }
        // ONE exit, carrying everything proven — no guard can preempt the
        // bookkeeping by returning ahead of it.
        return .read(names, truncatedBy: truncated.sorted())
    }

    /// The VALIDATING basename decode, factored out so the fail-closed
    /// policy is testable without a non-UTF-8-capable volume (APFS/HFS+
    /// refuse to create such names at all). `nil` for ANY byte sequence that
    /// is not valid UTF-8 — never a U+FFFD-repaired string, which would name
    /// a different path than the entry it came from.
    static func decodedBasename(
        fromCString pointer: UnsafePointer<CChar>
    ) -> String? {
        String(validatingCString: pointer)
    }

    // MARK: - Remediation guidance (PR #458 review)

    /// The delete-time remediation guidance for an incomplete probe:
    /// what actually obstructed it, and what — honestly — would clear it.
    ///
    /// The rule is one sentence long: NEVER claim a verdict is permanent
    /// unless every cause behind it really is. A mid-walk race and a
    /// transient I/O or permission error clear on retry; a mount boundary
    /// clears on unmount; an exhausted budget on a static tree clears on
    /// neither, and only THAT case may steer a user toward the riskier
    /// explicit-confirmation path. The previous message asserted permanence
    /// for the whole set, which is how a disk hiccup came to read as "this
    /// will never work, confirm it manually".
    static func remediationGuidance(
        for obstructions: [UserDataProbeObstruction]
    ) -> String {
        // Deduplicated and ordered, so a caller that hands over a repeated
        // cause still gets each one stated once, in declaration order.
        let causes = Set(obstructions).sorted()
        // CONJUNCTIVE, not best-of: the user has to clear EVERY cause, so
        // the closing advice is the MOST DEMANDING remedy present, never
        // the easiest. Best-of closed a budget-plus-transient set with
        // "re-scan and try again" — the transient clears, the over-budget
        // folder does not, the probe refuses again, and no remedy is ever
        // offered: the exact stranding loop this work exists to remove.
        // Every cause is still described above the closing, so the easier
        // remedies are not lost — only the promise that they suffice.
        guard let binding = causes.map(\.remedy).max() else { return "" }
        var sentences = causes.map(\.guidance)

        switch binding {
        case .retryAlone:
            sentences.append("Re-scan and try again.")
        case .userActionThenRetry:
            sentences.append(causes.count == 1
                ? "Clear that, then re-scan."
                : "Clear all of the above, then re-scan.")
        case .unknown:
            sentences.append(
                "Re-scanning may or may not clear this; if it repeats, "
                + "remove this item by explicit per-item confirmation once a "
                + "re-scan lists it at review risk."
            )
        case .irreducible:
            sentences.append(
                "Re-scanning will not clear this — an unchanged folder is "
                + "inspected the same way and reports the same thing every "
                + "time, whatever else is fixed first; remove this item by "
                + "explicit per-item confirmation once a re-scan lists it at "
                + "review risk."
            )
        }
        return sentences.joined(separator: " ")
    }
}

// MARK: - Config surface (fn-3.4, R8)

/// The sweep's two knobs — size floor (decimal MB) and stale age (days) —
/// layered defaults → UserDefaults → CLI flags at the COMPOSITION site
/// (`SpaceScannerRuntime.production` / the CLI handlers). Fail-safe by
/// contract: conversions are overflow-checked and never trap; an invalid
/// PERSISTED value (≤ 0, non-numeric, non-integral, overflow) falls back to
/// the default for that scan and is NEVER rewritten — a value this build
/// cannot read may be meaningful to another build.
enum OrphanedCachesSweepConfig {

    /// UserDefaults keys, per the `cacheout.*` precedent
    /// (`CacheoutViewModel`).
    static let sizeFloorMBKey = "cacheout.orphanedCaches.sizeFloorMB"
    static let staleAgeDaysKey = "cacheout.orphanedCaches.staleAgeDays"

    static let defaultSizeFloorMB: Int64 = 50
    static let defaultStaleAgeDays: Int64 = 60

    /// 50 MB / 60 days, through the same checked conversions as every other
    /// value (the force-unwraps are compile-time constants proven finite).
    static let defaultThresholds = OrphanedCacheClassifier.Thresholds(
        sizeFloorBytes: sizeFloorBytes(fromMB: defaultSizeFloorMB)!,
        staleAge: staleAge(fromDays: defaultStaleAgeDays)!
    )

    /// MB → bytes at ×1,000,000 — DECIMAL, matching the app's base-10
    /// `ByteCountFormatter` display convention. `nil` on non-positive or
    /// overflowing input (never traps).
    static func sizeFloorBytes(fromMB megabytes: Int64) -> Int64? {
        guard megabytes > 0 else { return nil }
        let (bytes, overflow) = megabytes
            .multipliedReportingOverflow(by: 1_000_000)
        return overflow ? nil : bytes
    }

    /// Days → seconds at ×86,400, overflow-checked in integer space before
    /// the `TimeInterval` conversion. `nil` on non-positive or overflowing
    /// input (never traps).
    static func staleAge(fromDays days: Int64) -> TimeInterval? {
        guard days > 0 else { return nil }
        let (seconds, overflow) = days.multipliedReportingOverflow(by: 86_400)
        return overflow ? nil : TimeInterval(seconds)
    }

    /// The layered resolution: an invocation-scoped OVERRIDE (CLI flag —
    /// already validated by the CLI's invalid-arguments gate) wins; else a
    /// VALID persisted value; else the default. Each half resolves
    /// independently, and nothing is ever written back to UserDefaults.
    static func resolvedThresholds(
        defaults: UserDefaults = .standard,
        sizeFloorMBOverride: Int64? = nil,
        staleAgeDaysOverride: Int64? = nil
    ) -> OrphanedCacheClassifier.Thresholds {
        let floorMB = sizeFloorMBOverride
            ?? persistedPositiveInteger(defaults.object(forKey: sizeFloorMBKey))
        let ageDays = staleAgeDaysOverride
            ?? persistedPositiveInteger(defaults.object(forKey: staleAgeDaysKey))
        // A value that parses but overflows its conversion is INVALID too —
        // same fallback, still no rewrite.
        return OrphanedCacheClassifier.Thresholds(
            sizeFloorBytes: floorMB.flatMap(sizeFloorBytes(fromMB:))
                ?? defaultThresholds.sizeFloorBytes,
            staleAge: ageDays.flatMap(staleAge(fromDays:))
                ?? defaultThresholds.staleAge
        )
    }

    /// A persisted value read as a positive INTEGER, or nil when it is
    /// absent or invalid (non-numeric, non-integral, boolean, zero,
    /// negative, or past Int64). Both NSNumber (the normal
    /// `set(_:forKey:)` shapes) and numeric strings are accepted —
    /// nothing else.
    static func persistedPositiveInteger(_ stored: Any?) -> Int64? {
        if let number = stored as? NSNumber {
            // A persisted Bool bridges to NSNumber (`true` → 1) — a
            // boolean is not a positive-integer threshold, so it is
            // invalid like any other non-numeric value (falls back to the
            // default, never rewritten). CFBoolean is the toll-free type
            // a bridged Bool actually carries.
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else {
                return nil
            }
            let value = number.doubleValue
            guard value.isFinite, value > 0,
                  value == value.rounded(),
                  let integer = Int64(exactly: value.rounded())
            else { return nil }
            return integer
        }
        if let string = stored as? String {
            guard let integer = Int64(string), integer > 0 else { return nil }
            return integer
        }
        return nil
    }
}

// MARK: - SpaceScanner conformance (fn-3.4)

extension OrphanedCachesScanner: SpaceScanner {

    var id: String { Self.registeredID }
    var displayName: String { "Orphaned Caches" }

    /// The sweep root, declared at registration — this is HOW the container
    /// reaches the cleaner: the runtime unions scanner-declared roots into
    /// PathGuard's delete-time admission (nothing item-side can widen it).
    var trustedContainerRoots: [URL] { [cachesRoot] }

    /// Protocol scan. The sweep ignores `categoryFilter` (category-scanner
    /// only) and runs on BOTH triggers — `~/Library/Caches` is not a
    /// TCC-gated search root; per-entry TCC denials are still classified by
    /// the sizer and propagated per R7.
    func scan(context: ScanContext) async -> ScanOutcome {
        switch enumerateFacts() {
        case .rootNotADirectory(let kind):
            // A symlinked/non-directory sweep root is NEVER traversed —
            // the scanner-level issue fn-2 defined for exactly this.
            return ScanOutcome(items: [], errors: [ScanIssue(
                url: cachesRoot,
                kind: .symlinkRoot,
                detail: "sweep root is not a real directory "
                    + "(\(Self.describe(kind))) — never traversed"
            )])
        case .rootUnreadable(let denial):
            // Root-level denial → classified ScanOutcome error (R7): the
            // GUI/CLI show "couldn't scan ~/Library/Caches", never an
            // empty-looking success (D6).
            return ScanOutcome(items: [], errors: [ScanIssue(
                url: denial.url,
                kind: Self.rootIssueKind(for: denial.kind),
                detail: denial.detail
            )])
        case .entries(let facts):
            let classifier = OrphanedCacheClassifier(
                thresholds: thresholds,
                installedAppStatus: installedAppStatus,
                now: now()
            )
            // classifyForOutput applies the frozen output-set rule AND the
            // frozen deterministic order — the mapping preserves it 1:1.
            let items = classifier.classifyForOutput(facts)
                .map(reclaimableItem(from:))
            return ScanOutcome(items: items, errors: [])
        }
    }

    // MARK: Item mapping (field by field — the fn-2 validator's invariants
    // are load-bearing here; see each field's note)

    /// One sweep entry's classification → one `ReclaimableItem`.
    ///
    /// State mapping (mount-boundary doctrine per the as-merged
    /// `NodeModulesScanner.reclaimableItem` — delete refuses a
    /// boundary-bearing target ENTIRELY, so `.partiallyDenied` is reserved
    /// for walk-denial impediments, where deletion partially succeeds):
    ///
    /// - ANY mount boundary (root or nested, measured content or not) →
    ///   `.denied`, ZERO components (components mean "deletion frees
    ///   these"; deletion frees nothing), the measured floor riding the
    ///   boundary-naming scanError message.
    /// - walk denial(s), no boundary + measured something →
    ///   `.partiallyDenied` with real components.
    /// - walk denial(s), no boundary + measured nothing → `.denied`, zero
    ///   components.
    /// - clean walk → `.measured` / `.empty`.
    private func reclaimableItem(
        from classification: SweepClassification
    ) -> ReclaimableItem {
        let entry = classification.entry
        let hasBoundary = entry.rootMountBoundary
            || !entry.mountBoundaries.isEmpty
        let measuredAnything = entry.itemCount > 0 || entry.allocatedBytes > 0

        let state: ScanState
        if hasBoundary {
            state = .denied
        } else if !entry.denials.isEmpty {
            state = measuredAnything ? .partiallyDenied : .denied
        } else {
            state = measuredAnything ? .measured : .empty
        }
        let deletable = state == .measured || state == .partiallyDenied

        // Identity path, FROZEN (epic rule): canonical PARENT chain +
        // UNRESOLVED leaf. Fully canonicalizing the leaf would point
        // identity and display OUTSIDE the container for symlink entries,
        // and two symlink entries sharing one target would collide on one
        // id — which fn-2's outcome validation rejects as duplicate ids,
        // poisoning the ENTIRE outcome. The ORIGINAL unresolved spelling
        // stays the deletion input (`requestedTargetURL` / `requestedURL`).
        let identity = provider.resolveTargetKeepingLeaf(entry.url)

        // Exactly ONE root record (a missing entry never becomes an item).
        // `.deniedUnmeasured` iff nothing deletable was established —
        // matching the frozen truth table and check (e)'s `.denied` shape.
        let record = RootScanRecord(
            requestedURL: entry.url,
            resolvedURL: identity,
            status: state == .denied ? .deniedUnmeasured : .measured
        )

        // Selection triple: the classifier's clean-knownLeak-only flags,
        // additionally gated on a cleanly `.measured` state — an `.empty`
        // leak row (e.g. a glob-matching symlink) is unselectable in every
        // surface, and the item itself must not claim otherwise.
        let selectable = classification.defaultSelected && state == .measured

        let isStale: Bool?
        switch classification.tier {
        case .staleLarge:
            isStale = true
        case .knownLeak, .orphan, .unclassified:
            // Staleness is knowable only when the walk dated content.
            isStale = entry.newestContentDate == nil ? nil : false
        }

        return ReclaimableItem(
            id: ReclaimableItem.stableID(
                scannerID: Self.registeredID, canonicalPath: identity.path
            ),
            scannerID: Self.registeredID,
            displayName: entry.name,
            // A `.denied` item publishes ZERO components (frozen coherence
            // shape): every consumer reads them as "deletion frees these",
            // and deletion is refused. The boundary case's measured floor
            // rides the scanError message instead.
            exactBytes: deletable ? entry.exactBytes : 0,
            estimatedUpToBytes: deletable ? entry.estimatedUpToBytes : 0,
            // Only the sparse-divergence direction that matters for honest
            // display (logical exceeding allocated — deletion frees LESS
            // than the apparent size); block-rounding noise stays nil.
            logicalBytes: deletable && entry.logicalBytes > entry.allocatedBytes
                ? entry.logicalBytes : nil,
            itemCount: deletable ? entry.itemCount : 0,
            // DISPLAY ONLY (destructive-target rule) — the same identity
            // the binding record resolves to, per check (f)'s
            // display-identity rule.
            url: identity,
            declaredDisplayPath: Self.displayPath(of: entry.url, home: home),
            rootRecords: [record],
            state: state,
            scanError: Self.sweepScanError(for: entry),
            risk: classification.risk,
            // The item model carries ONE evidence string; the classifier's
            // deterministic lines join in order.
            evidence: classification.evidence.joined(separator: "; "),
            rebuildNote: classification.tier == .orphan
                ? "reinstalling the app recreates its cache" : nil,
            // `.removeItem` — the entry directory ITSELF is deleted, trash
            // honored via fn-2's cleaner. NOT `.removeContents`: the frozen
            // validator reserves that for category provenance.
            action: .removeItem,
            // Frozen arm: origin = the scanner's own declared container
            // (check (f) binds it to the registration declaration), target
            // = the UNRESOLVED entry spelling (leaf never resolved — fn-1
            // dual-canonicalization doctrine).
            admission: .containerItem(
                originContainer: cachesRoot,
                requestedTargetURL: entry.url
            ),
            defaultSelected: selectable,
            automaticCleanEligible: selectable,
            isStale: isStale
        )
    }

    /// The single `scanError`, by FROZEN precedence when conditions coexist
    /// (an entry can carry BOTH a denial and a mount boundary; either-order
    /// overwrites would suppress the TCC grant hint): `tccDenied` →
    /// `permissionDenied` → other denial (`.other`) → mount boundary
    /// (`.other`, boundary detail). The most ACTIONABLE error wins the one
    /// error slot; EVERY condition still appears in the item's evidence,
    /// and the state is the more severe mapping regardless.
    static func sweepScanError(for entry: SweptCacheEntry) -> ScanError? {
        let denials = entry.denials
        if let ranked = denials.first(where: { $0.kind == .tcc })
            ?? denials.first(where: { $0.kind == .permission })
            ?? denials.first {
            return ScanError(
                kind: ranked.kind.scanErrorKind,
                message: "\(ranked.url.path): \(ranked.detail)"
            )
        }
        guard entry.rootMountBoundary || !entry.mountBoundaries.isEmpty else {
            return nil
        }
        return mountBoundaryScanError(for: entry)
    }

    /// The boundary-naming error, mirroring the as-merged
    /// `NodeModulesScanner` doctrine: `.other` (a boundary is neither TCC
    /// nor BSD permissions, and no grant would lift it), the message naming
    /// the boundary — and carrying the measured floor when the walk
    /// measured readable content beside it, because the item's byte
    /// components must stay zero (they mean "deletion frees these", and a
    /// boundary-bearing target is refused whole).
    private static func mountBoundaryScanError(
        for entry: SweptCacheEntry
    ) -> ScanError {
        let boundary = entry.mountBoundaries.first ?? entry.url
        var message = entry.rootMountBoundary
            ? "\(boundary.path): item is a mount point — not measured; "
                + "deletion would be refused"
            : "mount boundary at \(boundary.path) — subtree not measured; "
                + "deletion would be refused"
        if entry.itemCount > 0 || entry.allocatedBytes > 0 {
            let floor = CleanupReport.componentPhrase(
                exact: entry.exactBytes,
                estimatedUpTo: entry.estimatedUpToBytes
            )
            message += " (\(floor) measured beside the boundary is not "
                + "reclaimable while the boundary remains)"
        }
        return ScanError(kind: .other, message: message)
    }

    /// Root-level denial → `ScanIssue.Kind`, same taxonomy as the sizer's
    /// classification (R7).
    private static func rootIssueKind(
        for kind: SizeDenial.Kind
    ) -> ScanIssue.Kind {
        switch kind {
        case .tcc: return .tccDenied
        case .permission: return .permissionDenied
        case .metadata, .other: return .unreadable
        }
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

    /// The declared display spelling: the entry's unresolved path,
    /// home-shortened to `~` on a PATH-COMPONENT boundary (a sibling that
    /// merely string-prefixes the home path must never render as `~…`,
    /// least of all beside a destructive `.removeItem` action).
    private static func displayPath(of url: URL, home: URL) -> String {
        let path = url.path
        let homePath = home.path
        if path == homePath { return "~" }
        let prefix = homePath.hasSuffix("/") ? homePath : homePath + "/"
        guard path.hasPrefix(prefix) else { return path }
        return "~/" + path.dropFirst(prefix.count)
    }
}
