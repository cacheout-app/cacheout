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
    enum FileKind {
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

    /// File kind at `url` (no-follow): a symlink reports `.symlink` regardless
    /// of what it points at.
    func kind(of url: URL) -> FileKind? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        switch st.st_mode & S_IFMT {
        case S_IFREG: return .regularFile
        case S_IFDIR: return .directory
        case S_IFLNK: return .symlink
        default: return .other
        }
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
