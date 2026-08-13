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
/// The exclusion set is built from DECLARED discovery roots — never probe
/// stdout — with ONE gate (PR #456 review): a `.probed` entry's fallbacks
/// are excluded only while its `requiresTool` is PRESENT, because a missing
/// tool makes `CacheCategory.resolvedPaths(home:)` skip the whole discovery
/// entry (fallbacks included), so the category scan provably does not own
/// the fallback this session — and the stale cache an uninstalled tool left
/// behind (the exact case this epic exists for) must surface HERE instead
/// of being invisible to both surfaces. Tool presence is the same bounded
/// `which` check the category scan gates on, memoized per enumeration and
/// consulted only for fallbacks inside the sweep root; probe COMMANDS still
/// never run during exclusion-set construction.

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
    /// meaningful when the probe COMPLETED. False when the entry cap was
    /// hit before exhausting, when any directory at the depth boundary was
    /// left unexpanded, or when any branch was unreadable — fn-3.2 treats
    /// an incomplete probe like a caution (review risk, no default or
    /// automatic selection).
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

    /// PRODUCTION probe caps — one definition shared by the init defaults
    /// and the delete-time revalidation entry point
    /// (`preDeleteUserDataProbe`), so scan-time and delete-time inspection
    /// bounds can never drift apart.
    static let defaultProbeDepthLimit = 3
    static let defaultProbeEntryLimit = 512

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
    /// User-data probe caps — the probe is BOUNDED (only the sizing walk is
    /// complete). Injectable so tests can prove the fail-closed cap
    /// behavior without thousand-file fixtures.
    private let probeDepthLimit: Int
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
    /// Tool-presence gate for probed-fallback exclusion (R3, PR #456
    /// review) — injectable so tests stay hermetic; the production default
    /// mirrors `CacheCategory.toolExists` (same `which`, same PATH/HOME
    /// environment, same bounded wait), because the two MUST agree on
    /// whether the category scan attempts a probed discovery entry.
    private let toolIsAvailable: @Sendable (String) -> Bool

    init(
        home: URL,
        cachesRoot: URL? = nil,
        categories: [CacheCategory] = CacheCategory.allCategories,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider(),
        probeDepthLimit: Int = OrphanedCachesScanner.defaultProbeDepthLimit,
        probeEntryLimit: Int = OrphanedCachesScanner.defaultProbeEntryLimit,
        thresholds: OrphanedCacheClassifier.Thresholds =
            OrphanedCachesSweepConfig.defaultThresholds,
        installedAppStatus: @escaping @Sendable (String) -> InstalledAppStatus =
            { _ in .unknown },
        now: @escaping @Sendable () -> Date = { Date() },
        toolAvailability: (@Sendable (String) -> Bool)? = nil
    ) {
        self.home = home
        self.cachesRoot = cachesRoot
            ?? home.appendingPathComponent(Self.sweepRootRelativePath)
        self.categories = categories
        self.provider = provider
        self.sizer = DirectorySizer(provider: provider)
        self.probeDepthLimit = probeDepthLimit
        self.probeEntryLimit = probeEntryLimit
        self.thresholds = thresholds
        self.installedAppStatus = installedAppStatus
        self.now = now
        self.toolIsAvailable = toolAvailability
            ?? { Self.productionToolAvailability($0, home: home) }
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

            let matches: [String]
            let probeComplete: Bool
            switch provider.probeKind(of: child) {
            case .absent:
                // Deleted between enumeration and probe — a benign mid-scan
                // race, not a denial.
                continue
            case .kind(.directory):
                (matches, probeComplete) = probeUserDataShapes(at: child)
            case .kind:
                // Symlink / regular file / special: no contents of their
                // own to probe — complete by construction. A symlink is
                // NEVER followed: deleting the entry removes the link, not
                // its target, so nothing deletable went uninspected.
                matches = []
                probeComplete = true
            case .failed:
                // Cannot even establish the kind — fail closed; the sizing
                // pass below records the classified denial for the facts.
                matches = []
                probeComplete = false
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
                userDataShapeMatches: matches,
                userDataProbeComplete: probeComplete
            ))
        }

        return .entries(facts)
    }

    // MARK: - Category-owned exclusion (R3)

    /// Declared category roots kept for exclusion, as standardized path
    /// components. Path construction mirrors BOTH
    /// `CategoryAdmissionPolicy(category:home:)` and
    /// `CacheCategory.resolvedPaths(home:)` — all three `PathDiscovery`
    /// kinds, `.staticPath` and non-`/`-prefixed probed fallbacks anchored
    /// to the injected home, probe stdout contributing nothing.
    ///
    /// Step 1 — scope filter: keep ONLY roots STRICTLY below the sweep
    /// root. A root outside the sweep root, or EQUAL to it, contributes
    /// NOTHING — otherwise a category declaring e.g. `~/Library` (an
    /// ancestor of every entry) would silently suppress the entire sweep.
    ///
    /// Step 1b — tool gate on probed fallbacks (PR #456 review): a
    /// `.probed` entry with an ABSENT `requiresTool` is skipped ENTIRELY by
    /// the category scan (`CacheCategory.resolvedPaths`), fallbacks
    /// included, so excluding them here would hide the stale cache an
    /// uninstalled tool left behind from BOTH surfaces. Gate order is
    /// deliberate — scope filter FIRST, so the bounded `which` runs only
    /// for fallbacks that could actually contribute (production: 4 distinct
    /// tools), memoized per enumeration. While the tool IS present the
    /// exclusion deliberately stays a SUPERSET of what the category scan
    /// captured (all declared fallbacks, even when the probe resolved
    /// elsewhere or a later fallback lost the first-match cut) —
    /// conservative against double listing, and a declared-but-uncaptured
    /// root remains attributable to its category by declaration. A probed
    /// entry with NO `requiresTool` is always attempted by the category
    /// scan, so its fallbacks stay unconditionally excluded, exactly as
    /// before.
    private func categoryExclusionRoots() -> [[String]] {
        let rootComponents = cachesRoot.standardizedFileURL.pathComponents
        var toolPresence: [String: Bool] = [:]
        var kept: [[String]] = []
        for category in categories {
            for entry in category.discovery {
                let declared: [URL]
                let gatingTool: String?
                switch entry {
                case .staticPath(let relative):
                    declared = [home.appendingPathComponent(relative)]
                    gatingTool = nil
                case .absolutePath(let absolute):
                    declared = [URL(fileURLWithPath: absolute)]
                    gatingTool = nil
                case .probed(_, let requiresTool, let fallbacks):
                    declared = fallbacks.map {
                        $0.hasPrefix("/")
                            ? URL(fileURLWithPath: $0)
                            : home.appendingPathComponent($0)
                    }
                    gatingTool = requiresTool
                }
                for url in declared {
                    let components = url.standardizedFileURL.pathComponents
                    guard components.count > rootComponents.count,
                          components.starts(with: rootComponents)
                    else { continue }
                    if let tool = gatingTool {
                        let present: Bool
                        if let cached = toolPresence[tool] {
                            present = cached
                        } else {
                            present = toolIsAvailable(tool)
                            toolPresence[tool] = present
                        }
                        guard present else { continue }
                    }
                    kept.append(components)
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

    /// Bounded shallow walk of one REAL-DIRECTORY entry — the instance
    /// (scan-time) face of the shared static core below, using the
    /// injectable per-instance caps.
    private func probeUserDataShapes(at entryURL: URL) -> (matches: [String], complete: Bool) {
        Self.boundedUserDataShapeWalk(
            at: entryURL, provider: provider,
            depthLimit: probeDepthLimit, entryLimit: probeEntryLimit
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
    /// - real directory → the bounded no-follow walk (PRODUCTION caps);
    /// - symlink / regular file / special → no contents of their own —
    ///   clean and complete by construction (deletion removes the leaf
    ///   as-is, never a target's tree);
    /// - absent → clean and complete: the deletion path surfaces its own
    ///   ENOENT (frozen ghost asymmetry) — the probe must not preempt it;
    /// - unprobeable → fail closed (incomplete).
    static func preDeleteUserDataProbe(
        at target: URL, provider: FileSystemIdentityProvider
    ) -> (matches: [String], complete: Bool) {
        switch provider.probeKind(of: target) {
        case .kind(.directory):
            return boundedUserDataShapeWalk(
                at: target, provider: provider,
                depthLimit: defaultProbeDepthLimit,
                entryLimit: defaultProbeEntryLimit
            )
        case .kind:
            return ([], true)
        case .absent:
            return ([], true)
        case .failed:
            return ([], false)
        }
    }

    /// The ONE bounded user-data-shape walk, shared by the scan-time probe
    /// and the delete-time revalidation so the two can never drift. Matches
    /// basenames against `userDataShapePatterns`, returning the matched
    /// pattern NAMES (in table order, deduplicated) and the fail-closed
    /// completeness flag.
    ///
    /// NO-FOLLOW rule (safety — mirrors `.deletionTarget` sizing): the
    /// caller lstat-gates the probe root, and every descent below is
    /// lstat-gated here; a nested symlink is matched by NAME only and never
    /// traversed. Without this, `contentsOfDirectory` on a symlink would
    /// inspect data outside ~/Library/Caches and undo the safety the sizing
    /// mode bought. An unexpanded symlink does NOT mark the probe
    /// incomplete: deleting the entry removes the link, never its target,
    /// so no deletable content went uninspected.
    private static func boundedUserDataShapeWalk(
        at entryURL: URL,
        provider: FileSystemIdentityProvider,
        depthLimit: Int,
        entryLimit: Int
    ) -> (matches: [String], complete: Bool) {
        let fileManager = FileManager.default
        var matched = Set<String>()
        var complete = true
        var visited = 0
        // Depth-first with sorted children — deterministic order; the entry
        // itself sits at depth 0, its children at depth 1.
        var stack: [(url: URL, depth: Int)] = [(entryURL, 0)]

        walk: while let (dir, depth) = stack.popLast() {
            let children: [URL]
            do {
                // Hidden entries included, same stance as the enumeration.
                children = try fileManager.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil, options: []
                ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            } catch {
                // Unreadable branch: absence of matches is unproven.
                complete = false
                continue
            }
            for child in children {
                guard visited < entryLimit else {
                    // Entry cap hit before exhausting the tree.
                    complete = false
                    break walk
                }
                visited += 1

                let name = child.lastPathComponent
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
                    let childDepth = depth + 1
                    if childDepth < depthLimit {
                        stack.append((child, childDepth))
                    } else {
                        // A directory at the depth boundary left unexpanded:
                        // a match could hide just past it (fail closed).
                        complete = false
                    }
                case .kind:
                    // Symlink / regular file / special: matched by name
                    // above, never descended (see the no-follow rule).
                    break
                case .absent:
                    // Vanished mid-probe — benign race.
                    break
                case .failed:
                    // Could not establish the kind — fail closed.
                    complete = false
                }
            }
        }

        // Table order, deduplicated — deterministic output for fn-3.2.
        let names = userDataShapePatterns.map(\.name).filter(matched.contains)
        return (names, complete)
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
