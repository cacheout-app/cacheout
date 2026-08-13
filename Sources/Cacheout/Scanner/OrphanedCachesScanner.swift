/// # OrphanedCachesScanner — ~/Library/Caches Sweep Enumeration Core (fn-3.1)
///
/// A 31G leaked directory (`com.apple.SwiftUI.Drag-<UUID>` holding a complete
/// Photos-library copy) sat in `~/Library/Caches`, invisible to the fixed
/// category allowlist (FIELD-EVIDENCE-2026-08-06 scenario 4). An allowlist
/// only reclaims what its authors have already seen leak — this scanner
/// enumerates the caches directory and explains what it finds.
///
/// This file currently holds the PROTOCOL-INDEPENDENT enumeration half: it
/// produces per-entry FACTS, no judgments. Classification (tiers, risk,
/// evidence) is fn-3.2; installed-app resolution is fn-3.3; `SpaceScanner`
/// conformance, config, and registration land in fn-3.4 (in this same file).
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
/// The exclusion set is built from DECLARED discovery roots — all three
/// `PathDiscovery` kinds, probed FALLBACKS included, probe stdout
/// contributing nothing (deterministic + hermetic; the exact stance of
/// `CategoryAdmissionPolicy(category:home:)`, which this reuses).

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
/// probe depth.
struct UserDataShapePattern: Equatable {
    let name: String
    let glob: String
}

// MARK: - OrphanedCachesScanner (enumeration core)

struct OrphanedCachesScanner {

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

    init(
        home: URL,
        cachesRoot: URL? = nil,
        categories: [CacheCategory] = CacheCategory.allCategories,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider(),
        probeDepthLimit: Int = 3,
        probeEntryLimit: Int = 512
    ) {
        self.home = home
        self.cachesRoot = cachesRoot
            ?? home.appendingPathComponent(Self.sweepRootRelativePath)
        self.categories = categories
        self.provider = provider
        self.sizer = DirectorySizer(provider: provider)
        self.probeDepthLimit = probeDepthLimit
        self.probeEntryLimit = probeEntryLimit
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
    /// components. Reuses `CategoryAdmissionPolicy(category:home:)` for the
    /// declared-root resolution — all three `PathDiscovery` kinds, probed
    /// FALLBACKS included, probe stdout contributing nothing.
    ///
    /// Step 1 — scope filter: keep ONLY roots STRICTLY below the sweep
    /// root. A root outside the sweep root, or EQUAL to it, contributes
    /// NOTHING — otherwise a category declaring e.g. `~/Library` (an
    /// ancestor of every entry) would silently suppress the entire sweep.
    private func categoryExclusionRoots() -> [[String]] {
        let rootComponents = cachesRoot.standardizedFileURL.pathComponents
        var kept: [[String]] = []
        for category in categories {
            let policy = CategoryAdmissionPolicy(category: category, home: home)
            for declared in policy.declaredRoots {
                let components = declared.url.standardizedFileURL.pathComponents
                guard components.count > rootComponents.count,
                      components.starts(with: rootComponents)
                else { continue }
                kept.append(components)
            }
        }
        return kept
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

    /// Bounded shallow walk of one REAL-DIRECTORY entry, matching basenames
    /// against `userDataShapePatterns`. Returns the matched pattern NAMES
    /// (in table order, deduplicated) and the fail-closed completeness flag.
    ///
    /// NO-FOLLOW rule (safety — mirrors `.deletionTarget` sizing): the
    /// caller lstat-gates the probe root, and every descent below is
    /// lstat-gated here; a nested symlink is matched by NAME only and never
    /// traversed. Without this, `contentsOfDirectory` on a symlink would
    /// inspect data outside ~/Library/Caches and undo the safety the sizing
    /// mode bought. An unexpanded symlink does NOT mark the probe
    /// incomplete: deleting the entry removes the link, never its target,
    /// so no deletable content went uninspected.
    private func probeUserDataShapes(at entryURL: URL) -> (matches: [String], complete: Bool) {
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
                guard visited < probeEntryLimit else {
                    // Entry cap hit before exhausting the tree.
                    complete = false
                    break walk
                }
                visited += 1

                let name = child.lastPathComponent
                for pattern in Self.userDataShapePatterns
                where fnmatch(pattern.glob, name, 0) == 0 {
                    matched.insert(pattern.name)
                }

                switch provider.probeKind(of: child) {
                case .kind(.directory):
                    let childDepth = depth + 1
                    if childDepth < probeDepthLimit {
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
        let names = Self.userDataShapePatterns.map(\.name).filter(matched.contains)
        return (names, complete)
    }
}
