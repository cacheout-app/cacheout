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
/// pre-removal check) both call `GitWorktreeAdminMapper`. A second mapping
/// implementation is the thing this file exists to prevent: the set this
/// mapper returns IS the set fn-5.4 removes, directory by directory, so
/// detection and execution must agree byte for byte about which directories
/// those are.

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

        // THE GATE READS THE POINTER FIRST, AS SPELLED (fn-4.26). On an
        // `.automatic` scan the injected provider answers `.absent` for a
        // deferred (TCC-protected) target — and its predicate classifies a
        // directly-protected spelling lexically — so `canonicalize` below,
        // which is `realpath(3)` and therefore itself a traversal of every
        // component it resolves, runs only on a target the gate permitted.
        // The previous order canonicalized first, which walked the protected
        // path before the deferral could answer. No verdict changed: the
        // kinds that pass here are exactly the ones the canonical probe
        // below could still map onto a directory (a directory spelling, or a
        // symlink to one); every other kind, absence, and probe failure
        // produced nil AFTER the traversal — now before it.
        switch identity.probeKind(of: pointer) {
        case .kind(.directory), .kind(.symlink): break
        default: return nil
        }

        let adminDirectory = identity.canonicalize(pointer)
        guard identity.probeKind(of: adminDirectory) == .kind(.directory),
              adminDirectory.deletingLastPathComponent().lastPathComponent
                == Self.adminContainerName
        else { return nil }

        // BACK-LINK: the admin directory must point back at THIS worktree's
        // `.git` file. One-way, stale, and forged pointers all stop here.
        //
        // The back-link TARGET is data too, and `sameLocation`'s fallback
        // canonicalizes BOTH sides when either identity is missing — which a
        // deferred side always is — so the same gate answers for it before
        // the comparison (fn-4.26). A deferred target could never have
        // verified anyway: `dotGit` demonstrably exists, and a comparison of
        // an existing file against an untouchable one proves nothing.
        // Absence and probe failure fail exactly as they did before — the
        // fallback comparison they used to reach could not answer true for a
        // target that is not there while `dotGit` is.
        let backlinkFile = adminDirectory.appendingPathComponent("gitdir")
        guard identity.probeKind(of: backlinkFile) == .kind(.regularFile),
              let backlinkTarget = pathContents(of: backlinkFile, relativeTo: adminDirectory),
              case .kind = identity.probeKind(of: backlinkTarget),
              identity.sameLocation(backlinkTarget, dotGit)
        else { return nil }

        return adminDirectory
    }

    /// The BARE-repository proof (fn-4.28): is this directory a bare
    /// repository git itself would accept? `nil` = fail closed.
    ///
    /// Discovery keys on an entry named `.git`, and a bare repository has
    /// none — so a bare parent whose checkouts were ALL deleted used to name
    /// no group and the prune tier never ran for exactly the case it exists
    /// for. This proof is the discovery half of closing that gap; the
    /// listing half stays with `crossValidate`, whose bare branch requires
    /// git's OWN porcelain first record to declare the same directory bare
    /// before anything downstream is derived from it.
    ///
    /// WHAT IS REQUIRED, all probed through the injected identity provider
    /// (so the TCC deferral answers first, exactly as it does for the
    /// `gitdir:` pointer reads above), and each read only AFTER its
    /// `probeKind` gate:
    ///
    /// - `HEAD`, a regular file — never a symlink — whose content is a shape
    ///   git's own `validate_headref` accepts: a `ref: refs/…` symref or a
    ///   40/64-hex detached object id;
    /// - `objects`, a directory;
    /// - a refs backend: `refs` a directory, or the reftable layout's
    ///   `reftable` directory;
    /// - `config`, a regular file that DECLARES bareness the way git's own
    ///   writer spells it (a `bare = true` line). A git directory that backs
    ///   a working tree elsewhere (`--separate-git-dir`) carries the same
    ///   HEAD/objects/refs shape with `bare = false`, and admitting it here
    ///   would publish a cross-validation issue on every scan for a healthy
    ///   repository this scanner deliberately does not cover.
    ///
    /// RESIDUAL, disclosed rather than implied: a bare repository whose
    /// config spells bareness any way other than git's writer (`bare = yes`,
    /// an include, no config file at all) stays undiscovered — the same
    /// silent non-discovery every bare repository had before fn-4.28, never
    /// a refusal dressed as retryable.
    func bareRepositoryGitDirectory(at directory: URL) -> URL? {
        let head = directory.appendingPathComponent("HEAD")
        guard identity.probeKind(of: head) == .kind(.regularFile),
              let headContents = try? String(contentsOf: head, encoding: .utf8),
              Self.isAcceptableHeadContent(headContents)
        else { return nil }
        guard identity.probeKind(of: directory.appendingPathComponent("objects"))
            == .kind(.directory)
        else { return nil }
        let hasRefs = identity.probeKind(of: directory.appendingPathComponent("refs"))
            == .kind(.directory)
        let hasReftable = identity.probeKind(of: directory.appendingPathComponent("reftable"))
            == .kind(.directory)
        guard hasRefs || hasReftable else { return nil }
        let config = directory.appendingPathComponent("config")
        guard identity.probeKind(of: config) == .kind(.regularFile),
              let configContents = try? String(contentsOf: config, encoding: .utf8),
              Self.declaresBare(configContents)
        else { return nil }
        return directory
    }

    /// The HEAD shapes git's `validate_headref` accepts: `ref: refs/…`
    /// naming a non-empty ref, or a detached 40-hex (SHA-1) / 64-hex
    /// (SHA-256) object id.
    static func isAcceptableHeadContent(_ contents: String) -> Bool {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let symrefPrefix = "ref: refs/"
        if trimmed.hasPrefix(symrefPrefix) {
            return trimmed.count > symrefPrefix.count
        }
        guard trimmed.count == 40 || trimmed.count == 64 else { return false }
        return trimmed.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    /// The EFFECTIVE `core.bare`, resolved the way git resolves it: section
    /// context is honoured and the LAST value wins.
    ///
    /// The first version matched any line whose key was `bare`, anywhere in
    /// the file (PR #461 codex r2). Two shapes broke it, and git reads both
    /// the other way: a healthy `--separate-git-dir` repository carrying
    /// `core.bare = false` PLUS an unrelated section with its own `bare` key
    /// was admitted as bare, and an early `core.bare = true` later overridden
    /// by `false` stayed admitted. Admitting one is not a harmless
    /// over-discovery — the scanner then runs `worktree list` against a
    /// healthy non-bare admin directory and publishes a cross-validation
    /// `unreadable` issue on every scan, for a repository shape this scanner
    /// deliberately does not cover.
    ///
    /// RESIDUAL, unchanged and still disclosed: only git's own writer
    /// spelling of the VALUE counts. `bare = yes`, a valueless `bare` key
    /// (which git reads as true) and an `include.path` indirection all leave
    /// the repository undiscovered — the same silence every bare repository
    /// had before fn-4.28, never a refusal dressed as retryable.
    static func declaresBare(_ configContents: String) -> Bool {
        var section = ""
        var subsection: String?
        var effective: String?
        for rawLine in configContents.split(
            whereSeparator: \.isNewline
        ) {
            var line = Substring(Self.withoutComment(rawLine))
                .drop(while: { $0 == " " || $0 == "\t" })
            if line.first == "[" {
                guard let close = line.firstIndex(of: "]") else { continue }
                (section, subsection) = Self.sectionName(
                    line[line.index(after: line.startIndex)..<close]
                )
                // git allows a variable on the section header's own line.
                line = line[line.index(after: close)...]
                    .drop(while: { $0 == " " || $0 == "\t" })
            }
            guard !line.isEmpty, let equals = line.firstIndex(of: "=")
            else { continue }
            let key = line[..<equals]
                .trimmingCharacters(in: .whitespaces).lowercased()
            guard section == "core", subsection == nil, key == "bare"
            else { continue }
            var value = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces).lowercased()
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            // LAST WINS, which is the whole point: an override must be able
            // to turn bareness OFF, not merely fail to turn it on.
            effective = value
        }
        return effective == "true"
    }

    /// The line with any unquoted `#`/`;` comment removed. Quoted because a
    /// git config VALUE may legitimately contain either character.
    private static func withoutComment(_ line: Substring) -> String {
        var out = ""
        var quoted = false
        var escaped = false
        for character in line {
            if escaped { out.append(character); escaped = false; continue }
            if character == "\\" { out.append(character); escaped = true; continue }
            if character == "\"" { quoted.toggle(); out.append(character); continue }
            if !quoted, character == "#" || character == ";" { break }
            out.append(character)
        }
        return out
    }

    /// `[core]` -> ("core", nil); `[core "sub"]` -> ("core", "sub"). Section
    /// names are case-insensitive in git, subsection names are not — and a
    /// subsection makes the key `core.sub.bare`, which is NOT `core.bare`.
    private static func sectionName(
        _ header: Substring
    ) -> (String, String?) {
        guard let quote = header.firstIndex(of: "\"") else {
            return (
                header.trimmingCharacters(in: .whitespaces).lowercased(), nil
            )
        }
        let name = header[..<quote]
            .trimmingCharacters(in: .whitespaces).lowercased()
        let rest = header[header.index(after: quote)...]
        return (name, String(rest.prefix(while: { $0 != "\"" })))
    }

    /// The repository's COMMON git directory, via the admin directory's
    /// `commondir` file (usually the relative `../..`). Resolved rather than
    /// stripped so bare mains and `extensions.worktreeConfig` layouts work.
    func commonGitDirectory(forAdminDirectory adminDirectory: URL) -> URL? {
        let commonDirFile = adminDirectory.appendingPathComponent("commondir")
        guard identity.probeKind(of: commonDirFile) == .kind(.regularFile),
              let target = pathContents(of: commonDirFile, relativeTo: adminDirectory)
        else { return nil }
        // The same first-read gate as `adminDirectory(forWorktreeAt:)`
        // (fn-4.26): a `commondir` is usually the relative `../..`, but the
        // file's content is DATA — an absolute spelling into a deferred
        // location must be answered by the gate before `realpath(3)` walks
        // it. Verdicts are unchanged for every non-deferred shape.
        switch identity.probeKind(of: target) {
        case .kind(.directory), .kind(.symlink): break
        default: return nil
        }
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
            // The same first-read gate (fn-4.26): `sameLocation`'s fallback
            // canonicalizes BOTH sides when either identity is missing — and
            // a deferred side always is — so the gate answers for the
            // pointer target before the comparison. Worse than the
            // traversal, the fallback's canonical PATH equality would have
            // answered true for a deferred target, validating a repository
            // the scan was told not to touch. A genuinely absent target
            // could never compare equal to `parentGitDir`, which was probed
            // a directory moments ago — failing closed changes no reachable
            // verdict.
            guard case .kind = identity.probeKind(of: pointer) else { return false }
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

// MARK: - The orphaned-admin ORACLE (D10)

/// The ONE spelling of the orphaned-admin oracle listing — the read-only
/// command whose `prunable` annotations detection (fn-5.5) and execution
/// (fn-5.4's delete-time recompute and its final pre-removal check) both
/// consume. One argv, like the one mapper below: if detection and execution
/// asked git differently, they could disagree about which admin directories
/// the execution then removes.
///
/// `-c gc.worktreePruneExpire=now` is pinned (D10, empirically re-verified on
/// git 2.50.1): a freshly orphaned checkout is annotated `prunable` even
/// without the override, but OTHER orphan classes are expire-gated and the
/// 2.39 floor is not locally verifiable, so without it those classes are
/// invisible to BOTH sides and never reclaimed at all.
///
/// THERE IS NO EXECUTION PRUNE TO MATCH ANY MORE (PR #460 codex r1 / C4, and
/// this note is the r2 correction of a rationale that outlived it): the
/// repository-level mode removes the mapped directories itself, so
/// prunability is decided HERE and nowhere else, and the removal no longer
/// depends on git honouring an expire policy. The override is pinned on the
/// single shared argv precisely so the two call sites cannot drift.
///
/// NO MUTATION ARGV LIVES HERE — AND SINCE PR #460 codex r5 THERE IS NO
/// MUTATION ARGV ANYWHERE. Through r4 this note said the `worktree remove`
/// argv "belongs to the one component allowed to mutate,
/// `WorktreeReclaimPerformer`". That builder is gone, and the performer's own
/// line says so: "It is gone, argv builder and all". The boundary this note
/// is really about is unchanged — this type ANSWERS questions and never acts,
/// and the component that acts does the removal itself rather than by
/// spawning git.
enum GitWorktreeOracle {

    /// The config override that makes every expire-gated orphan class visible.
    static let pruneExpireOverride = "gc.worktreePruneExpire=now"

    /// `git -C <repo> -c gc.worktreePruneExpire=now worktree list --porcelain -z`
    /// — read-only by D17 classification, so the runner applies
    /// `GIT_OPTIONAL_LOCKS=0` + `-c core.fsmonitor=false` wherever it runs.
    static func listArguments(forRepositoryAt repository: URL) -> [String] {
        [
            "-C", repository.path, "-c", pruneExpireOverride,
            "worktree", "list", "--porcelain", "-z",
        ]
    }
}

// MARK: - Shared oracle → admin-directory mapper (epic round 10)

/// Whether the prunable set could be mapped COMPLETELY onto admin
/// directories. There is no partial answer on purpose: the verdict decides
/// whether a repository's registry may be offered AT ALL, and a
/// knowingly-incomplete account of a container the removal traverses would
/// let the operation touch something nobody was told about (D14).
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
/// immediately before the scoped removal. Two implementations would let
/// detection and execution disagree about which directories are destroyed.
///
/// The admin-ENTRY traversal gates run BEFORE any back-link is read (round
/// 10 / F3), over EVERY entry of the carried container — not only the ones
/// that happen to map. THIS MAPPER traverses the whole container: it
/// enumerates it and reads each entry's back-link, and its verdict claims
/// the set is provably COMPLETE. A single entry it cannot account for is
/// therefore a set it cannot prove complete, whatever the removal later
/// touches.
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
    /// incomplete: a locked admin directory is not in the removal set, so
    /// disclosing it would be a lie (D14).
    ///
    /// THE `!$0.isLocked` BELOW IS THE ONLY LOCK CHECK LEFT IN THE PIPELINE,
    /// and it is DEFENCE IN DEPTH rather than the thing standing between a
    /// user and lost data (PR #460 codex r2 / D6, corrected r3).
    ///
    /// It used to be a disclosure rule with a backstop: the execution was
    /// `git worktree prune`, which skips locked entries. That prune is
    /// retired (`WorktreeReclaimPerformer.removeAdminDirectories` removes the
    /// mapped directories itself and knows nothing about locks), so nothing
    /// downstream re-checks the lock — hence "the only one left".
    ///
    /// WHAT IT IS NOT is one line away from disaster. MEASURED on git 2.50.1:
    /// git does not annotate a locked worktree `prunable` AT ALL, even under
    /// `-c gc.worktreePruneExpire=now`, so `isPrunable && !isLocked` is
    /// already false on its FIRST clause for every record git produces, and
    /// the cells that cover this filter have to INJECT prunable+locked
    /// records synthetically. Keep the clause: it costs nothing and it holds
    /// if a future git ever does mark such a record. Do not read it as the
    /// last guard on a live path.
    /// THE ONE SPELLING of "the records whose admin directories a prune would
    /// remove" (PR #460 codex r18, C4). Three call sites read it — this
    /// mapper, the scanner's disclosure, and the delete-time preservation
    /// proof — and a second spelling would let one of them reason about a set
    /// the removal does not have.
    static func removalTargets(in entries: [GitWorktreeEntry]) -> [GitWorktreeEntry] {
        entries.filter { $0.isPrunable && !$0.isLocked }
    }

    func map(
        prunableRecordsIn entries: [GitWorktreeEntry], adminContainer: URL
    ) -> GitAdminMappingVerdict {
        let targets = Self.removalTargets(in: entries)

        // ABSENCE is the ONLY benign container failure, and only when
        // nothing is prunable — a repository that never had a linked
        // worktree has no container at all. Everything else (a permission
        // denial, an I/O error, a container that is a file or a symlink) is
        // a container this mapper cannot account for, and its own
        // enumeration below traverses it regardless.
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
            // EXACTLY ONE, OR THE REGISTRY IS AMBIGUOUS (PR #460 codex r21).
            //
            // The guard above refused ZERO matches and said nothing about
            // several. Two admin entries can carry the SAME `gitdir`
            // back-link, and git may then list one of them `locked` and the
            // other `prunable`. `removalTargets` excludes the locked RECORD —
            // but this mapper works from the back-link, so the locked entry's
            // DIRECTORY was mapped in anyway, on the strength of the other
            // record. Its lock is then never consulted (the last-instant
            // check re-reads the lock of the directory it is given, and the
            // caller was given both), and detached-HEAD preservation examined
            // only the prunable record — so the locked entry's unique commit
            // could be orphaned by a removal nothing about it authorized.
            //
            // A registry in that state is not something to resolve by picking
            // one; it is a shape this code has no proof about. Refuse it, and
            // say which directories collided so the user can look.
            guard matches.count == 1 else {
                let names = matches.map(\.lastPathComponent).sorted()
                return .incomplete(
                    reason: "prunable worktree \(record.path.path) maps to "
                        + "\(matches.count) admin directories "
                        + "(\(names.joined(separator: ", "))) in "
                        + "\(adminContainer.path) — the registry is ambiguous "
                        + "about which entry describes it, so none is pruned"
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

// MARK: - Detached-HEAD preservation (PR #460 codex r18, C4)

/// What the preservation proof answered about a repository's prune set.
enum GitOrphanedHeadVerdict: Equatable, Sendable {
    /// Every record in the set survives its own removal: it is attached to a
    /// ref, its HEAD is reachable from one, or the commit is not in the
    /// object database at all.
    case nothingOrphaned
    /// The prune would leave a commit named by nothing. The reason NAMES the
    /// checkout and the commit, and carries the remedy.
    case refuse(reason: String)
}

/// THE PROOF THAT PRUNING AN ADMIN DIRECTORY DESTROYS NO COMMIT
/// (PR #460 codex r18, C4).
///
/// ## What the hazard is, MEASURED on git 2.50.1 (Apple Git-155) today
///
/// A registered worktree that was `--detach`ed and then committed to has its
/// tip named by exactly one thing: the `HEAD` file inside its admin
/// directory. Delete the checkout and git calls the record `prunable`; delete
/// the ADMIN DIRECTORY — which is what this product's prune item does — and
/// the commit is named by nothing at all. Reproduced end to end: a detached
/// worktree with one commit, its checkout removed, `git fsck --unreachable
/// --no-reflogs` SILENT before the admin directory was removed and reporting
/// `unreachable commit <oid>` (plus its tree and blob) immediately after, and
/// a subsequent `git gc --prune=now` deleting the object outright
/// (`git cat-file -t <oid>` → `could not get object info`). That is the
/// user's own work, and the item that removes it is labelled `.safe`.
///
/// ## Why this REFUSES rather than preserving the commit itself
///
/// The obvious alternative — write `refs/…` or a tag at the commit before
/// pruning — would make this product WRITE INTO THE USER'S REPOSITORY. Every
/// git command this app has ever issued is read-only (`GitSafetyProfile`
/// classifies them, and the last two mutating argvs were retired in
/// PR #460 codex r5/r6); a scanner that silently creates refs is a different
/// product with a different consent model, and a ref it created would then
/// outlive the reclaim as litter nobody asked for. So the conservative arm is
/// taken: prove the commit survives, or offer nothing.
///
/// ## Why the refusal is not a permanent strand
///
/// The condition is USER-CLEARABLE and a retry genuinely differs: naming the
/// commit (`git branch`, `git tag`, a merge, a push) makes the very next scan
/// read `0` from the reachability query and offer the item. That is the
/// distinction the "deterministic bound dressed as a re-scan promise" doctrine
/// turns on — this is a fact about the repository, not a fixed limit of this
/// process.
///
/// ## What it does NOT cover, stated rather than implied
///
/// The admin directory also holds a per-worktree REFLOG, and entries in it
/// can name commits that no ref reaches (work that was `reset --hard` away,
/// for instance). Those are not checked: they are already invisible to
/// `git fsck --no-reflogs`, git's own `worktree prune` discards them exactly
/// as this removal does, and `gc.reflogExpireUnreachable` (30 days by
/// default) expires them anyway. The claim made here is precisely the one
/// that is proved — the record's HEAD commit — and nothing wider.
enum GitOrphanedHeadPreservation {

    /// `rev-parse --verify --quiet` answers 1 for "no such object". The
    /// discriminator against a real failure is the same one the D6 ladder
    /// uses: a genuine miss is SILENT (verified on git 2.50.1 — exit 1, no
    /// stdout, no stderr), while every diagnostic answer says something.
    static let missingObjectExitCode: Int32 = 1

    /// `git -C <repo> rev-parse --verify --quiet <oid>^{commit}` — does the
    /// object database still hold this commit? A commit that is ALREADY gone
    /// cannot be destroyed by removing a directory, and refusing on it would
    /// be a refusal no user action could ever clear.
    static func commitExistenceArguments(
        repositoryAt repository: URL, commit: String
    ) -> [String] {
        ["-C", repository.path, "rev-parse", "--verify", "--quiet", "\(commit)^{commit}"]
    }

    /// `git -C <repo> rev-list --single-worktree --max-count=1 --count <oid>
    /// --not --all` — prints `0` when the commit is reachable from some ref,
    /// `1` when it is reachable from none.
    ///
    /// `--single-worktree` IS THE WHOLE CORRECTNESS OF THIS QUERY, and its
    /// absence would make the check answer "safe" every single time. By
    /// default `--all` pretends every WORKING TREE's `HEAD` is listed too —
    /// including the doomed record's own, since a prunable worktree is still
    /// registered until it is pruned. MEASURED on the reproduction above:
    /// without the flag the query printed `0` (reachable) for the very commit
    /// `git fsck` reported unreachable one command later; with it, `1`.
    ///
    /// The cost of the flag is a conservative reading in one shape: a commit
    /// reachable ONLY from ANOTHER live worktree's detached HEAD reads as
    /// unreachable and is refused. That errs toward keeping the user's data,
    /// and it clears the same way every other reading here does.
    static func unreachableCountArguments(
        repositoryAt repository: URL, commit: String
    ) -> [String] {
        [
            "-C", repository.path, "rev-list", "--single-worktree",
            "--max-count=1", "--count", commit, "--not", "--all",
        ]
    }

    /// A syntactically usable object name: hex, and one of git's two hash
    /// lengths (SHA-1 / SHA-256). Anything else is not handed to git as a
    /// revision.
    static func isObjectName(_ text: String) -> Bool {
        (text.count == 40 || text.count == 64)
            && text.allSatisfy(\.isHexDigit)
    }

    /// The count `--count` printed, or nil when the output is not one.
    static func count(in stdout: Data) -> Int? {
        let text = String(decoding: stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Int(text)
    }

    /// Run the proof over the records a prune would remove the admin
    /// directories of.
    ///
    /// ONE implementation, both call sites — the scanner's disclosure and the
    /// performer's delete-time recompute — for the reason the mapper is
    /// shared: a detection that proves this and an execution that does not
    /// would destroy the commit anyway, and an execution stricter than
    /// detection would strand every offered item.
    ///
    /// ATTACHED RECORDS ARE NOT QUERIED, and that is not an omission: git
    /// REFUSES to delete a branch a registered worktree holds, prunable or
    /// not (`error: cannot delete branch 'x' used by worktree at …`, measured
    /// on 2.50.1), so the branch ref that names the tip is still there and
    /// still names it after the admin directory is gone.
    static func prove(
        prunableRecords: [GitWorktreeEntry],
        repositoryAt repository: URL,
        run: (_ arguments: [String]) async -> GitCommandOutcome
    ) async -> GitOrphanedHeadVerdict {
        for record in prunableRecords where record.isDetached {
            let checkout = record.path.path
            guard let commit = record.headSHA, isObjectName(commit) else {
                return .refuse(
                    reason: "the registered checkout '\(checkout)' is detached "
                        + "but this repository's listing named no usable commit "
                        + "for its HEAD, so it cannot be shown that pruning its "
                        + "admin directory destroys no work"
                )
            }
            let short = String(commit.prefix(12))

            switch await run(
                commitExistenceArguments(repositoryAt: repository, commit: commit)
            ) {
            case .success:
                break
            case .failure(let exitCode, let stderr)
                where exitCode == missingObjectExitCode
                && stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                // The commit is not in the object database — there is nothing
                // left for this removal to orphan.
                continue
            case .failure(let exitCode, let stderr):
                return .refuse(
                    reason: "whether the detached commit \(short) of the "
                        + "registered checkout '\(checkout)' still exists could "
                        + "not be answered "
                        + "(\(GitCommandFailureSummary.describe(exitCode: exitCode, stderr: stderr)))"
                )
            case .timeout:
                return .refuse(
                    reason: "the existence check for the detached commit "
                        + "\(short) of the registered checkout '\(checkout)' "
                        + "timed out"
                )
            case .gitUnavailable:
                return .refuse(
                    reason: "git became unavailable while checking the detached "
                        + "commit \(short) of the registered checkout "
                        + "'\(checkout)'"
                )
            }

            switch await run(
                unreachableCountArguments(repositoryAt: repository, commit: commit)
            ) {
            case .success(let stdout):
                guard let unreachable = count(in: stdout) else {
                    return .refuse(
                        reason: "the reachability query for the detached commit "
                            + "\(short) of the registered checkout '\(checkout)' "
                            + "produced no count"
                    )
                }
                guard unreachable == 0 else {
                    return .refuse(
                        reason: "the registered checkout '\(checkout)' was "
                            + "detached at commit \(short), and no branch, tag "
                            + "or other ref reaches that commit — its admin "
                            + "directory's HEAD is the only name it has, so "
                            + "pruning would leave the commit unreachable and a "
                            + "later `git gc` may delete it. Name the commit "
                            + "(`git branch <name> \(short)` or `git tag`), or "
                            + "prune this repository with git yourself, and the "
                            + "next scan offers it"
                    )
                }
            case .failure(let exitCode, let stderr):
                return .refuse(
                    reason: "whether the detached commit \(short) of the "
                        + "registered checkout '\(checkout)' is reachable from "
                        + "any ref could not be answered "
                        + "(\(GitCommandFailureSummary.describe(exitCode: exitCode, stderr: stderr)))"
                )
            case .timeout:
                return .refuse(
                    reason: "the reachability query for the detached commit "
                        + "\(short) of the registered checkout '\(checkout)' "
                        + "timed out"
                )
            case .gitUnavailable:
                return .refuse(
                    reason: "git became unavailable while checking whether the "
                        + "detached commit \(short) of the registered checkout "
                        + "'\(checkout)' is reachable"
                )
            }
        }
        return .nothingOrphaned
    }
}
