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
//
//  EVERY PROOF IS TAKEN AGAINST THE HELD PARENT, AND BEFORE THE DESTRUCTION,
//  never against the object being judged and never after the fact. Both
//  halves are load-bearing:
//
//  - anchored to the parent, because a root that supplies its own reference
//    point cannot disagree with itself — read the mount identity FROM the
//    opened root and a volume attached onto the target is invisible, every
//    descendant matching the mounted filesystem it was compared against;
//  - taken first, because a descriptor survives a `rename(2)` intact, so a
//    check made on the way back up passes judgement on entries that are
//    already unlinked.
//
//  THE DELETION ALSO PROVES *WHOSE* TREE IT IS (PR #458 review — the P1 the
//  descriptor-relative rewrite left open). Every proof above answers "am I
//  still inside the parent I was admitted under?", which a swap of the TARGET
//  ITSELF answers `yes` to: the replacement directory is created at the same
//  name, in the same parent, on the same volume. The caller's inspection
//  verdict is a fact about an OBJECT, so `remove(at:expecting:provider:)`
//  takes that object's identity and `fstat`s the ROOT DESCRIPTOR IT OPENED
//  before the first `unlinkat`. A path re-checked after the descriptor is
//  held is not a proof of anything; the held inode is.
//
//  RESIDUALS, MEASURED — not "one directory's enumeration", which is what
//  this comment used to claim and is false:
//
//  1. A relocated directory's ENTIRE REMAINING SUBTREE. `rename(2)` of a
//     directory the traversal is standing in (or of any ancestor of where it
//     is standing, up to the deletion root) leaves every descriptor and every
//     containment proof below it perfectly valid — `..` from a child still
//     names the relocated directory. So the traversal keeps going: it
//     `readdir`s each not-yet-visited subdirectory AFTER the relocation and
//     unlinks what it finds, at every depth, including entries the new owner
//     wrote there. The bound is the relocated directory's own subtree (the
//     unwind's `..` re-anchor refuses the moment it tries to climb OUT of
//     it, so the damage never spreads to the new owner's siblings), and the
//     deletion then fails `.relocated` — it does not report success.
//     Evidenced by `testAncestorRelocationDestroysTheNewOwnersWholeSubtree`.
//  2. The deletion root's final `rmdir`. There is no `frmdir(2)`: the last
//     act names the leaf in the parent descriptor. Measured on this
//     platform, that names what can be lost: `unlinkat(AT_REMOVEDIR)`
//     returns `ENOTDIR` on a non-directory and `ENOTEMPTY` (errno 66) on a
//     non-empty one, so a name swapped in that window costs at most ONE
//     EMPTY directory — never a tree, never a file.
//
//  POSIX offers no primitive that closes either: there is no way to pin a
//  directory to its parent for the duration of a read, and no way to remove
//  a directory by descriptor.

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
            /// The object opened at the target's name is NOT the object the
            /// caller's pre-delete inspection was about — or its identity
            /// could not be read at all. Unprovable ⇒ refused.
            case notTheInspectedObject
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
                // WHERE the boundary is changes what the user has to do
                // about it, so the two are not one sentence: a volume ON the
                // target is ejected, a volume INSIDE it is a nested mount.
                return depth == 0
                    ? "\(place): a volume is mounted here and the deletion "
                        + "never crosses a mount boundary — refused, not "
                        + "deleted"
                    : "\(place): a volume is mounted inside this folder and "
                        + "the deletion never crosses a mount boundary — "
                        + "refused, not deleted"
            case .relocated:
                return "\(place): the folder moved while it was being "
                    + "deleted — refused, re-scan required"
            case .unprovableLocation:
                return "\(place): the deletion could not prove which volume "
                    + "this folder is on — refused, not deleted"
            case .invalidTarget:
                return "\(place): not a removable item"
            case .notTheInspectedObject:
                // Deliberately the SAME sentence the cleaner's own path
                // check produces: to the user these are one event, and the
                // only difference is which layer caught it.
                return "\(place): the folder at this path is no longer the "
                    + "one that was inspected — it was replaced between the "
                    + "safety check and the deletion; refused, re-scan "
                    + "required"
            }
        }
    }

    /// Remove `url` — the item ITSELF, in its UNRESOLVED spelling: a symlink
    /// is removed AS a link, never through it (R4).
    ///
    /// `inspected` is WHAT THE CALLER'S PRE-DELETE INSPECTION WAS ABOUT, and
    /// it is proved against the descriptor this call opens, before anything
    /// is destroyed. `nil` says — explicitly, at the call site, because there
    /// is no default — that no inspection ran and there is nothing to bind
    /// to; it is not a way to skip the check.
    ///
    /// `provider` answers the mount question, and it is the same object the
    /// scanner's walk asks, so the two cannot classify a boundary
    /// differently. It is also the tests' injection seam.
    static func remove(
        at url: URL,
        expecting inspected: UserDataProbeResult.InspectedRoot?,
        provider: FileSystemIdentityProvider
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

        // THE KIND GATE **IS** THE OPEN — one syscall, so there is no window
        // between deciding what stands here and taking hold of it (a gate
        // BESIDE an open is a swap window by construction; this is the same
        // shape the scanner's root open already has). `O_NOFOLLOW` is what
        // makes the answer trustworthy rather than merely fast: measured on
        // this platform, `openat(parent, link-to-dir, O_DIRECTORY)` WITHOUT
        // it opens the link's target and the traversal below would then
        // recursively empty a directory that is not the item at all, while
        // WITH it the same call fails `ENOTDIR` and the link is unlinked AS
        // a link (R4). `O_DIRECTORY` is what makes it safe to point at any
        // leaf: on a fifo, a socket or a device node it fails `ENOTDIR`
        // without ever entering the driver's open (measured — `/dev/tty`,
        // `/dev/null`, `/dev/zero` and a real `mkfifo`, none of which
        // blocked).
        let root = openat(
            parentFd, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard root >= 0 else {
            let code = errno
            guard code == ENOTDIR else {
                throw Failure(path: url.path, cause: .posix(code), depth: 0)
            }
            // Symlink, regular file, fifo, socket, device: one unlink, and
            // never a resolution through it.
            //
            // THE BINDING FOR THIS ARM IS THE SYSCALL. A verdict of
            // `.noDirectoryTree` is about the ABSENCE of a tree at this
            // name, and `unlinkat` WITHOUT `AT_REMOVEDIR` cannot remove a
            // directory — measured on this platform: `EPERM`. So a directory
            // created here between the failed open and the unlink is refused
            // by the kernel, not by a re-check that would have its own
            // window.
            if let inspected {
                guard case .noDirectoryTree = inspected else {
                    throw Failure(
                        path: url.path, cause: .notTheInspectedObject,
                        depth: 0
                    )
                }
            }
            guard unlinkat(parentFd, leaf, 0) == 0 else {
                throw Failure(path: url.path, cause: .posix(errno), depth: 0)
            }
            return
        }

        // WHOSE TREE IS THIS? Asked of the OPENED INODE, before one entry is
        // unlinked. Every other proof in this file answers "am I inside the
        // parent I was admitted under?" — and a replacement directory
        // created at the target's own name answers that `yes`, in the right
        // parent, on the right volume, holding content nobody inspected.
        do {
            try proveInspectedRoot(
                inspected, is: root, provider: provider, displayPath: url.path
            )
        } catch {
            close(root)
            throw error
        }

        try removeTree(
            from: root, named: leaf, in: parentFd, displayPath: url.path,
            provider: provider
        )
    }

    /// Prove that the directory `root` names IS the object the caller's
    /// pre-delete inspection was about.
    ///
    /// `fstat` OF THE HELD DESCRIPTOR, never a re-`lstat` of the path: the
    /// path is exactly what an attacker re-points, and re-resolving it after
    /// the descriptor is held re-opens the race the descriptor closed. An
    /// identity that cannot be read is not a match — fail closed.
    private static func proveInspectedRoot(
        _ inspected: UserDataProbeResult.InspectedRoot?,
        is root: Int32,
        provider: FileSystemIdentityProvider,
        displayPath: String
    ) throws {
        // No inspection ran (contents mode): nothing to bind to. The caller
        // states this explicitly.
        guard let inspected else { return }
        guard case .directory(let expected) = inspected,
              provider.identity(ofDescriptor: root) == expected else {
            throw Failure(
                path: displayPath, cause: .notTheInspectedObject, depth: 0
            )
        }
    }

    // MARK: - The traversal

    /// One level of the unwind: the name to `rmdir` from the level above,
    /// and the identity that level MUST still have when `..` lands on it.
    private struct Ascent {
        let name: RawName
        let parent: FileSystemIdentityProvider.Identity
    }

    /// Empty the tree `root` names depth-first, then remove `leaf` itself
    /// from `parentFd`. TAKES OWNERSHIP of `root`.
    ///
    /// Iterative on purpose: recursion would hold one descriptor per level,
    /// which is the resource bill the scanner's walk already paid to retire.
    /// Here the bill is a constant — `parentFd`, the current directory, and
    /// at most one handle in flight — at ANY depth.
    private static func removeTree(
        from root: Int32,
        named leaf: RawName, in parentFd: Int32, displayPath: String,
        provider: FileSystemIdentityProvider
    ) throws {
        var current = root
        defer { if current >= 0 { close(current) } }

        // THE ROOT'S MOUNT IS JUDGED AGAINST THE PARENT, NEVER AGAINST
        // ITSELF. Taking the reference from the tree being deleted makes the
        // one case that matters most invisible: a volume attached ONTO the
        // target after the admission-time path check and before this
        // descriptor was opened (this runs on a background queue, so that
        // window is real and is not small) supplies its OWN filesystem id as
        // the baseline, every descendant then agrees with it, and the
        // traversal recursively empties somebody else's volume while
        // believing it never crossed a boundary. `removefile(3)`, which this
        // type replaces, does not cross mount points; inheriting that
        // guarantee means proving the root's mount from OUTSIDE the root.
        guard let parentMount = provider.mountIdentity(ofDescriptor: parentFd)
        else {
            throw Failure(
                path: displayPath, cause: .unprovableLocation, depth: 0
            )
        }
        guard let rootMount = provider.mountIdentity(ofDescriptor: current)
        else {
            throw Failure(
                path: displayPath, cause: .unprovableLocation, depth: 0
            )
        }
        guard rootMount == parentMount else {
            throw Failure(
                path: displayPath, cause: .mountBoundary, depth: 0
            )
        }
        guard let parentIdentity = provider.identity(ofDescriptor: parentFd)
        else {
            throw Failure(
                path: displayPath, cause: .unprovableLocation, depth: 0
            )
        }
        try proveContainment(
            of: current, in: parentIdentity, provider: provider,
            displayPath: displayPath, depth: 0
        )

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
                // BEFORE the first `unlinkat`, not after the level is empty.
                // A `rename(2)` between the `openat` above and this point
                // leaves the descriptor perfectly valid — that is what
                // descriptors do — pointing at a directory that now lives in
                // somebody else's tree, and the destructive pass would then
                // unlink whatever the new owner has put in it. The check on
                // the way back up (below) cannot save that: by the time it
                // runs the contents are gone, and a check that validates
                // what was already destroyed is not a guard.
                do {
                    try proveContainment(
                        of: child, in: identity, provider: provider,
                        displayPath: displayPath, depth: depth + 1
                    )
                } catch {
                    close(child)
                    throw error
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

    /// Prove that `directory` is STILL inside the inode we are holding, and
    /// throw if it is not — or if the question cannot be answered.
    ///
    /// The proof is containment, taken at this instant: `..` opened from the
    /// held descriptor, and its identity compared with the parent's. It is
    /// deliberately NOT a comparison against an identity recorded for
    /// `directory` itself — the descriptor keeps that identity through any
    /// number of renames, so a recorded-identity check agrees with a
    /// relocation instead of catching it.
    ///
    /// Errno classes are kept apart: a `..` that cannot be OPENED is a posix
    /// failure with its own code, while a `..` that opens but whose identity
    /// cannot be read is unprovable. Neither is treated as containment.
    private static func proveContainment(
        of directory: Int32,
        in parent: FileSystemIdentityProvider.Identity,
        provider: FileSystemIdentityProvider,
        displayPath: String,
        depth: Int
    ) throws {
        let up = openat(directory, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard up >= 0 else {
            throw Failure(
                path: displayPath, cause: .posix(errno), depth: depth
            )
        }
        defer { close(up) }
        guard let here = provider.identity(ofDescriptor: up) else {
            throw Failure(
                path: displayPath, cause: .unprovableLocation, depth: depth
            )
        }
        guard here == parent else {
            throw Failure(
                path: displayPath, cause: .relocated, depth: depth
            )
        }
    }

    /// A SECOND, INDEPENDENT description of the directory `fd` names, for
    /// `fdopendir` to take ownership of.
    ///
    /// `dup(fd)` is wrong twice, both measured on this platform:
    ///
    /// - it CLEARS `FD_CLOEXEC` (`fcntl(F_GETFD)` reports 0 on the copy),
    ///   so the handle is inheritable by anything this process spawns while
    ///   a permanent deletion is in flight, and
    /// - it SHARES the file offset with `fd`, so a second enumeration of the
    ///   same directory returns 0 entries (measured: 5, then 0) — a directory
    ///   silently reported as empty is the worst possible answer for a
    ///   deleter.
    ///
    /// `openat(fd, ".", O_CLOEXEC)` has neither property (measured: 5, then
    /// 5, `FD_CLOEXEC` set), and it is the SAME shape the scanner's bounded
    /// read uses — scan-time and delete-time do not get to drift.
    static func enumerationDescriptor(for fd: Int32) -> Int32 {
        openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
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
        let handle = enumerationDescriptor(for: fd)
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
