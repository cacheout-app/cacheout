//  DepthSafeRemoval.swift
//  Recursive removal that traverses by DESCRIPTOR, never by path.
//
//  WHY THIS EXISTS (PR #458 review — the stranding class that MOVED).
//
//  Making the user-data probe descriptor-relative (e9de405 and the ancestor-
//  swap round after it) let INSPECTION walk past `PATH_MAX`. Deletion was
//  left on `FileManager.removeItem(at:)`, which composes an absolute path per
//  entry, so the codebase started manufacturing items that are provably clean
//  and permanently undeletable. Measured on real chains built with `mkdirat`
//  (the only way one can exist), depths 300 / 446 / 600 / 2000 / 4000 —
//  threshold exactly `PATH_MAX`:
//
//  - probe          `complete=true, obstructions=[]` at every depth;
//  - `DirectorySizer` `itemCount=0, exact=0, denials=1`, detail "The item
//    couldn't be opened because the file name "d" is invalid";
//  - `removeItem`   NSCocoaErrorDomain 514 (underlying NSPOSIXErrorDomain 63,
//    ENAMETOOLONG) in 0.03 s — deterministically, forever;
//  - `rm -rf`       removes the identical tree, status 0.
//
//  The refusal was the app's own, not the OS's: `rm` uses `fts`, which
//  `chdir`s/`openat`s its way down and therefore never spells a long path.
//  So does this. Below the deletion root, no operation here takes a path;
//  containment in a held parent descriptor is the proof, exactly as in the
//  scanner's bounded walk — which is also why both sides ask the SAME
//  `FileSystemIdentityProvider` about mount boundaries, so scan-time and
//  delete-time cannot drift.
//
//  Descriptor cost is a CONSTANT (parent + current + one in-flight handle),
//  not a function of depth: the traversal keeps one descriptor and climbs
//  back with `openat(cur, "..")`, verifying at every step that `..` landed on
//  the directory it left — a `rename` of the current directory into a foreign
//  parent otherwise redirects the rest of the deletion into somebody else's
//  tree.

import Foundation

/// Depth-independent, no-follow, mount-respecting recursive removal.
///
/// The ONE removal primitive behind `CacheCleaner`'s permanent-delete paths.
/// It is deliberately not a general `rm`: it refuses rather than guesses
/// whenever it cannot prove where it is standing.
enum DepthSafeRemoval {

    /// A directory-entry name as the filesystem gave it: raw, NUL-terminated
    /// bytes.
    ///
    /// NOT a `String`. `d_name` is whatever the filesystem driver wrote, and
    /// decoding it through Swift's repairing initializer produces a name that
    /// addresses a DIFFERENT entry (or none). The probe refuses undecodable
    /// names because it must reason about them; deletion only has to unlink
    /// them, and it can — bytes in, bytes out.
    typealias RawName = [CChar]

    /// Why a removal stopped, in the caller's language.
    struct Failure: LocalizedError {
        enum Cause: Equatable {
            /// A syscall failed; the errno is carried verbatim.
            case posix(Int32)
            /// A directory below the target sits on another filesystem —
            /// the R15 mount doctrine, enforced where the sizer cannot see
            /// (a tree it could not measure), not only where it can.
            case mountBoundary
            /// `..` did not land on the directory it was left from: the tree
            /// was restructured mid-deletion. Continuing would delete
            /// entries by name inside a FOREIGN directory.
            case relocated
            /// A descriptor whose device/mount could not be read at all.
            /// Unprovable ⇒ refused.
            case unprovableLocation
            /// A target with no removable leaf ("/", ".", "..").
            case invalidTarget
        }

        let path: String
        let cause: Cause
        /// Where inside the tree, in levels below the target — the honest
        /// locator when the path itself cannot be spelled.
        let depth: Int

        var errorDescription: String? {
            let place = depth == 0
                ? path
                : "\(path) (\(depth) level\(depth == 1 ? "" : "s") down)"
            switch cause {
            case .posix(let code):
                return "\(place): \(String(cString: strerror(code)))"
            case .mountBoundary:
                return "\(place): a volume is mounted inside this folder and "
                    + "the deletion never crosses a mount boundary — refused, "
                    + "not deleted"
            case .relocated:
                return "\(place): the folder moved while it was being "
                    + "deleted — refused, re-scan required"
            case .unprovableLocation:
                return "\(place): the deletion could not prove which volume "
                    + "this folder is on — refused, not deleted"
            case .invalidTarget:
                return "\(place): not a removable item"
            }
        }
    }

    /// Remove `url` — the item ITSELF, in its UNRESOLVED spelling: a symlink
    /// is removed AS a link, never through it (R4).
    ///
    /// `provider` answers the mount question, and it is the same object the
    /// scanner's walk asks, so the two cannot classify a boundary
    /// differently. It is also the tests' injection seam.
    static func remove(
        at url: URL, provider: FileSystemIdentityProvider
    ) throws {
        let leafName = url.lastPathComponent
        guard !leafName.isEmpty, leafName != "/", leafName != ".",
              leafName != ".." else {
            throw Failure(path: url.path, cause: .invalidTarget, depth: 0)
        }
        let leaf = RawName(leafName.utf8CString)

        // The ONE path this whole operation resolves, and it is the target's
        // PARENT — always inside `PATH_MAX`, because the target itself came
        // through the path guard's admission. Everything below is relative
        // to the descriptor opened here.
        let parentPath = url.deletingLastPathComponent().path
        let parentFd = parentPath.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard parentFd >= 0 else {
            throw Failure(path: url.path, cause: .posix(errno), depth: 0)
        }
        defer { close(parentFd) }

        var leafStat = stat()
        guard fstatat(parentFd, leaf, &leafStat, AT_SYMLINK_NOFOLLOW) == 0
        else {
            throw Failure(path: url.path, cause: .posix(errno), depth: 0)
        }
        guard (leafStat.st_mode & S_IFMT) == S_IFDIR else {
            // Symlink, regular file, fifo, socket, device: one unlink, and
            // never a resolution through it.
            guard unlinkat(parentFd, leaf, 0) == 0 else {
                throw Failure(path: url.path, cause: .posix(errno), depth: 0)
            }
            return
        }

        try removeTree(
            named: leaf, in: parentFd, displayPath: url.path,
            provider: provider
        )
    }

    // MARK: - The traversal

    /// One level of the unwind: the name to `rmdir` from the level above,
    /// and the identity that level MUST still have when `..` lands on it.
    private struct Ascent {
        let name: RawName
        let parent: FileSystemIdentityProvider.Identity
    }

    /// Empty `name`'s tree depth-first, then remove `name` itself.
    ///
    /// Iterative on purpose: recursion would hold one descriptor per level,
    /// which is the resource bill the scanner's walk already paid to retire.
    /// Here the bill is a constant — `parentFd`, the current directory, and
    /// at most one handle in flight — at ANY depth.
    private static func removeTree(
        named leaf: RawName, in parentFd: Int32, displayPath: String,
        provider: FileSystemIdentityProvider
    ) throws {
        var current = openat(
            parentFd, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard current >= 0 else {
            throw Failure(path: displayPath, cause: .posix(errno), depth: 0)
        }
        defer { if current >= 0 { close(current) } }

        guard let rootMount = provider.mountIdentity(ofDescriptor: current)
        else {
            throw Failure(
                path: displayPath, cause: .unprovableLocation, depth: 0
            )
        }

        /// Subdirectory names not yet descended into, one list per level of
        /// the CURRENT path. Bounded by what is actually on the path, exactly
        /// as `du` is — never by the size of the whole tree.
        var pending: [[RawName]] = []
        var ascent: [Ascent] = []

        pending.append(
            try emptyOfNonDirectories(
                current, displayPath: displayPath, depth: 0
            )
        )

        while true {
            let depth = ascent.count
            if let name = pending[pending.count - 1].popLast() {
                guard let identity = provider.identity(ofDescriptor: current)
                else {
                    throw Failure(
                        path: displayPath, cause: .unprovableLocation,
                        depth: depth
                    )
                }
                let child = openat(
                    current, name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard child >= 0 else {
                    let code = errno
                    switch code {
                    case ENOENT:
                        // Gone since the read — nothing left to remove.
                        continue
                    case ENOTDIR, ELOOP:
                        // Replaced by a file or a symlink since the read.
                        // Remove it AS what it now is; never through it.
                        guard unlinkat(current, name, 0) == 0
                                || errno == ENOENT else {
                            throw Failure(
                                path: displayPath, cause: .posix(errno),
                                depth: depth
                            )
                        }
                        continue
                    default:
                        throw Failure(
                            path: displayPath, cause: .posix(code),
                            depth: depth
                        )
                    }
                }
                guard let childMount = provider.mountIdentity(
                    ofDescriptor: child
                ) else {
                    close(child)
                    throw Failure(
                        path: displayPath, cause: .unprovableLocation,
                        depth: depth + 1
                    )
                }
                guard childMount == rootMount else {
                    // We did not look past it and we do not delete past it —
                    // the same refusal the sizer's `mountBoundaries` check
                    // makes for trees it CAN measure (R15).
                    close(child)
                    throw Failure(
                        path: displayPath, cause: .mountBoundary,
                        depth: depth + 1
                    )
                }
                close(current)
                current = child
                ascent.append(Ascent(name: name, parent: identity))
                pending.append(
                    try emptyOfNonDirectories(
                        current, displayPath: displayPath, depth: depth + 1
                    )
                )
                continue
            }

            // This level holds nothing but itself now.
            pending.removeLast()
            guard let step = ascent.popLast() else {
                // Back at the deletion root: remove it through the parent
                // descriptor held since the very first line.
                close(current)
                current = -1
                guard unlinkat(parentFd, leaf, AT_REMOVEDIR) == 0 else {
                    throw Failure(
                        path: displayPath, cause: .posix(errno), depth: 0
                    )
                }
                return
            }
            let up = openat(current, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            close(current)
            current = up
            guard up >= 0 else {
                throw Failure(
                    path: displayPath, cause: .posix(errno), depth: depth
                )
            }
            // `..` IS NOT A PROOF, it is a lookup. A directory renamed into
            // a foreign parent while we stood inside it makes `..` name that
            // foreign parent, and every remaining entry in `pending` would
            // then be unlinked THERE, by name, out of somebody else's tree.
            // Measured with a real `rename(2)` fired at this exact instant.
            guard provider.identity(ofDescriptor: up) == step.parent else {
                throw Failure(
                    path: displayPath, cause: .relocated, depth: depth - 1
                )
            }
            guard unlinkat(current, step.name, AT_REMOVEDIR) == 0
                    || errno == ENOENT else {
                throw Failure(
                    path: displayPath, cause: .posix(errno), depth: depth - 1
                )
            }
        }
    }

    /// Unlink every non-directory child of `fd` and return the names of the
    /// directories left behind, in reverse traversal order (the caller pops
    /// from the end).
    ///
    /// ONE `readdir` pass per directory, and the names are kept rather than
    /// re-read: coming back up, the subdirectory just finished is gone and
    /// the rest are still in hand, so the whole traversal stays linear in
    /// entries. Re-opening and re-reading on every return is what makes a
    /// naive descriptor-relative `rm` quadratic in a wide directory.
    private static func emptyOfNonDirectories(
        _ fd: Int32, displayPath: String, depth: Int
    ) throws -> [RawName] {
        // `fdopendir` takes ownership of the descriptor it is handed, and
        // the caller still needs `fd`.
        let handle = dup(fd)
        guard handle >= 0 else {
            throw Failure(path: displayPath, cause: .posix(errno), depth: depth)
        }
        guard let stream = fdopendir(handle) else {
            let code = errno
            close(handle)
            throw Failure(path: displayPath, cause: .posix(code), depth: depth)
        }
        defer { closedir(stream) }

        var subdirectories: [RawName] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                let code = errno
                guard code == 0 else {
                    throw Failure(
                        path: displayPath, cause: .posix(code), depth: depth
                    )
                }
                break
            }
            let length = Int(entry.pointee.d_namlen)
            guard length > 0 else { continue }
            var name = RawName(repeating: 0, count: length + 1)
            withUnsafeBytes(of: entry.pointee.d_name) { raw in
                _ = name.withUnsafeMutableBytes { destination in
                    memcpy(destination.baseAddress!, raw.baseAddress!, length)
                }
            }
            if isDotEntry(name, length: length) { continue }

            let isDirectory: Bool
            switch entry.pointee.d_type {
            case UInt8(DT_DIR):
                isDirectory = true
            case UInt8(DT_UNKNOWN):
                // Not every filesystem fills `d_type` in (a userland one need
                // not), so ask — no-follow, against THIS held descriptor.
                var st = stat()
                guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                    if errno == ENOENT { continue }
                    throw Failure(
                        path: displayPath, cause: .posix(errno), depth: depth
                    )
                }
                isDirectory = (st.st_mode & S_IFMT) == S_IFDIR
            default:
                isDirectory = false
            }

            if isDirectory {
                subdirectories.append(name)
            } else if unlinkat(fd, name, 0) != 0, errno != ENOENT {
                throw Failure(
                    path: displayPath, cause: .posix(errno), depth: depth
                )
            }
        }
        return subdirectories
    }

    /// `.` and `..` by BYTES — the two names the traversal must never take.
    private static func isDotEntry(_ name: RawName, length: Int) -> Bool {
        let dot = CChar(bitPattern: UInt8(ascii: "."))
        if length == 1 { return name[0] == dot }
        if length == 2 { return name[0] == dot && name[1] == dot }
        return false
    }
}
