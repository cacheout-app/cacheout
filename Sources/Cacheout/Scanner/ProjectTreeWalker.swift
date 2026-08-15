/// # ProjectTreeWalker — Reusable Project-Tree Walk (fn-4.2, R2/R9/R11/R12)
///
/// The REUSABLE walker COMPONENT (epic D2: independent walks per scanner,
/// NOT a shared traversal — fn-4's build-artifacts scanner and fn-5's
/// worktree scanner each instantiate their own walk). Rule-agnostic:
/// consumers receive one `ProjectTreeEvent` per visited directory and return
/// descend/prune verdicts per child; the walker itself never knows what a
/// "matched artifact dir" is.
///
/// ## Event + verdict contract (epic R9)
/// - One event per visited directory: `(directory, depth, originRoot,
///   entries)` — `originRoot` is the EXACT declared dev-root spelling the
///   walk started under, carried VERBATIM on every event (the validator's
///   origin binding string-compares it against the producing scanner's
///   declared `trustedContainerRoots`; fn-4.3 stamps it into
///   `.containerItem(originContainer:)`). Directory URLs are built by
///   appending entry names to the declared spelling, so provenance survives
///   alias-declared roots end to end.
/// - Entries are the directory's immediate children with lstat NO-FOLLOW
///   kinds, byte-wise name-sorted (deterministic event order — never
///   filesystem order). This one shape serves fn-4.3 (artifact dir + marker
///   siblings in one event) and fn-5 (`.git` file-vs-directory
///   discrimination).
/// - Verdicts: each consumer returns the set of child NAMES it wants pruned.
///   A child descends unless EVERY consumer prunes it (default with no
///   verdict: descend). In a SINGLE-consumer walk a prune verdict is
///   therefore decisive; in a MULTI-consumer walk pruning requires
///   unanimity — a child pruned by one consumer but descended by another IS
///   descended. With zero consumers nothing is pruned.
/// - `.git` is a walker-level HARD prune regardless of consumers: it appears
///   in entries (fn-5 classifies it — a worktree's `.git` FILE reports
///   `.regularFile`) but its children are never visited.
///
/// ## Safety (epic R11/R12)
/// - Per root, `PathGuard.admitSearchRoot` runs BEFORE any traversal
///   (scan-time, read-only, snapshot-free); refusal is a classified per-root
///   issue and the root is never walked.
/// - lstat gate on every descent: symlink children are NEVER descended
///   (listed in entries as `.symlink`); a symlink-LEAF or non-directory root
///   is refused with a classified issue; an ABSENT root is a QUIET no-item
///   omission (seeds routinely include roots most machines lack). Symlinked
///   ANCESTORS of a declared root are LEGAL (`/var`-style aliases — the
///   leaf lstats real through them) and every event under such a root
///   carries the alias spelling verbatim.
/// - The absence boundary: an INDIVIDUAL entry vanishing between enumeration
///   and descent is a benign deletion race — skipped QUIETLY; but failure of
///   the CURRENT enumerated directory, or of the ORIGIN ROOT after admission
///   (unmount, deletion, permission loss mid-scan), emits a per-root
///   classified issue — never a silent skip (R12).
/// - Mount boundaries are never crossed: a child on a different device than
///   the walk root, or one `statfs`-marked as a mount root, is listed but
///   never descended (a boundary-nested subtree is unreachable and
///   undeletable anyway; boundary handling on MATCHED dirs is fn-4.3's
///   doctrine). The non-crossing rule applies to DESCENT only: whether a
///   ROOT may itself be a mount point is the container-root policy's call,
///   and since fn-4.5 that policy runs INSIDE `admitSearchRoot` (R16 layer
///   c) — a mount-point root is refused there, with a classified per-root
///   issue, before this walker descends anything (a dev root INSIDE an
///   external volume stays perfectly legal).
/// - Hidden directories are traversed; never `.skipsHiddenFiles` or
///   `.skipsPackageDescendants`; NO name-based skip list (the
///   NodeModulesScanner anti-pattern R2 bans — it made monorepo
///   `packages/build/...` invisible).
///
/// ## Failure classification (epic R12)
/// Per-root enumeration/probe failures use the FROZEN `ScanIssue.Kind`
/// taxonomy: EPERM → `.tccDenied`, EACCES → `.permissionDenied` (the
/// `DirectorySizer.classifyDenial` precedent), anything else `.unreadable`.
/// `.malformedOutcome` is NEVER authored here (reserved to the validator).
/// TCC PROTECTION of a configured root is prefix-under-protected-ancestor on
/// the CANONICAL root path (a user-added `~/Documents/GitHub` is protected
/// because `Documents` is; an alias spelling INTO `~/Documents` via a
/// symlinked ancestor is protected as `~/Documents`) — never basename
/// matching (the NodeModulesScanner pattern this replaces).
///
/// ## Concurrency
/// `walk` is synchronous and isolation-inherited: it runs wherever the
/// caller runs (scanners call it from their own task, off the main actor —
/// the walker never touches the main actor). `Task.isCancelled` is checked
/// per entry with prompt partial return; consumers already ran for emitted
/// events, so partial accumulations stay coherent. Enumeration and entry
/// probing are wrapped in an `autoreleasepool` (long walks accumulate
/// URL/metadata allocations). Event order is deterministic: roots in caller
/// order, DFS pre-order within a root (parent before child), children
/// byte-wise name-ascending. Overlapping/nested kept roots are EXPECTED and
/// walked independently (D7: each root gets its own depth budget; item-level
/// canonical dedupe collapses the overlap in fn-4.3, not here).

import Foundation

/// One walk consumer: receives EVERY event of the walk and returns the set
/// of child names (of `event.entries`) it wants PRUNED. A name absent from
/// the set descends (default: descend); a child is skipped only when ALL
/// consumers prune it.
typealias ProjectTreeConsumer = (ProjectTreeEvent) -> Set<String>

struct ProjectTreeWalker {

    /// Default per-root depth budget (epic R9): directories more than
    /// `maxDepth` levels below a root are never visited — the deepest
    /// emitted event has `depth == maxDepth` (its entries are still listed;
    /// none are descended).
    static let defaultMaxDepth = 8

    /// Home-relative first-level ancestors macOS gates behind a TCC consent
    /// prompt. Protection of an ARBITRARY configured root is decided by
    /// canonical-path PREFIX under one of these (see `isProtectedRoot`),
    /// never by basename.
    static let tccProtectedAncestorNames: [String] = [
        "Documents", "Desktop", "Downloads",
    ]

    private let home: URL
    private let pathGuard: PathGuard
    private let provider: FileSystemIdentityProvider
    private let fileManager: FileManager

    /// - Parameters:
    ///   - home: home the TCC-protected ancestors resolve against
    ///     (injectable — tests use a fixture home).
    ///   - pathGuard: the CALLING SCANNER'S own guard, whose
    ///     `containerRoots` == its declared `trustedContainerRoots` (each
    ///     scanner constructs its own — epic D2).
    ///   - provider: identity provider shared with the guard and the sizer
    ///     (tests subclass to inject devices/mount points/probe failures).
    ///   - fileManager: directory enumeration source.
    init(
        home: URL,
        pathGuard: PathGuard,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider(),
        fileManager: FileManager = .default
    ) {
        self.home = home
        self.pathGuard = pathGuard
        self.provider = provider
        self.fileManager = fileManager
    }

    // MARK: - TCC-protected-root determination (R12)

    /// Is `root` gated behind a macOS TCC consent prompt? True iff the
    /// CANONICAL root path is equal to or under a canonical protected
    /// ancestor (`home/Documents`, `home/Desktop`, `home/Downloads`) —
    /// prefix by `pathComponents`, never string `hasPrefix`, never basename:
    /// `~/Documents/GitHub` is protected because `Documents` is; a directory
    /// merely NAMED `Documents` outside home is not; an alias spelling that
    /// resolves INTO `~/Documents` through a symlinked ancestor is protected
    /// as `~/Documents`.
    static func isProtectedRoot(
        _ root: URL, home: URL, provider: FileSystemIdentityProvider
    ) -> Bool {
        let rootComponents = provider.canonicalize(root).pathComponents
        for name in tccProtectedAncestorNames {
            let ancestor = provider
                .canonicalize(home.appendingPathComponent(name))
                .pathComponents
            if rootComponents.count >= ancestor.count,
               Array(rootComponents.prefix(ancestor.count)) == ancestor {
                return true
            }
        }
        return false
    }

    // MARK: - Walk

    /// Walk `roots` (each an INDEPENDENT walk with its own depth budget,
    /// caller order preserved), dispatching one event per visited directory
    /// to every consumer. Returns the per-root classified issues; discovered
    /// content lives in whatever the consumers accumulated.
    ///
    /// - Parameters:
    ///   - roots: declared dev-root spellings, carried verbatim as each
    ///     walk's `originRoot`. Every root must be among the guard's
    ///     configured container roots or admission refuses it.
    ///   - maxDepth: per-root depth budget (see `defaultMaxDepth`).
    ///   - includeProtectedRoots: when false (automatic/background scans),
    ///     TCC-protected roots are skipped entirely — deliberately silent,
    ///     a policy skip is not a scan problem (the as-built R9 doctrine).
    ///     User-initiated scans pass true.
    ///   - consumers: verdict-returning event receivers (see
    ///     `ProjectTreeConsumer`). All of them see every event of every
    ///     kept root — ONE walk, N consumers.
    func walk(
        roots: [URL],
        maxDepth: Int = ProjectTreeWalker.defaultMaxDepth,
        includeProtectedRoots: Bool = true,
        consumers: [ProjectTreeConsumer]
    ) -> [ScanIssue] {
        var issues: [ScanIssue] = []

        for root in roots {
            if Task.isCancelled { break }

            // TCC policy gate (R9/R12): a background rescan must never be
            // the thing that fires a macOS privacy prompt. Prefix-under-
            // protected-ancestor on the CANONICAL root — never basename.
            if !includeProtectedRoots,
               Self.isProtectedRoot(root, home: home, provider: provider) {
                continue
            }

            // ABSENT root: honest no-item omission — machines differ, and
            // the seeds routinely include roots that do not exist. No issue,
            // no events (epic registration-time story).
            let rootProbe = provider.probeKind(of: root)
            if rootProbe == .absent { continue }

            // Container admission BEFORE any traversal — the SCAN-TIME
            // read-only mode (fn-3.4 round 9): no snapshot, and this token
            // cannot delete. Refusal → classified issue, root never walked.
            do {
                _ = try pathGuard.admitSearchRoot(root)
            } catch {
                issues.append(ScanIssue(
                    url: root, kind: .containerRefused,
                    detail: error.localizedDescription
                ))
                continue
            }

            // lstat root gate: a symlink-LEAF root is NEVER traversed (its
            // real target may sit anywhere — but symlinked ANCESTORS already
            // resolved through the lstat, so `/var`-style alias roots pass).
            // A root we cannot even lstat is a classified, visible failure.
            switch rootProbe {
            case .kind(.directory):
                break
            case .failed(let code):
                issues.append(Self.issue(forFailedProbe: root, errno: code))
                continue
            case .kind, .absent:
                issues.append(ScanIssue(
                    url: root, kind: .symlinkRoot,
                    detail: "dev root is not a real directory"
                ))
                continue
            }

            // Boundary reference: children on a DIFFERENT device than the
            // root never descend. The root itself may be a mount point
            // (external-volume dev roots are legal).
            let rootDevice = provider.deviceID(of: root)

            visit(
                directory: root, depth: 0, originRoot: root,
                rootDevice: rootDevice, maxDepth: maxDepth,
                consumers: consumers, issues: &issues
            )
        }

        return issues
    }

    // MARK: - Per-directory visit (DFS pre-order)

    private func visit(
        directory: URL,
        depth: Int,
        originRoot: URL,
        rootDevice: UInt64?,
        maxDepth: Int,
        consumers: [ProjectTreeConsumer],
        issues: inout [ScanIssue]
    ) {
        if Task.isCancelled { return }

        // Enumerate + probe the immediate children inside an autoreleasepool
        // (long walks accumulate URL/metadata allocations). nil = this
        // directory produced no event: either the enumeration failed (issue
        // already appended — failure of the CURRENT enumerated directory is
        // never a silent skip, R12) or the walk was cancelled mid-probe
        // (prompt partial return; a half-built event is never emitted).
        let enumerated: [ProjectTreeEvent.Entry]? = autoreleasepool {
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [],
                    // Deliberately NOT .skipsHiddenFiles /
                    // .skipsPackageDescendants (R2).
                    options: []
                )
            } catch {
                issues.append(Self.issue(
                    from: DirectorySizer.classifyDenial(error, at: directory)
                ))
                return nil
            }

            // Byte-wise name sort: deterministic entries and descent order,
            // never filesystem order.
            let sorted = children.sorted {
                $0.lastPathComponent.utf8
                    .lexicographicallyPrecedes($1.lastPathComponent.utf8)
            }

            var entries: [ProjectTreeEvent.Entry] = []
            entries.reserveCapacity(sorted.count)
            for child in sorted {
                if Task.isCancelled { return nil }
                switch provider.probeKind(of: child) {
                case .absent:
                    // Vanished between enumeration and probe — a benign
                    // mid-walk deletion race, quiet by contract.
                    continue
                case .failed(let code):
                    // Classified by errno (EPERM → TCC, EACCES →
                    // permission) — never a silent zero (R12). No kind was
                    // proven, so the child is not listed.
                    issues.append(Self.issue(forFailedProbe: child, errno: code))
                case .kind(let kind):
                    entries.append(ProjectTreeEvent.Entry(
                        name: child.lastPathComponent, kind: kind
                    ))
                }
            }
            return entries
        }
        guard let entries = enumerated else { return }

        let event = ProjectTreeEvent(
            directory: directory, depth: depth,
            originRoot: originRoot, entries: entries
        )

        // EVERY consumer sees EVERY event (no early exit — a consumer's
        // verdict must not depend on another's). A child is pruned only on
        // unanimity: the intersection of all prune sets. Zero consumers =
        // nothing pruned.
        var unanimouslyPruned: Set<String>?
        for consumer in consumers {
            let pruneSet = consumer(event)
            unanimouslyPruned =
                unanimouslyPruned.map { $0.intersection(pruneSet) } ?? pruneSet
        }
        let pruned = unanimouslyPruned ?? []

        for entry in entries {
            if Task.isCancelled { return }
            // Only real directories descend — symlink children are listed
            // but NEVER followed (R11); files and specials have no interior.
            guard entry.kind == .directory else { continue }
            // Walker-level hard prune: `.git` is SEEN in entries (fn-5
            // classifies it) but its children are never visited, regardless
            // of consumer verdicts.
            if entry.name == ".git" { continue }
            if pruned.contains(entry.name) { continue }
            let childDepth = depth + 1
            guard childDepth <= maxDepth else { continue }

            let child = directory.appendingPathComponent(entry.name)

            // lstat gate on EVERY descent — consumers ran between the
            // entries probe and this one, and the filesystem is live.
            switch provider.probeKind(of: child) {
            case .kind(.directory):
                break
            case .absent:
                // Vanished between enumeration and descent — the benign
                // race arm of the absence boundary. Quiet.
                continue
            case .failed(let code):
                issues.append(Self.issue(forFailedProbe: child, errno: code))
                continue
            case .kind:
                // Became a non-directory since the entries probe; never
                // descended (the entries already reported honestly).
                continue
            }

            // Mount boundaries are never crossed — BOTH signals, matching
            // the sizer: device change against the WALK ROOT, and the
            // statfs mount-root check that catches same-st_dev firmlink
            // mounts.
            //
            // CANONICAL INPUT for the statfs arm (PR #457 review r4).
            // `isMountPoint` compares `f_mntonname` — always canonical —
            // against the path it is handed, and requires canonical input
            // (`FileSystemIdentityProvider.swift:143`). This walk canonicalizes
            // ONLY to compare a root against the TCC-protected ancestors
            // (`isProtectedRoot`) and then descends from the ORIGINAL root
            // spelling, deliberately: `originRoot` and every event carry the
            // DECLARED spelling verbatim, which is what the guard, the
            // snapshot, and the deletion target are all keyed on. So every
            // child inherits the root's aliasing — a dev root declared as
            // `/tmp/work`, or any home reached through a symlink — and this
            // arm silently answered `false` for a real mount. It is not
            // defense-in-depth behind the device arm: on a firmlink-shaped
            // mount that SHARES the root's `st_dev` the device arm cannot
            // fire at all, which is the very case this arm exists for, so
            // both go silent together and the walk descends into the mounted
            // volume.
            //
            // The canonical value is an ARGUMENT and is discarded — `child`
            // is what descends, what consumers see, and what items derive
            // from. Safe here because the lstat gate directly above already
            // proved `child` a REAL directory (`canonicalize` resolves the
            // leaf too, so a symlink child must never reach this call — and
            // never does), and a real directory's own name is its canonical
            // name.
            let childDevice = provider.deviceID(of: child)
            if (rootDevice != nil && childDevice != nil
                    && childDevice != rootDevice)
                || provider.isMountPoint(provider.canonicalize(child)) {
                continue
            }

            visit(
                directory: child, depth: childDepth, originRoot: originRoot,
                rootDevice: rootDevice, maxDepth: maxDepth,
                consumers: consumers, issues: &issues
            )
        }
    }

    // MARK: - Denial classification (frozen taxonomy, R12)

    /// Map a sizer denial onto the FROZEN `ScanIssue.Kind` taxonomy —
    /// `.malformedOutcome` is never authored here (reserved to the
    /// validator).
    private static func issue(from denial: SizeDenial) -> ScanIssue {
        let kind: ScanIssue.Kind
        switch denial.kind {
        case .tcc: kind = .tccDenied
        case .permission: kind = .permissionDenied
        case .metadata, .other: kind = .unreadable
        }
        return ScanIssue(url: denial.url, kind: kind, detail: denial.detail)
    }

    /// Classify a failed lstat probe by errno (EPERM → TCC, EACCES → BSD
    /// permissions) — same taxonomy as the sizer's denial classification.
    private static func issue(
        forFailedProbe url: URL, errno code: Int32
    ) -> ScanIssue {
        issue(from: DirectorySizer.denial(forFailedProbe: url, errno: code))
    }
}
