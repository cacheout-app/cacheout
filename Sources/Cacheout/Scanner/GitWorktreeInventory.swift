/// # GitWorktreeInventory — porcelain model, gitdir resolver, admin mapper
/// (fn-5.1, R7 / R9)
///
/// Three pure-ish pieces every later fn-5 task consumes verbatim. Keeping
/// them here — beside each other and away from the subprocess seam — is what
/// lets the parser be tested on BYTES with no git at all.
///
/// ## 1. The `--porcelain -z` grammar
///
/// `git worktree list --porcelain -z` emits NUL-TERMINATED attribute lines
/// with a second NUL closing each record, and NO quoting or escaping
/// anywhere. The non-`-z` form is the trap this exists to avoid (D8): there
/// the worktree PATH is raw and unquoted while a lock reason IS quoted and
/// escaped, so a path containing a newline silently splits into two bogus
/// records — and a mis-split path is a wrong deletion target. Line splitting
/// is therefore FORBIDDEN in this file. `-z` needs git 2.36; the deployment
/// floor is macOS 14 / Apple Git 2.39.
///
/// Grammar per record: `worktree <abs-path>`, `HEAD <sha>`,
/// `branch <ref>` XOR `detached`, `bare` (first record only),
/// `locked[ <reason>]`, `prunable[ <reason>]`. The FIRST record is the main
/// worktree BY GIT CONTRACT, so `isMain` comes from position — never from a
/// heuristic. Unknown attribute lines are ignored forward-compatibly.
///
/// `prunable` IS the orphaned-admin oracle (D10): fn-5.5 runs the listing
/// with `-c gc.worktreePruneExpire=now` and consumes `isPrunable` /
/// `prunableReason` from here. No dry-run text parsing exists anywhere.
///
/// ## 2. Split of authority (epic round 4 / F4, round 7)
///
/// - The INVENTORY owns `parentRepoWorkingDir` — the porcelain FIRST
///   record's path (or, for a bare main, the bare repository directory,
///   which is the `-C` target git accepts).
/// - The RESOLVER owns `parentGitDir` — reached from the linked worktree's
///   `.git` FILE → its admin directory → that directory's `commondir`.
///
/// Neither derives the other. Under `git init --separate-git-dir` the common
/// git dir is EXTERNAL and its parent is NOT the working tree, so
/// path-deriving a `-C` target from `parentGitDir` yields a wrong target and
/// a wrong containment decision. Symmetrically, `<wd>/.git/worktrees` is not
/// the admin container of a bare parent — downstream derives the container
/// ONLY as `<parentGitDir>/worktrees` (`WorktreeMembership.parentAdminContainer`,
/// D13).
///
/// The two are CROSS-VALIDATED, in two branches because a bare repo has no
/// `<bare>/.git` and one rule cannot cover both:
/// - NON-BARE first record → the first-record path's own `.git` (file or
///   directory) must resolve to the SAME common git dir.
/// - BARE first record (the porcelain `bare` attribute) → canonicalize the
///   first-record path ITSELF and require equality with the resolved common
///   git dir.
/// Either branch's mismatch fails the membership CLOSED — callers record an
/// issue, never guess.
///
/// EMPIRICAL CAVEAT (git 2.50.1, verified on a hermetic fixture): git
/// derives the main record's path by stripping a `/.git` suffix from the
/// common git dir, so for `git init --separate-git-dir=<external> <wd>` the
/// first record reports `<external>`, not `<wd>`. The cross-validation above
/// then finds no `<external>/.git` and the membership fails CLOSED. That is
/// the safe direction and is exactly why the check exists: a missed stale
/// worktree wastes disk, a mis-attributed one loses work.
///
/// ## 3. Bidirectional gitdir resolution
///
/// A linked worktree's `.git` is a regular FILE holding
/// `gitdir: <path>/.git/worktrees/<id>` (absolute or relative to the
/// worktree). The parent repo is reached through that admin directory's
/// `commondir` (usually `../..`, relative) rather than by stripping path
/// components — that survives bare mains and `extensions.worktreeConfig`
/// layouts.
///
/// Before attributing anything, the BACK-LINK is enforced (mirroring git's
/// own `validate_worktree`): the admin directory's `gitdir` file must point
/// BACK at the worktree's `.git` file. A forged, stale, or one-way pointer
/// resolves to `nil`. This is the anti-mis-attribution mechanism for
/// nested-repo cases (R7).
///
/// ## 4. The SHARED oracle→admin mapper (epic round 10)
///
/// ONE implementation, TWO call sites: fn-5.5 (scan-time detection and
/// disclosure) and fn-5.4 (delete-time recompute plus the final
/// pre-subprocess check) both call `GitWorktreeAdminMapper`. A second
/// mapping implementation is the thing this file exists to prevent — a
/// repo-wide `git worktree prune` removes every prunable admin directory, so
/// detection and execution must agree byte for byte about which ones those
/// are.

import Foundation

// MARK: - Porcelain model

/// One `git worktree list --porcelain -z` record.
struct GitWorktreeEntry: Equatable, Sendable {
    /// The `worktree` attribute, verbatim as git spelled it.
    let path: URL
    let headSHA: String?
    let branchRef: String?
    let isDetached: Bool
    /// The `bare` attribute — git emits it on the first record only.
    let isBare: Bool
    let isLocked: Bool
    /// `nil` when git emitted a bare `locked` with no reason.
    let lockReason: String?
    /// The orphaned-admin ORACLE signal (D10).
    let isPrunable: Bool
    /// `nil` when git emitted a bare `prunable` with no reason.
    let prunableReason: String?
    /// Position-derived: the first record IS the main worktree by git
    /// contract. Never inferred from paths or attributes.
    let isMain: Bool
}

/// A parsed listing. The type exists so ONE place owns the
/// `parentRepoWorkingDir` authority (see the file header's split of
/// authority) instead of every call site re-deciding what "first record"
/// means.
struct GitWorktreeInventory: Equatable, Sendable {
    let entries: [GitWorktreeEntry]

    /// The main worktree record — position 0, by git contract.
    var mainRecord: GitWorktreeEntry? { entries.first }

    /// THE AUTHORITY for `parentRepoWorkingDir`: the main record's path.
    /// For a bare main this is the bare repository directory itself, which
    /// is a `-C` target git accepts (there is no working tree). NEVER
    /// derived from `parentGitDir`.
    var parentRepoWorkingDir: URL? { mainRecord?.path }

    /// Parse raw `--porcelain -z` bytes. `nil` means the stream could not be
    /// read faithfully — non-UTF-8 bytes, a record with no `worktree`
    /// attribute, or TRUNCATION (an unterminated final field or a record
    /// missing its closing NUL) — fail CLOSED rather than hand a guessed
    /// path downstream. Unknown attribute lines are ignored, never fatal.
    static func parse(_ data: Data) -> GitWorktreeInventory? {
        guard let entries = GitWorktreePorcelainParser.parse(data) else { return nil }
        return GitWorktreeInventory(entries: entries)
    }
}

/// The pure `-z` parser. Split out so it can be exercised on fixture bytes
/// with no git, no filesystem, and no runner.
enum GitWorktreePorcelainParser {

    /// Attribute keys with a meaning; anything else is ignored.
    private static let worktreeKey = "worktree"

    static func parse(_ data: Data) -> [GitWorktreeEntry]? {
        // NUL-DELIMITED, never line-split (D8). A record ends at an EMPTY
        // field, i.e. at the second consecutive NUL.
        var records: [[String]] = []
        var current: [String] = []

        var start = data.startIndex
        var index = data.startIndex
        func flushField(_ range: Range<Data.Index>) -> Bool {
            guard let text = String(data: data[range], encoding: .utf8) else {
                return false
            }
            if text.isEmpty {
                if !current.isEmpty {
                    records.append(current)
                    current = []
                }
            } else {
                current.append(text)
            }
            return true
        }
        while index < data.endIndex {
            if data[index] == 0 {
                guard flushField(start..<index) else { return nil }
                index = data.index(after: index)
                start = index
            } else {
                index = data.index(after: index)
            }
        }
        // TRUNCATION IS MALFORMED, not "best effort". Every field is
        // NUL-TERMINATED and every record is closed by an empty field, so a
        // trailing unterminated field or a record that never received its
        // terminator means the stream was not read faithfully — and half a
        // path is exactly the wrong deletion target the `-z` grammar exists
        // to prevent (D8). Fail CLOSED for the whole listing.
        guard start == data.endIndex, current.isEmpty else { return nil }

        var entries: [GitWorktreeEntry] = []
        entries.reserveCapacity(records.count)
        for (position, attributes) in records.enumerated() {
            guard let entry = entry(from: attributes, isMain: position == 0) else {
                return nil
            }
            entries.append(entry)
        }
        return entries
    }

    private static func entry(from attributes: [String], isMain: Bool) -> GitWorktreeEntry? {
        var path: String?
        var headSHA: String?
        var branchRef: String?
        var isDetached = false
        var isBare = false
        var isLocked = false
        var lockReason: String?
        var isPrunable = false
        var prunableReason: String?

        for attribute in attributes {
            let (key, value) = split(attribute)
            switch key {
            case worktreeKey:
                // The FIRST `worktree` line wins; a repeated one would be a
                // malformed record, and overwriting it could retarget a
                // deletion.
                if path == nil { path = value }
            case "HEAD":
                headSHA = value.isEmpty ? nil : value
            case "branch":
                branchRef = value.isEmpty ? nil : value
            case "detached":
                isDetached = true
            case "bare":
                isBare = true
            case "locked":
                isLocked = true
                lockReason = value.isEmpty ? nil : value
            case "prunable":
                isPrunable = true
                prunableReason = value.isEmpty ? nil : value
            default:
                continue // Forward-compatible: unknown attributes are ignored.
            }
        }

        guard let path, !path.isEmpty else { return nil }
        return GitWorktreeEntry(
            path: URL(fileURLWithPath: path),
            headSHA: headSHA,
            branchRef: branchRef,
            isDetached: isDetached,
            isBare: isBare,
            isLocked: isLocked,
            lockReason: lockReason,
            isPrunable: isPrunable,
            prunableReason: prunableReason,
            isMain: isMain
        )
    }

    /// Split an attribute line at its FIRST space: everything after it is
    /// the value VERBATIM (paths and lock reasons alike are unescaped in
    /// `-z` output, so nothing is unquoted or trimmed here).
    private static func split(_ attribute: String) -> (key: String, value: String) {
        guard let space = attribute.firstIndex(of: " ") else {
            return (attribute, "")
        }
        return (
            String(attribute[attribute.startIndex..<space]),
            String(attribute[attribute.index(after: space)...])
        )
    }
}

// MARK: - Membership

/// A linked worktree attributed to its parent repository, AFTER the
/// bidirectional back-link check and the first-record cross-validation.
///
/// The two path authorities are deliberately separate (see the file header):
/// `parentRepoWorkingDir` comes from the porcelain inventory's first record,
/// `parentGitDir` from the resolver. Neither is derived from the other, and
/// the admin container is derived ONLY here.
struct WorktreeMembership: Equatable, Sendable {
    /// The linked worktree, verbatim as the caller spelled it.
    let worktreePath: URL
    /// RESOLVER-owned: the repository's COMMON git directory. The single
    /// authority for the admin container.
    let parentGitDir: URL
    /// INVENTORY-owned: the porcelain first record's path. The `-C` target.
    let parentRepoWorkingDir: URL

    /// The ONE derivation of the admin container (D13). Downstream must use
    /// this and must NEVER reconstruct `<parentRepoWorkingDir>/.git/worktrees`
    /// — a bare parent's git dir does not live at `<wd>/.git`, and a linked
    /// worktree of a bare main is not itself `bare`, so no gate excludes the
    /// shape.
    var parentAdminContainer: URL {
        parentGitDir.appendingPathComponent("worktrees")
    }
}

/// Resolves a linked worktree's `.git` FILE to its parent repository.
///
/// Net-new code: `FileSystemIdentityProvider.canonicalize` is plain
/// `realpath(3)` and performs NO gitdir parsing. The provider is injected
/// only for the identity/canonicalization primitives (and so tests can
/// subclass it).
struct GitWorktreeGitdirResolver {

    /// The `gitdir:` prefix in a worktree's `.git` file.
    static let gitdirPrefix = "gitdir:"
    /// Every admin directory lives directly under this component.
    static let adminContainerName = "worktrees"

    private let identity: FileSystemIdentityProvider

    init(identity: FileSystemIdentityProvider = FileSystemIdentityProvider()) {
        self.identity = identity
    }

    /// The admin directory `<worktree>/.git` points at, AFTER the
    /// bidirectional back-link check. `nil` = fail closed.
    func adminDirectory(forWorktreeAt worktreePath: URL) -> URL? {
        let dotGit = worktreePath.appendingPathComponent(".git")
        // A LINKED worktree's `.git` is a regular FILE. A directory is the
        // main worktree (not a linked one); a symlink is never followed.
        guard identity.probeKind(of: dotGit) == .kind(.regularFile),
              let pointer = pointerPath(inFileAt: dotGit, relativeTo: worktreePath)
        else { return nil }

        let adminDirectory = identity.canonicalize(pointer)
        guard identity.probeKind(of: adminDirectory) == .kind(.directory),
              adminDirectory.deletingLastPathComponent().lastPathComponent
                == Self.adminContainerName
        else { return nil }

        // BACK-LINK: the admin directory must point back at THIS worktree's
        // `.git` file. One-way, stale, and forged pointers all stop here.
        let backlinkFile = adminDirectory.appendingPathComponent("gitdir")
        guard identity.probeKind(of: backlinkFile) == .kind(.regularFile),
              let backlinkTarget = pathContents(of: backlinkFile, relativeTo: adminDirectory),
              identity.sameLocation(backlinkTarget, dotGit)
        else { return nil }

        return adminDirectory
    }

    /// The repository's COMMON git directory, via the admin directory's
    /// `commondir` file (usually the relative `../..`). Resolved rather than
    /// stripped so bare mains and `extensions.worktreeConfig` layouts work.
    func commonGitDirectory(forAdminDirectory adminDirectory: URL) -> URL? {
        let commonDirFile = adminDirectory.appendingPathComponent("commondir")
        guard identity.probeKind(of: commonDirFile) == .kind(.regularFile),
              let target = pathContents(of: commonDirFile, relativeTo: adminDirectory)
        else { return nil }
        let resolved = identity.canonicalize(target)
        guard identity.probeKind(of: resolved) == .kind(.directory) else { return nil }
        return resolved
    }

    /// Full attribution of `worktreePath` against a porcelain inventory.
    /// `nil` whenever ANY step fails — the back-link, the `commondir`, the
    /// admin-container shape, or either cross-validation branch.
    func membership(
        forWorktreeAt worktreePath: URL, in inventory: GitWorktreeInventory
    ) -> WorktreeMembership? {
        guard let mainRecord = inventory.mainRecord,
              let adminDirectory = adminDirectory(forWorktreeAt: worktreePath),
              let parentGitDir = commonGitDirectory(forAdminDirectory: adminDirectory)
        else { return nil }

        // The admin directory must sit directly inside THIS common git
        // dir's container — the one derivation downstream is allowed to use.
        let container = parentGitDir.appendingPathComponent(Self.adminContainerName)
        guard identity.sameLocation(adminDirectory.deletingLastPathComponent(), container)
        else { return nil }

        guard crossValidate(mainRecord: mainRecord, against: parentGitDir) else { return nil }

        return WorktreeMembership(
            worktreePath: worktreePath,
            parentGitDir: parentGitDir,
            parentRepoWorkingDir: mainRecord.path
        )
    }

    /// The TWO cross-validation branches (epic round 7). A bare repo has no
    /// `<bare>/.git`, so one rule cannot cover both shapes.
    func crossValidate(mainRecord: GitWorktreeEntry, against parentGitDir: URL) -> Bool {
        if mainRecord.isBare {
            // BARE branch: the first-record path IS the git directory.
            return identity.sameLocation(mainRecord.path, parentGitDir)
        }
        // NON-BARE branch: the first record's own `.git` must resolve to the
        // same common git dir. A directory is the git dir itself; a file
        // points at it (the `--separate-git-dir` shape). A symlink is never
        // followed — fail closed.
        let dotGit = mainRecord.path.appendingPathComponent(".git")
        switch identity.probeKind(of: dotGit) {
        case .kind(.directory):
            return identity.sameLocation(dotGit, parentGitDir)
        case .kind(.regularFile):
            guard let pointer = pointerPath(inFileAt: dotGit, relativeTo: mainRecord.path)
            else { return false }
            return identity.sameLocation(pointer, parentGitDir)
        default:
            return false
        }
    }

    // MARK: Pointer files

    /// Read a `gitdir: <path>` pointer file. Relative targets resolve
    /// against `base`.
    private func pointerPath(inFileAt url: URL, relativeTo base: URL) -> URL? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.gitdirPrefix) else { return nil }
        let target = String(trimmed.dropFirst(Self.gitdirPrefix.count))
            .trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        return resolve(target, relativeTo: base)
    }

    /// Read a bare path file (`gitdir`, `commondir`). Relative targets
    /// resolve against `base`.
    private func pathContents(of url: URL, relativeTo base: URL) -> URL? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return resolve(trimmed, relativeTo: base)
    }

    private func resolve(_ path: String, relativeTo base: URL) -> URL {
        path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : base.appendingPathComponent(path)
    }
}

// MARK: - Shared oracle → admin-directory mapper (epic round 10)

/// Whether the prunable set could be mapped COMPLETELY onto admin
/// directories. There is no partial answer on purpose: `git worktree prune`
/// is repo-wide, so a knowingly-incomplete disclosure would let the prune
/// remove something nobody was told about (D14).
enum GitAdminMappingVerdict: Equatable, Sendable {
    /// Every prunable record mapped, and every entry in the container
    /// cleared the traversal gates. Sorted and de-duplicated for
    /// determinism.
    case complete(adminDirectories: [URL])
    /// Something could not be mapped, or an entry failed a gate. The reason
    /// NAMES the offending entry or record.
    case incomplete(reason: String)
}

/// The ONE oracle→admin-directory mapping in the epic (round 10 / F4).
///
/// fn-5.5 uses it to decide whether a repo's prune item may be disclosed at
/// all; fn-5.4 uses it to recompute the set at delete time and again
/// immediately before the prune subprocess. Two implementations would let
/// detection and execution disagree about a repo-wide side effect.
///
/// The admin-ENTRY traversal gates run BEFORE any back-link is read (round
/// 10 / F3), over EVERY entry of the carried container — not only the ones
/// that happen to map. A repo-wide prune traverses the whole container, so a
/// single hostile entry makes the whole disclosure unsafe.
struct GitWorktreeAdminMapper {

    private let identity: FileSystemIdentityProvider
    private let fileManager: FileManager

    init(
        identity: FileSystemIdentityProvider = FileSystemIdentityProvider(),
        fileManager: FileManager = .default
    ) {
        self.identity = identity
        self.fileManager = fileManager
    }

    /// Map the inventory's prunable records onto admin directories inside
    /// the RESOLVER-CARRIED container.
    ///
    /// LOCKED prunable records are excluded WITHOUT making the verdict
    /// incomplete: git's prune skips locked admin directories, so they are
    /// not in the removal set and disclosing them would be a lie (D14).
    func map(
        prunableRecordsIn entries: [GitWorktreeEntry], adminContainer: URL
    ) -> GitAdminMappingVerdict {
        let targets = entries.filter { $0.isPrunable && !$0.isLocked }

        // ABSENCE is the ONLY benign container failure, and only when
        // nothing is prunable — a repository that never had a linked
        // worktree has no container at all. Everything else (a permission
        // denial, an I/O error, a container that is a file or a symlink) is
        // a container this mapper cannot account for, and a repo-wide prune
        // would still traverse it.
        switch identity.probeKind(of: adminContainer) {
        case .absent:
            if targets.isEmpty { return .complete(adminDirectories: []) }
            return .incomplete(
                reason: "admin container \(adminContainer.path) is absent while "
                    + "\(targets.count) prunable record(s) remain"
            )
        case .kind(.directory):
            break
        case .kind(let kind):
            return .incomplete(
                reason: "admin container \(adminContainer.path) is not a directory (\(kind))"
            )
        case .failed(let code):
            return .incomplete(
                reason: "admin container \(adminContainer.path) could not be inspected "
                    + "(errno \(code))"
            )
        }

        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: adminContainer.path).sorted()
        } catch {
            return .incomplete(
                reason: "admin container \(adminContainer.path) could not be read"
            )
        }

        // Gate EVERY entry before reading a single back-link.
        var gated: [URL] = []
        gated.reserveCapacity(names.count)
        let canonicalContainer = identity.canonicalize(adminContainer)
        let containerDevice = identity.deviceID(of: adminContainer)
        for name in names {
            let entry = adminContainer.appendingPathComponent(name)
            // (a) a REAL directory, no-follow — a symlinked entry is refused
            //     before anything about its target is consulted.
            guard identity.probeKind(of: entry) == .kind(.directory) else {
                return .incomplete(
                    reason: "admin entry \(entry.path) is not a real directory"
                )
            }
            // (b) canonicalizes strictly INSIDE the carried container.
            let canonicalEntry = identity.canonicalize(entry)
            guard Self.isStrictDescendant(canonicalEntry, of: canonicalContainer) else {
                return .incomplete(
                    reason: "admin entry \(entry.path) canonicalizes outside "
                        + "\(adminContainer.path)"
                )
            }
            // (c) same device as the container.
            guard let entryDevice = identity.deviceID(of: entry),
                  let containerDevice, entryDevice == containerDevice
            else {
                return .incomplete(
                    reason: "admin entry \(entry.path) is not on the container's device"
                )
            }
            // (d) its `gitdir` back-link is a NON-SYMLINK regular file.
            let backlink = entry.appendingPathComponent("gitdir")
            guard identity.probeKind(of: backlink) == .kind(.regularFile) else {
                return .incomplete(
                    reason: "admin entry \(entry.path) has no regular gitdir file"
                )
            }
            gated.append(entry)
        }

        // Only now read the back-links.
        var worktreePaths: [(entry: URL, worktree: URL)] = []
        worktreePaths.reserveCapacity(gated.count)
        for entry in gated {
            let backlink = entry.appendingPathComponent("gitdir")
            guard let contents = try? String(contentsOf: backlink, encoding: .utf8) else {
                return .incomplete(
                    reason: "admin entry \(entry.path) gitdir file is unreadable"
                )
            }
            let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .incomplete(
                    reason: "admin entry \(entry.path) gitdir file is empty"
                )
            }
            let dotGit = trimmed.hasPrefix("/")
                ? URL(fileURLWithPath: trimmed)
                : entry.appendingPathComponent(trimmed)
            // The back-link names `<worktree>/.git`; the worktree is its
            // parent. (The worktree itself is GONE for a prunable record —
            // that is what makes it prunable — so this comparison runs on
            // canonical paths, not inodes.)
            worktreePaths.append((entry, dotGit.deletingLastPathComponent()))
        }

        var mapped: [URL] = []
        for record in targets {
            let matches = worktreePaths
                .filter { identity.sameLocation($0.worktree, record.path) }
                .map(\.entry)
            guard !matches.isEmpty else {
                return .incomplete(
                    reason: "prunable worktree \(record.path.path) could not be "
                        + "mapped to an admin directory in \(adminContainer.path)"
                )
            }
            mapped.append(contentsOf: matches)
        }

        var unique: [URL] = []
        for directory in mapped.sorted(by: { $0.path < $1.path })
        where unique.last?.path != directory.path {
            unique.append(directory)
        }

        return .complete(adminDirectories: unique)
    }

    /// Strict path-component containment on ALREADY-CANONICAL URLs.
    private static func isStrictDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        let candidateComponents = candidate.pathComponents
        let ancestorComponents = ancestor.pathComponents
        guard candidateComponents.count > ancestorComponents.count else { return false }
        return Array(candidateComponents.prefix(ancestorComponents.count)) == ancestorComponents
    }
}
