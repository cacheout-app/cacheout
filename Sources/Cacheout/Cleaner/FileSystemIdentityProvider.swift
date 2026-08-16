/// # FileSystemIdentityProvider — Canonical Path Resolution & Inode Identity
///
/// The single source of truth for filesystem identity questions asked by the
/// deletion-safety layer (`PathGuard`) and, later, the shared sizer. Two distinct
/// canonicalization operations exist ON PURPOSE — do not merge them:
///
/// - **Root resolution** (`canonicalize`): full `realpath(3)` of the whole path.
///   A symlink handed to us as a deletion/scan ROOT is judged (and would be
///   walked) by its real location. When the path does not exist, the deepest
///   existing ancestor is resolved and the remaining components are appended
///   unresolved (this is what makes `/var/folders` ↔ `/private/var/folders`
///   interchangeable even for not-yet-existing leaves).
/// - **Target resolution** (`resolveTargetKeepingLeaf`): ancestors fully
///   resolved, the LEAF NEVER resolved. A deletion target that is itself a
///   symlink must keep its own identity — deleting it removes the link, not
///   the destination. `URL.resolvingSymlinksInPath()` is wrong for both jobs
///   (lexical past a symlink, misses `/private` aliasing, leaves ancestors
///   unresolved on non-existent leaves) — hence `realpath(3)` here.
///
/// Identity comparisons are `(st_dev, st_ino)` via `lstat(2)` (no-follow):
/// three spellings of `$HOME` (direct, symlink alias, case variant) share one
/// inode even though no amount of string canonicalization collapses them.
///
/// The class is intentionally the ONLY production implementation. It is a
/// non-final class solely so tests (via `@testable`) can subclass and override
/// `identity(of:)` to inject device ids for hermetic cross-device / mount-point
/// cases.

import Foundation

class FileSystemIdentityProvider {

    /// Inode identity: device + inode number, from `lstat` (never follows a
    /// symlink leaf — a link's identity is the link itself).
    struct Identity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    /// What kind of filesystem object sits at a URL (via `lstat`, no-follow).
    /// (Explicitly `Equatable` for documentation's sake — `KindProbe`'s
    /// synthesized conformance and callers' `==` checks rely on it, though
    /// associated-value-free enums conform automatically.)
    enum FileKind: Equatable {
        case regularFile
        case directory
        case symlink
        case other
    }

    init() {}

    // MARK: - Identity (override point for tests)

    /// `(st_dev, st_ino)` of the object at `url` itself (lstat: a symlink's
    /// identity is the link, not its target). `nil` when the path is absent
    /// or unreadable. Tests override THIS method to inject device cases;
    /// `deviceID(of:)` derives from it so overrides flow through.
    func identity(of url: URL) -> Identity? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return Identity(
            device: UInt64(bitPattern: Int64(st.st_dev)),
            inode: UInt64(st.st_ino)
        )
    }

    /// Device id of the object at `url` (derived from `identity(of:)`).
    final func deviceID(of url: URL) -> UInt64? {
        identity(of: url)?.device
    }

    /// `(st_dev, st_ino)` of an OPEN DESCRIPTOR — the same identity model as
    /// `identity(of:)`, read from the object a caller actually holds open
    /// rather than from a path, which a concurrent writer can re-point
    /// between the check and the open.
    ///
    /// This is the only way to prove that what was opened IS what was
    /// vetted: a path check followed by a path open has an irreducible
    /// window between them, and re-checking the path only re-opens it. A
    /// leaf swapped for a symlink is refused by `O_NOFOLLOW` at the open
    /// itself; a leaf swapped for a DIFFERENT DIRECTORY passes every path
    /// check there is, and only this comparison catches it. Overridable
    /// alongside `identity(of:)` so both sides go through one seam.
    ///
    /// PAIRING RULE for tests: production reads both sides from the same
    /// object (`lstat` then `fstat`), so they always agree. A test that
    /// overrides `identity(of:)` for a directory the walk actually OPENS
    /// must override this in step, or the re-proof sees a divergence
    /// production cannot produce and refuses.
    func identity(ofDescriptor descriptor: Int32) -> Identity? {
        var st = stat()
        guard fstat(descriptor, &st) == 0 else { return nil }
        return Identity(
            device: UInt64(bitPattern: Int64(st.st_dev)),
            inode: UInt64(st.st_ino)
        )
    }

    // MARK: - Descriptor-relative primitives (PR #458 review, ancestor swap)

    /// Which MOUNT an open descriptor sits on.
    ///
    /// `f_fsid` rather than `f_mntonname` or `st_dev` alone, measured on
    /// this platform: EVERY path on a modern APFS system volume group
    /// reports the SAME `st_dev` (16777230 — `/`, `/System/Volumes/Data`
    /// and `/private/tmp` alike), so a device comparison is blind to the
    /// system/data firmlink split it was partly meant to catch. `f_fsid`
    /// separates them ({16777235,26} vs {16777230,26}). The device is kept
    /// as a second arm because it still catches ordinary external volumes
    /// (and is the arm hermetic tests inject), but `f_fsid` is what
    /// actually carries the check.
    ///
    /// Read from a DESCRIPTOR, never a path: the path form
    /// (`isMountPoint`) compares `f_mntonname` against the spelling it was
    /// handed, so an aliased spelling silently answered `false` — a whole
    /// failure class that dies with this method.
    struct MountIdentity: Equatable {
        /// `statfs.f_fsid.val` — the filesystem's own id pair.
        let filesystemID: (Int32, Int32)
        /// `st_dev` of the descriptor itself.
        let device: UInt64

        static func == (lhs: MountIdentity, rhs: MountIdentity) -> Bool {
            lhs.filesystemID == rhs.filesystemID && lhs.device == rhs.device
        }
    }

    /// `(f_fsid, st_dev)` of an OPEN DESCRIPTOR. `nil` when either call
    /// fails, which callers must treat as unvetted.
    ///
    /// Override point for hermetic mount tests: injecting a foreign
    /// `filesystemID` (or `device`) here is the descriptor-shaped
    /// equivalent of the retired `isMountPoint` inode injection, and it
    /// cannot be defeated by path spelling.
    func mountIdentity(ofDescriptor descriptor: Int32) -> MountIdentity? {
        var fs = statfs()
        guard fstatfs(descriptor, &fs) == 0 else { return nil }
        var st = stat()
        guard fstat(descriptor, &st) == 0 else { return nil }
        return MountIdentity(
            filesystemID: (fs.f_fsid.val.0, fs.f_fsid.val.1),
            device: UInt64(bitPattern: Int64(st.st_dev))
        )
    }

    /// Kind AND identity of one child, from ONE atomic `fstatat`.
    ///
    /// Two separate path `lstat`s of the same name (one for the kind, one
    /// for the identity) are two independent resolutions with a window
    /// between them; one `fstatat` against a HELD parent descriptor is a
    /// single resolution that cannot be re-pointed, because the parent is
    /// an inode we already hold rather than a path anyone can swap.
    struct ChildFacts: Equatable {
        let kind: FileKind
        let identity: Identity
    }

    /// Errno-aware descriptor-relative probe result — the `KindProbe`
    /// shape, carrying the identity the same stat established.
    enum ChildProbe: Equatable {
        case facts(ChildFacts)
        /// ENOENT/ENOTDIR — the entry simply is not there any more.
        case absent
        /// `fstatat` failed for another reason (EACCES, EIO, …).
        case failed(errno: Int32)
    }

    /// `fstatat(descriptor, name, AT_SYMLINK_NOFOLLOW)` — the walk's ONE
    /// per-entry syscall below its root.
    ///
    /// `logical` is the walk's UNRESOLVED spelling of the child. Production
    /// IGNORES it completely (no path ever reaches a syscall here); it is
    /// carried solely so tests can key overrides and touch-recording on the
    /// path the walk believes it is at.
    ///
    /// IT IS AN `@autoclosure` PRECISELY BECAUSE PRODUCTION IGNORES IT. The
    /// walk keeps its spelling as one basename per level and composes a URL
    /// only for whoever actually wants one, so the per-entry
    /// `appendingPathComponent` against a full parent path — O(depth) work
    /// per entry, and O(depth²) retained bytes down a deep chain — is not
    /// performed at all unless an override evaluates it. Overrides evaluate
    /// `logical()` once and pass the value on.
    ///
    /// `name` MUST be a single safe component — callers validate before
    /// calling, because `openat`/`fstatat` happily accept a MULTI-COMPONENT
    /// relative path, and `O_NOFOLLOW` then guards only its last component
    /// (measured: `openat(base, "cache/mid/secret.bin", O_NOFOLLOW)` opens a
    /// foreign file through a symlinked `mid`).
    func probeChild(
        inDirectory descriptor: Int32, named name: String,
        logical: @autoclosure () -> URL
    ) -> ChildProbe {
        var st = stat()
        guard fstatat(descriptor, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            return (code == ENOENT || code == ENOTDIR)
                ? .absent
                : .failed(errno: code)
        }
        let kind: FileKind
        switch st.st_mode & S_IFMT {
        case S_IFREG: kind = .regularFile
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        return .facts(ChildFacts(
            kind: kind,
            identity: Identity(
                device: UInt64(bitPattern: Int64(st.st_dev)),
                inode: UInt64(st.st_ino)
            )
        ))
    }

    /// The outcome of a descriptor-relative directory open — errno carried
    /// rather than left in the global, which an override could clobber.
    enum DescriptorOpen: Equatable {
        case opened(Int32)
        case failed(errno: Int32)
    }

    /// `openat(descriptor, name, O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW)`.
    ///
    /// Single component only (see `probeChild`). The descent's safety comes
    /// from CONTAINMENT — the child is resolved inside an inode we hold —
    /// not from re-checking a recorded identity, which an ancestor swap
    /// makes meaningless (the recorded value is then already the foreign
    /// object's).
    /// `logical` is lazy for the same reason as `probeChild`'s: production
    /// never composes it.
    func openChildDirectory(
        inDirectory descriptor: Int32, named name: String,
        logical: @autoclosure () -> URL
    ) -> DescriptorOpen {
        let fd = openat(
            descriptor, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        return fd >= 0 ? .opened(fd) : .failed(errno: errno)
    }

    /// `st_nlink` of the object at `url` (no-follow). Hardlink detection:
    /// `linkCount > 1` on a regular file.
    func linkCount(of url: URL) -> UInt64? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return UInt64(st.st_nlink)
    }

    /// Is `url` itself a mount point (the root directory of a mounted
    /// filesystem)? Implemented via `statfs(2)`: the path is a mount root iff
    /// it IS the containing filesystem's `f_mntonname`.
    ///
    /// This exists because device-id change alone is NOT sufficient on modern
    /// macOS: volumes in a unified APFS volume group present ONE `st_dev` —
    /// measured on macOS 15: `/` and `/System/Volumes/Data` both report
    /// device 16777230, while a genuinely separate volume like
    /// `/System/Volumes/Update` reports its own. `statfs` still names the
    /// Data firmlink mount as its own `f_mntonname`, so both signals are used
    /// by the deny list. Note `statfs` follows a symlink leaf — callers pass
    /// canonical paths, and a mere LINK to a volume root correctly reports
    /// `false` (deleting the link touches only the link).
    func isMountPoint(_ url: URL) -> Bool {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { return false }
        let mountedOn = withUnsafeBytes(of: &fs.f_mntonname) { raw -> String in
            guard let baseAddress = raw.bindMemory(to: CChar.self).baseAddress else {
                return ""
            }
            return String(cString: baseAddress)
        }
        return mountedOn == url.path
    }

    /// Errno-aware kind probe result: distinguishes "nothing there" (the
    /// callers' silent-skip case) from a real metadata failure that must be
    /// recorded, never swallowed (D6).
    enum KindProbe: Equatable {
        case kind(FileKind)
        /// ENOENT/ENOTDIR — the path simply is not there.
        case absent
        /// `lstat` failed for a reason other than absence (EACCES, EIO, …).
        case failed(errno: Int32)
    }

    /// `lstat`-based kind probe at `url` (no-follow), with errno retained on
    /// failure. This is the override point for tests; `kind(of:)` derives
    /// from it so overrides flow through.
    func probeKind(of url: URL) -> KindProbe {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            let code = errno
            return (code == ENOENT || code == ENOTDIR)
                ? .absent
                : .failed(errno: code)
        }
        switch st.st_mode & S_IFMT {
        case S_IFREG: return .kind(.regularFile)
        case S_IFDIR: return .kind(.directory)
        case S_IFLNK: return .kind(.symlink)
        default: return .kind(.other)
        }
    }

    /// File kind at `url` (no-follow): a symlink reports `.symlink` regardless
    /// of what it points at. `nil` collapses both "absent" and "failed" —
    /// callers that must distinguish (D6 classification) use `probeKind(of:)`.
    final func kind(of url: URL) -> FileKind? {
        if case .kind(let kind) = probeKind(of: url) { return kind }
        return nil
    }

    // MARK: - Canonicalization

    /// `realpath(3)` of `path`; `nil` when it fails (typically ENOENT).
    func realPath(of path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return nil }
        return String(cString: buffer)
    }

    /// Root resolution: full canonical path. If `url` exists this is exactly
    /// `realpath(3)` — every component including the leaf resolved. If it does
    /// not exist, the deepest existing ancestor is resolved and the remaining
    /// components are appended unresolved.
    func canonicalize(_ url: URL) -> URL {
        if let resolved = realPath(of: url.path) {
            return URL(fileURLWithPath: resolved)
        }
        var current = url.standardizedFileURL
        var tail: [String] = []
        while current.pathComponents.count > 1 {
            tail.insert(current.lastPathComponent, at: 0)
            current = current.deletingLastPathComponent()
            if let resolved = realPath(of: current.path) {
                var out = URL(fileURLWithPath: resolved)
                for component in tail {
                    out.appendPathComponent(component)
                }
                return out
            }
        }
        return url.standardizedFileURL
    }

    /// Target resolution: ancestors fully resolved, leaf appended UNRESOLVED.
    /// The deletion target's own name is never followed — a symlink leaf keeps
    /// the link's identity, and a non-existent leaf still yields a canonical
    /// position (its parent chain resolves).
    func resolveTargetKeepingLeaf(_ url: URL) -> URL {
        let leaf = url.lastPathComponent
        let parent = url.deletingLastPathComponent()
        guard parent.pathComponents.count >= 1, leaf != "/" else {
            return canonicalize(url)
        }
        return canonicalize(parent).appendingPathComponent(leaf)
    }

    // MARK: - Location comparison

    /// Same filesystem object? Inode identity when both sides exist (immune to
    /// case, NFC/NFD, and spelling differences); canonical path-components
    /// equality as the fallback when either side does not exist yet.
    final func sameLocation(_ a: URL, _ b: URL) -> Bool {
        if let ia = identity(of: a), let ib = identity(of: b) {
            return ia == ib
        }
        return canonicalize(a).pathComponents == canonicalize(b).pathComponents
    }
}
