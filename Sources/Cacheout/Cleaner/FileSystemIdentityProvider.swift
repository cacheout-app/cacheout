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

    /// The ALL-INTEGER no-follow metadata ONE `lstat(2)` yields (fn-4.4,
    /// R17): inode identity, leaf allocation, and modification time as
    /// integers. `device`/`inode` follow `Identity`'s convention exactly.
    /// No `Date` — a `Date` round trip loses the nanosecond and is what the
    /// valuables identity path exists to avoid.
    struct LeafMetadata: Hashable {
        let device: UInt64
        let inode: UInt64
        /// `st_blocks * 512` — the LEAF's own allocation (a directory's own
        /// inode allocation, for a directory).
        let allocatedBytes: Int64
        /// `st_mtimespec.tv_sec`.
        let modifiedSeconds: Int64
        /// `st_mtimespec.tv_nsec`, guaranteed in `[0, 1e9)` by the accessor.
        let modifiedNanoseconds: Int64
    }

    /// ONE no-follow `lstat` of `url` → the five integers above; `nil` when
    /// the path is absent, unreadable, OR reports metadata OUTSIDE the pinned
    /// value domains (a nanosecond field outside `[0, 1e9)`, a
    /// seconds×1e9+ns product that would overflow `Int64`, or a block count
    /// whose byte figure overflows). Fail-CLOSED at the source: a caller can
    /// never build an out-of-domain identity from real filesystem metadata,
    /// so a hostile or broken filesystem cannot malform a whole scan outcome
    /// downstream — it can only make the inspection INCOMPLETE. Checked with
    /// overflow-reporting arithmetic; nothing is ever saturated.
    func leafMetadata(of url: URL) -> LeafMetadata? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        let (allocated, blocksOverflow) = Int64(st.st_blocks)
            .multipliedReportingOverflow(by: 512)
        guard !blocksOverflow, allocated >= 0 else { return nil }
        let seconds = Int64(st.st_mtimespec.tv_sec)
        let nanoseconds = Int64(st.st_mtimespec.tv_nsec)
        // The PINNED domain, named ONCE beside the model it belongs to — the
        // source check, the derivation, and the validator cannot disagree.
        let scale = ValuableIdentity.nanosecondsPerSecond
        guard nanoseconds >= 0, nanoseconds < scale else { return nil }
        let (scaled, scaleOverflow) = seconds
            .multipliedReportingOverflow(by: scale)
        guard !scaleOverflow,
              !scaled.addingReportingOverflow(nanoseconds).overflow
        else { return nil }
        return LeafMetadata(
            device: UInt64(bitPattern: Int64(st.st_dev)),
            inode: UInt64(st.st_ino),
            allocatedBytes: allocated,
            modifiedSeconds: seconds,
            modifiedNanoseconds: nanoseconds
        )
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
