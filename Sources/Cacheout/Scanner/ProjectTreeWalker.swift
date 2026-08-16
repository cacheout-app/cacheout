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
/// - **BELOW A ROOT, NOTHING TAKES A PATH (PR #457 review r5).** Each root is
///   opened ONCE with `O_NOFOLLOW | O_DIRECTORY`; from there children are
///   enumerated through the held descriptor (`openat(fd, ".")` + `fdopendir`),
///   vetted with `fstatat`, and descended with `openat` by single-component
///   basename. `FileManager.contentsOfDirectory` is gone: Foundation has NO
///   no-follow option, and it returns fully RESOLVED child URLs which every
///   downstream per-child check then re-resolved by path — so replacing a
///   directory the walk had already passed through with a symlink redirected
///   the walk, and neither `O_NOFOLLOW` (last component only) nor an inode
///   re-proof (whose vetted value was itself read through the swapped
///   ancestor) could see it. A held descriptor is inode-pinned and cannot be
///   redirected. Live descriptors are exactly the current path's, so the
///   depth budget bounds them at `maxDepth + 1` anchors plus two transients.
///   RESIDUAL: the root open still resolves the root's own ancestors.
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

    /// - Parameters:
    ///   - home: home the TCC-protected ancestors resolve against
    ///     (injectable — tests use a fixture home).
    ///   - pathGuard: the CALLING SCANNER'S own guard, whose
    ///     `containerRoots` == its declared `trustedContainerRoots` (each
    ///     scanner constructs its own — epic D2).
    ///   - provider: identity provider shared with the guard and the sizer
    ///     (tests subclass to inject devices/mount points/probe failures) —
    ///     and, since PR #457 review r5, the source of every descriptor-
    ///     relative primitive this walk uses. There is no `FileManager`
    ///     parameter any more: Foundation offers no no-follow directory read,
    ///     so enumeration is `openat`/`fdopendir` through the provider.
    init(
        home: URL,
        pathGuard: PathGuard,
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) {
        self.home = home
        self.pathGuard = pathGuard
        self.provider = provider
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
    ///   - didAnchorRoot: handed the ADMITTED, VETTED, still-OPEN anchor of
    ///     every root this walk actually traverses, at the instant it is
    ///     opened. A caller that RETAINS the `SecureDirectory` keeps the walk
    ///     root inode-pinned past the walk, which is the only way a POST-WALK
    ///     pass can re-establish CONTAINMENT for something the walk found:
    ///     re-opening the root by path afterwards would re-resolve the root's
    ///     own name and could anchor a foreign directory (`BuildArtifactsScanner`
    ///     phase 3 does exactly this re-descent). Default nil — nothing is
    ///     retained, the anchor dies with its recursion, and the walk's
    ///     descriptor profile is unchanged. RETENTION COST, on the caller:
    ///     one descriptor per admitted root, live until the caller drops it.
    func walk(
        roots: [URL],
        maxDepth: Int = ProjectTreeWalker.defaultMaxDepth,
        includeProtectedRoots: Bool = true,
        consumers: [ProjectTreeConsumer],
        didAnchorRoot: ((URL, SecureDirectory) -> Void)? = nil
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

            // THE ROOT OPEN — the ONE path-based open of this walk, and the
            // gate that ENFORCES the lstat decision above. The gate and the
            // open are two separate resolutions of the same path, so a root
            // swapped for a symlink between them passes the gate; only
            // `O_NOFOLLOW | O_DIRECTORY` on the open refuses it.
            //
            // Below this point NOTHING is reached by path: children are
            // enumerated through the held descriptor, probed with `fstatat`,
            // and descended with `openat` by single-component basename. That
            // is what closes the ancestor-swap race that
            // `FileManager.contentsOfDirectory` could not — it has no
            // no-follow option at all, and it hands back fully RESOLVED child
            // URLs, so every subsequent per-child check re-resolved a path an
            // attacker could have re-pointed in between.
            let rootFD = provider.openDirectoryNoFollow(at: root)
            guard rootFD >= 0 else {
                // Captured BEFORE anything else can clobber `errno`.
                issues.append(Self.issue(forFailedOpen: root, errno: errno))
                continue
            }
            guard let anchor = SecureDirectory(fd: rootFD, provider: provider)
            else {
                issues.append(Self.issue(forFailedOpen: root, errno: EIO))
                continue
            }

            // The vetted anchor, offered to the caller BEFORE the traversal
            // that consumes it. A retaining caller now holds the same
            // inode-pinned handle this walk descends from, so anything it
            // discovers can be re-reached later by CONTAINMENT rather than by
            // re-resolving a path an attacker may have re-pointed.
            didAnchorRoot?(root, anchor)

            // Boundary reference: children on a DIFFERENT device than the
            // root never descend. The root itself may be a mount point
            // (external-volume dev roots are legal).
            let rootDevice = provider.deviceID(of: root)

            visit(
                anchor: anchor, directory: root, depth: 0, originRoot: root,
                rootDevice: rootDevice, rootMount: anchor.mount,
                maxDepth: maxDepth, consumers: consumers, issues: &issues
            )
        }

        return issues
    }

    // MARK: - Per-directory visit (DFS pre-order)

    /// - Parameters:
    ///   - anchor: the OPEN, vetted descriptor for `directory`. Every child is
    ///     discovered and opened relative to it, by single-component basename
    ///     — never by path.
    ///   - directory: the UNRESOLVED spelling of the same directory. Display
    ///     and provenance ONLY (it is what `originRoot`-derived event URLs and
    ///     the deletion target are keyed on); it is never opened or resolved.
    ///
    /// DESCRIPTOR BOUND: this is a plain recursion, so the live descriptors
    /// are exactly the CURRENT PATH's — never one per pending sibling. With
    /// the per-root depth budget (`defaultMaxDepth` = 8) the chain is at most
    /// `maxDepth + 1` anchors plus two transients (the enumeration handle,
    /// and a child descriptor between its open and its recursion): 11 for the
    /// default budget. The Swift call stack enforces the frame discipline for
    /// free, which is why this walk needs no descriptor window and no `..`
    /// re-anchoring.
    private func visit(
        anchor: SecureDirectory,
        directory: URL,
        depth: Int,
        originRoot: URL,
        rootDevice: UInt64?,
        rootMount: FileSystemIdentityProvider.MountIdentity,
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
        //
        // `vetted` carries each listed child's `fstatat` identity forward to
        // its descent, where the OPENED descriptor must reproduce it.
        var vetted: [String: FileSystemIdentityProvider.Identity] = [:]
        let enumerated: [ProjectTreeEvent.Entry]? = autoreleasepool {
            guard let names = Self.childNames(
                inDirectory: anchor.fd, provider: provider
            ) else {
                issues.append(Self.issue(
                    forFailedOpen: directory, errno: errno
                ))
                return nil
            }

            // Byte-wise name sort: deterministic entries and descent order,
            // never filesystem order.
            let sorted = names
                .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }

            var entries: [ProjectTreeEvent.Entry] = []
            entries.reserveCapacity(sorted.count)
            for name in sorted {
                if Task.isCancelled { return nil }
                let child = directory.appendingPathComponent(name)
                switch provider.probeKind(
                    inDirectory: anchor.fd, named: name, logical: child
                ) {
                case .absent:
                    // Vanished between enumeration and probe — a benign
                    // mid-walk deletion race, quiet by contract.
                    continue
                case .failed(let code):
                    // Classified by errno (EPERM → TCC, EACCES →
                    // permission) — never a silent zero (R12). No kind was
                    // proven, so the child is not listed.
                    issues.append(Self.issue(forFailedProbe: child, errno: code))
                case .kind(let kind, let identity, _):
                    vetted[name] = identity
                    entries.append(ProjectTreeEvent.Entry(
                        name: name, kind: kind
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

            // THE DESCENT GATE, descriptor-relative. Consumers ran between
            // the entries probe and this point and the filesystem is live, so
            // the child is opened — not re-stat'd — from the SAME held parent
            // descriptor, with `O_NOFOLLOW | O_DIRECTORY`.
            let childFD = provider.openChildDirectory(
                inDirectory: anchor.fd, named: entry.name, logical: child
            )
            guard childFD >= 0 else {
                let code = errno
                // ENOENT is the benign race arm of the absence boundary:
                // the entry vanished between enumeration and descent. Quiet.
                if code == ENOENT { continue }
                // ENOTDIR means the name is no longer a directory — swapped
                // for a symlink, swapped for a file, or raced. All three are
                // one event with one remedy, and none of them may be a
                // SILENT skip: this walk already EMITTED an event listing
                // this child as a directory, so a consumer has seen it.
                issues.append(Self.issue(forFailedOpen: child, errno: code))
                continue
            }
            guard let childAnchor = SecureDirectory(
                fd: childFD, provider: provider
            ) else {
                issues.append(Self.issue(forFailedOpen: child, errno: EIO))
                continue
            }
            // The corroborator: what we OPENED must BE what we LISTED. This
            // is the one swap `O_NOFOLLOW` cannot see — a directory re-bound
            // to a DIFFERENT real directory, which passes every no-follow
            // check there is.
            guard let expected = vetted[entry.name],
                  childAnchor.identity == expected
            else {
                issues.append(ScanIssue(
                    url: child, kind: .unreadable,
                    detail: "directory changed identity between listing and "
                        + "descent — not traversed"
                ))
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
            // …and, since PR #457 review r5, the arm that actually carries
            // the check: `f_fsid` of the CHILD'S OWN DESCRIPTOR against the
            // root's. `st_dev` is identical for every path on an APFS volume
            // group (measured: `/` and `/System/Volumes/Data` both report
            // 16777230), so the device arm is blind to exactly the firmlink
            // split it was meant to catch, and the path arms are blind to an
            // aliased spelling. The descriptor arm has neither blind spot.
            // The two PATH arms are RETAINED: they are the seam hermetic
            // tests inject synthetic devices and mount points through, and
            // they can only ever push the answer toward NOT descending.
            if childAnchor.mount.fsidMajor != rootMount.fsidMajor
                || childAnchor.mount.fsidMinor != rootMount.fsidMinor
                || childAnchor.mount.device != rootMount.device {
                continue
            }
            let childDevice = provider.deviceID(of: child)
            if (rootDevice != nil && childDevice != nil
                    && childDevice != rootDevice)
                || provider.isMountPoint(provider.canonicalize(child)) {
                continue
            }

            visit(
                anchor: childAnchor, directory: child, depth: childDepth,
                originRoot: originRoot, rootDevice: rootDevice,
                rootMount: rootMount, maxDepth: maxDepth,
                consumers: consumers, issues: &issues
            )
        }
    }

    // MARK: - Descriptor-relative enumeration

    /// Every immediate child basename of an OPEN directory.
    ///
    /// `FileManager.contentsOfDirectory` cannot be used here: Foundation
    /// offers NO no-follow option, and it returns fully RESOLVED child URLs,
    /// which every downstream per-child check then re-resolved by path — the
    /// exact re-resolution an attacker swapping an ancestor exploits. The
    /// enumeration handle comes from `openat(fd, ".")`, never `dup` (which
    /// clears `FD_CLOEXEC` and shares the file offset) and never a path.
    ///
    /// DELIBERATELY UNBOUNDED per directory, matching the previous behaviour:
    /// adding an entry budget to this walker is a separate decision, not a
    /// rider on a security fix. `nil` on failure with `errno` set; `.`/`..`
    /// are skipped and hidden entries are included (R2 bans name-based
    /// skipping). An undecodable basename ABORTS the directory rather than
    /// substituting U+FFFD, which would name a different path than the entry.
    private static func childNames(
        inDirectory fd: Int32, provider: FileSystemIdentityProvider
    ) -> [String]? {
        let enumerationFD = provider.openSelfForEnumeration(fd)
        guard enumerationFD >= 0 else { return nil }
        guard let handle = fdopendir(enumerationFD) else {
            let code = errno
            close(enumerationFD)
            errno = code
            return nil
        }
        defer { closedir(handle) }
        var names: [String] = []
        while true {
            // `readdir` returns nil for BOTH end-of-stream and error; errno
            // is the only discriminator, so it is cleared before each call.
            errno = 0
            guard let entry = readdir(handle) else {
                if errno != 0 { return nil }
                break
            }
            let decoded = withUnsafeBytes(of: entry.pointee.d_name) {
                raw -> String? in
                guard let base = raw.bindMemory(to: CChar.self).baseAddress
                else { return nil }
                return ValuablesDetector.decodedBasename(fromCString: base)
            }
            guard let name = decoded, !name.isEmpty else {
                errno = EILSEQ
                return nil
            }
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        return names
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

    /// Classify a failed directory OPEN by errno, on the SAME frozen
    /// taxonomy: EPERM → `.tccDenied`, EACCES → `.permissionDenied`,
    /// everything else (notably ENOTDIR — a name that is no longer a
    /// directory) → `.unreadable`.
    private static func issue(
        forFailedOpen url: URL, errno code: Int32
    ) -> ScanIssue {
        let kind: ScanIssue.Kind
        switch code {
        case EPERM: kind = .tccDenied
        case EACCES: kind = .permissionDenied
        default: kind = .unreadable
        }
        return ScanIssue(
            url: url, kind: kind,
            detail: "directory open failed: "
                + String(cString: strerror(code))
        )
    }
}
