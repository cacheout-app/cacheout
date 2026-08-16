import Foundation

/// # DeepRemover — the descriptor-relative removal primitive
///
/// The one destructive syscall sequence behind every permanent delete this
/// app performs. It exists because `FileManager.removeItem` — i.e.
/// `removefile(3)`, which resolves a full path for every entry it touches —
/// is not a safe removal for a tree this app is willing to CALL clean.
///
/// ## The defect it closes (fn-4, review r9)
///
/// The valuables probe and the artifact walk are descriptor-anchored
/// (`openat` one component at a time) and therefore see PAST `PATH_MAX`. The
/// removal was not. So the scanner could prove a tree clean, offer it, and
/// then hand it to a remover that walks in `readdir` order, unlinks
/// everything it reaches, hits the first over-`PATH_MAX` component and
/// returns ENAMETOOLONG. Measured with the raw syscall on a `target/`
/// holding 40 ordinary files plus a 120-deep chain of 20-byte components:
/// 41 entries in, 31 left. At 201 entries in, 176 left. The user was shown
/// "the file name "target" is invalid" and ZERO bytes freed while a quarter
/// of the tree was already gone — the one outcome a cleaner must never
/// produce.
///
/// This is not an OS limit. `rm -rf` removes the identical tree in 0.57s,
/// because `fts` traverses relatively. So does this.
///
/// ## The walk
///
/// Every operation below the removal root takes a NAME plus a HELD PARENT
/// DESCRIPTOR — never a path. There is therefore no `PATH_MAX` ceiling on
/// depth, on component width, or on the total. Directories are entered with
/// `openat(…, O_DIRECTORY | O_NOFOLLOW)` and emptied post-order; entries are
/// destroyed with `unlinkat` against the descriptor of the directory that
/// contains them.
///
/// **Unbounded depth on a bounded descriptor budget.** The traversal keeps a
/// stack of frames but only the deepest `fdWindow` frames hold a live
/// descriptor; older ones are closed. Popping back to a closed ancestor
/// reopens it with `openat(child, "..")` — available precisely because the
/// child's descriptor is still held — and then PROVES it is the same
/// directory by comparing `(st_dev, st_ino)` against the identity recorded
/// when the frame was pushed. A mismatch (someone moved the tree mid-delete)
/// is a fail-closed error, never a deletion somewhere else.
///
/// ## Symlinks
///
/// A symlink is always removed AS a link and never followed (R4): entries
/// are classified from `d_type`/`fstatat(AT_SYMLINK_NOFOLLOW)`, only
/// directories are entered, and the entering `openat` carries `O_NOFOLLOW`
/// so a directory swapped for a symlink between `readdir` and `openat` fails
/// instead of escaping the tree.
///
/// ## Honest failure
///
/// Whatever cannot be finished — EACCES on an unwritable parent, EPERM on a
/// `uchg` entry, a concurrent recreate — is reported with the count of
/// entries this attempt DID destroy, so no surface can render a partial
/// destruction as "nothing was deleted". A benign ENOENT under the root (a
/// build removed the file while we walked) is not a failure and is not
/// counted; the removal root's OWN ENOENT still throws, preserving the
/// cleaner's frozen ghost-target asymmetry.
enum DeepRemover {

    /// Deepest simultaneously-held directory descriptors. Depth beyond this
    /// costs one extra `openat("..")` per level per pop and nothing else —
    /// the traversal never refuses for being deep.
    static let defaultFDWindow = 64

    // MARK: - Test seams (nil in production)

    /// Narrows the descriptor window so the ancestor-recovery path — which a
    /// production run only reaches past depth 64 — is reachable in a
    /// three-directory fixture. Never set outside tests.
    nonisolated(unsafe) static var fdWindowOverride: Int?

    /// Never below 2 — a window of 1 would close the descriptor the walk is
    /// standing on.
    static var fdWindow: Int { max(2, fdWindowOverride ?? defaultFDWindow) }

    /// Points in the walk a test can observe or perturb. `.entered` fires
    /// once per directory ENTERED (so a test can sample the process's REAL
    /// open-descriptor count from the kernel rather than trust a counter
    /// this file keeps about itself); `.willEnter` and `.willReopenAncestor`
    /// fire immediately before the two `openat` calls whose no-follow /
    /// identity checks exist for a race — the only way to drive that race on
    /// purpose.
    enum WalkEvent: Sendable, Equatable {
        case entered(depth: Int)
        case willEnter(name: String, depth: Int)
        case willReopenAncestor(depth: Int)
    }

    nonisolated(unsafe) static var testHook: (@Sendable (WalkEvent) -> Void)?

    /// A removal that could not be finished, carrying what it DESTROYED.
    ///
    /// `removedEntries` is the count of entries this attempt actually
    /// unlinked before it stopped. It is what makes the difference between
    /// "your tree is intact" and "part of your tree is gone" sayable at all.
    struct Failure: Error, LocalizedError, Sendable, Equatable {
        /// The removal root, as spelled by the caller.
        let target: String
        /// Path of the entry that failed, relative to `target`'s parent.
        let relativePath: String
        /// The syscall that refused (`open`, `read`, `unlink`, `rmdir`, …).
        let operation: String
        /// `errno` at the point of refusal.
        let code: Int32
        /// Entries this attempt destroyed before failing.
        let removedEntries: Int

        var reason: String { String(cString: strerror(code)) }

        var errorDescription: String? {
            let where_ = "\(operation) \(relativePath): \(reason)"
            guard removedEntries > 0 else {
                return "\(target) could not be removed — \(where_); "
                    + "nothing in this tree was removed"
            }
            let noun = removedEntries == 1 ? "entry" : "entries"
            return "\(target) was PARTIALLY REMOVED — \(removedEntries) "
                + "\(noun) were deleted before this failed and the rest are "
                + "still on disk — \(where_)"
        }
    }

    // MARK: - Entry point

    /// Remove `url` — a file, a symlink, or a whole directory tree — with
    /// every operation below the root anchored to a held descriptor.
    ///
    /// The root's PARENT is opened by path (it is the container the guard
    /// already admitted, and is therefore a path this process can express);
    /// nothing under it ever is.
    static func removeTree(at url: URL) throws {
        let leaf = url.lastPathComponent
        let parentPath = url.deletingLastPathComponent().path
        guard !leaf.isEmpty, leaf != "/", leaf != ".", leaf != ".." else {
            throw Failure(
                target: url.path, relativePath: leaf.isEmpty ? "/" : leaf,
                operation: "resolve", code: EINVAL, removedEntries: 0
            )
        }

        let parentFd = open(parentPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentFd >= 0 else {
            throw Failure(
                target: url.path, relativePath: parentPath,
                operation: "open", code: errno, removedEntries: 0
            )
        }
        defer { close(parentFd) }

        var info = stat()
        guard fstatat(parentFd, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw Failure(
                target: url.path, relativePath: leaf, operation: "stat",
                code: errno, removedEntries: 0
            )
        }

        // Not a directory (including a symlink TO one): the link itself goes.
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            guard unlinkat(parentFd, leaf, 0) == 0 else {
                throw Failure(
                    target: url.path, relativePath: leaf,
                    operation: "unlink", code: errno, removedEntries: 0
                )
            }
            return
        }

        let counter = Counter()
        try emptyTree(
            parentFd: parentFd, name: leaf, target: url.path, counter: counter
        )
        guard unlinkat(parentFd, leaf, AT_REMOVEDIR) == 0 else {
            throw Failure(
                target: url.path, relativePath: leaf, operation: "rmdir",
                code: errno, removedEntries: counter.value
            )
        }
    }

    // MARK: - Traversal

    /// Mutable count that survives a `throw` from any depth (an `inout` Int
    /// would not be readable by the thrower's caller).
    private final class Counter {
        var value = 0
    }

    private struct Entry {
        let name: String
        let isDirectory: Bool
    }

    private struct Frame {
        /// Live descriptor, or -1 once the window closed it.
        var fd: Int32
        /// This directory's name inside its parent.
        let name: String
        /// Identity recorded while the descriptor was held — the proof a
        /// reopened `..` is the same directory.
        let dev: dev_t
        let ino: ino_t
        var entries: [Entry]
        var index: Int
    }

    /// Empty (but do not remove) the directory `name` inside `parentFd`.
    private static func emptyTree(
        parentFd: Int32, name: String, target: String, counter: Counter
    ) throws {
        var stack: [Frame] = []
        defer { for frame in stack where frame.fd >= 0 { close(frame.fd) } }

        /// Path of `extra` (or of the current directory) relative to the
        /// removal root's parent — for messages only; never for syscalls.
        func relative(_ extra: String?) -> String {
            var parts = [name]
            parts.append(contentsOf: stack.dropFirst().map(\.name))
            if let extra { parts.append(extra) }
            return parts.joined(separator: "/")
        }
        func fail(_ operation: String, _ extra: String?, _ code: Int32) -> Failure {
            Failure(
                target: target, relativePath: relative(extra),
                operation: operation, code: code,
                removedEntries: counter.value
            )
        }

        let rootFd = openat(
            parentFd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootFd >= 0 else { throw fail("open", nil, errno) }
        var rootInfo = stat()
        guard fstat(rootFd, &rootInfo) == 0 else {
            let code = errno
            close(rootFd)
            throw fail("stat", nil, code)
        }
        do {
            stack.append(Frame(
                fd: rootFd, name: name, dev: rootInfo.st_dev,
                ino: rootInfo.st_ino, entries: try listEntries(fd: rootFd),
                index: 0
            ))
            testHook?(.entered(depth: 0))
        } catch let code as POSIXCode {
            close(rootFd)
            throw fail("read", nil, code.value)
        }

        while let top = stack.last {
            // Emptied — pop, then remove it from its parent.
            if top.index == top.entries.count {
                if stack.count == 1 {
                    close(top.fd)
                    stack.removeLast()
                    return
                }
                let parentIndex = stack.count - 2
                if stack[parentIndex].fd < 0 {
                    // The window closed this ancestor. Recover it THROUGH the
                    // child we still hold, and prove it is the same inode.
                    testHook?(.willReopenAncestor(depth: parentIndex))
                    let reopened = openat(
                        top.fd, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC
                    )
                    guard reopened >= 0 else { throw fail("open", "..", errno) }
                    var info = stat()
                    guard fstat(reopened, &info) == 0,
                          info.st_dev == stack[parentIndex].dev,
                          info.st_ino == stack[parentIndex].ino
                    else {
                        close(reopened)
                        throw fail("open", "..", ESTALE)
                    }
                    stack[parentIndex].fd = reopened
                }
                let parentFdNow = stack[parentIndex].fd
                let myName = top.name
                close(top.fd)
                stack.removeLast()
                if unlinkat(parentFdNow, myName, AT_REMOVEDIR) != 0 {
                    let code = errno
                    guard code == ENOENT else {
                        throw fail("rmdir", myName, code)
                    }
                    continue
                }
                counter.value += 1
                continue
            }

            let entry = top.entries[top.index]
            stack[stack.count - 1].index += 1

            guard entry.isDirectory else {
                if unlinkat(top.fd, entry.name, 0) != 0 {
                    let code = errno
                    // A build that removed its own file mid-walk is not a
                    // failure — the goal state holds.
                    guard code == ENOENT else {
                        throw fail("unlink", entry.name, code)
                    }
                    continue
                }
                counter.value += 1
                continue
            }

            // O_NOFOLLOW: a directory swapped for a symlink between the
            // `readdir` above and here fails instead of escaping the tree.
            testHook?(.willEnter(name: entry.name, depth: stack.count))
            let childFd = openat(
                top.fd, entry.name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard childFd >= 0 else {
                let code = errno
                guard code == ENOENT else {
                    throw fail("open", entry.name, code)
                }
                continue
            }
            var info = stat()
            guard fstat(childFd, &info) == 0 else {
                let code = errno
                close(childFd)
                throw fail("stat", entry.name, code)
            }
            let children: [Entry]
            do {
                children = try listEntries(fd: childFd)
            } catch let code as POSIXCode {
                close(childFd)
                throw fail("read", entry.name, code.value)
            }
            // Bound the descriptors held, NOT the depth walked.
            if stack.count >= fdWindow {
                let stale = stack.count - fdWindow
                if stack[stale].fd >= 0 {
                    close(stack[stale].fd)
                    stack[stale].fd = -1
                }
            }
            stack.append(Frame(
                fd: childFd, name: entry.name, dev: info.st_dev,
                ino: info.st_ino, entries: children, index: 0
            ))
            testHook?(.entered(depth: stack.count - 1))
        }
    }

    private struct POSIXCode: Error { let value: Int32 }

    /// Every entry of `fd`, read through a DUPLICATE descriptor so `fd`
    /// itself stays open for the `unlinkat`/`openat` calls that follow.
    /// Names are collected before anything is destroyed (what `fts` does) —
    /// `readdir` while unlinking from the same stream is unspecified.
    private static func listEntries(fd: Int32) throws -> [Entry] {
        let duplicated = dup(fd)
        guard duplicated >= 0 else { throw POSIXCode(value: errno) }
        guard let handle = fdopendir(duplicated) else {
            let code = errno
            close(duplicated)
            throw POSIXCode(value: code)
        }
        defer { closedir(handle) }
        rewinddir(handle)

        var entries: [Entry] = []
        while let raw = readdir(handle) {
            let name = withUnsafeBytes(of: raw.pointee.d_name) { buffer in
                String(cString: buffer.baseAddress!
                    .assumingMemoryBound(to: CChar.self))
            }
            guard name != ".", name != ".." else { continue }
            let isDirectory: Bool
            switch Int32(raw.pointee.d_type) {
            case DT_DIR:
                isDirectory = true
            case DT_UNKNOWN:
                // Filesystems that do not fill `d_type` (some network and
                // FUSE mounts) still get classified — no-follow, so a
                // symlink to a directory stays a symlink.
                var info = stat()
                isDirectory = fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0
                    && (info.st_mode & S_IFMT) == S_IFDIR
            default:
                isDirectory = false
            }
            entries.append(Entry(name: name, isDirectory: isDirectory))
        }
        return entries
    }
}
