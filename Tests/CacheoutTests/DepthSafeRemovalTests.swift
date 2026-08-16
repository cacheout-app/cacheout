import XCTest
@testable import Cacheout

/// `DepthSafeRemoval` — the descriptor-relative deletion core.
///
/// Every case here runs against REAL syscalls on REAL trees. The over-
/// `PATH_MAX` fixtures cannot be built any other way: `mkdir` on an absolute
/// path returns `ENAMETOOLONG` long before the depths below, so they are
/// built with `mkdirat` against a held descriptor, one level at a time.
final class DepthSafeRemovalTests: XCTestCase {

    private let fm = FileManager.default
    private var base: URL!

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("DepthSafeRemoval-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        guard let base else { return }
        // `rm -rf` uses `fts`, i.e. relative traversal, so it can clean up
        // fixtures that `FileManager` cannot address.
        let rm = Process()
        rm.executableURL = URL(fileURLWithPath: "/bin/rm")
        rm.arguments = ["-rf", base.path]
        try? rm.run()
        rm.waitUntilExit()
    }

    // MARK: - Fixtures

    private func mkdir(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func write(_ url: URL, bytes: Int = 64) throws {
        try Data(repeating: 0xAB, count: bytes).write(to: url)
    }

    private func openDirectory(_ url: URL) throws -> Int32 {
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard fd >= 0 else { throw XCTSkip("open failed: \(errno)") }
        return fd
    }

    /// A chain of `levels` directories built with `mkdirat`, holding at most
    /// two descriptors at a time. Returns the deepest descriptor (owned by
    /// the caller) so a leaf file can be planted at the bottom.
    @discardableResult
    private func makeDeepChain(
        under root: URL, name: String, levels: Int
    ) throws -> Int32 {
        var current = try openDirectory(root)
        for _ in 0..<levels {
            guard mkdirat(current, name, 0o755) == 0 else {
                close(current)
                throw XCTSkip("mkdirat failed: \(errno)")
            }
            let next = openat(current, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            close(current)
            guard next >= 0 else { throw XCTSkip("openat failed: \(errno)") }
            current = next
        }
        return current
    }

    /// The absolute spelling of a chain's leaf, and whether the OS can open
    /// it — the fixture's own precondition, asserted rather than assumed.
    private func absolutePathIsUnaddressable(
        _ root: URL, name: String, levels: Int
    ) -> Bool {
        var path = root.path
        for _ in 0..<levels { path += "/" + name }
        let fd = path.withCString { open($0, O_RDONLY | O_DIRECTORY) }
        if fd >= 0 { close(fd); return false }
        return errno == ENAMETOOLONG
    }

    private func exists(_ url: URL) -> Bool {
        var st = stat()
        return url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return lstat(path, &st) == 0
        }
    }

    // MARK: - The class this type exists to close

    /// A tree deeper than `PATH_MAX` is REMOVED, not refused.
    ///
    /// `FileManager.removeItem(at:)` fails here with NSCocoaErrorDomain 514
    /// (underlying ENAMETOOLONG) in ~0.03 s, deterministically, forever —
    /// measured at 446 / 600 / 2000 / 4000 levels, the threshold being
    /// exactly `PATH_MAX`. `rm -rf` removes the identical tree, because
    /// `fts` traverses relatively. So does this.
    func testRemovesATreeDeeperThanAnAbsolutePathCanAddress() throws {
        let target = base.appendingPathComponent("deep-target")
        try mkdir(target)
        let levels = 600
        let deepest = try makeDeepChain(under: target, name: "d", levels: levels)
        // A real file at the bottom: emptying must reach it, not just rmdir
        // its way down a chain of empty directories.
        let leaf = openat(deepest, "payload.bin", O_CREAT | O_WRONLY, 0o644)
        XCTAssertGreaterThanOrEqual(leaf, 0, "fixture leaf file")
        if leaf >= 0 { close(leaf) }
        close(deepest)

        XCTAssertTrue(
            absolutePathIsUnaddressable(target, name: "d", levels: levels),
            "fixture is not actually past PATH_MAX"
        )
        // The retired primitive's verdict on this exact tree, pinned so the
        // test states what it is buying.
        XCTAssertThrowsError(try fm.removeItem(at: target)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, NSCocoaErrorDomain)
            XCTAssertEqual(nsError.code, 514)
        }

        try DepthSafeRemoval.remove(
            at: target, provider: FileSystemIdentityProvider()
        )
        XCTAssertFalse(exists(target),
                       "the whole tree must be gone, root included")
    }

    /// Depth is not a resource here: the traversal keeps ONE descriptor and
    /// climbs back with `openat(cur, "..")`, so a lowered process limit —
    /// what a launchd-spawned app actually sees — changes nothing.
    func testRemovesADeepTreeUnderALoweredDescriptorLimit() throws {
        let target = base.appendingPathComponent("fd-bound-target")
        try mkdir(target)
        let deepest = try makeDeepChain(under: target, name: "d", levels: 400)
        close(deepest)

        var original = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &original) == 0 else {
            throw XCTSkip("getrlimit failed")
        }
        var lowered = original
        lowered.rlim_cur = 96
        guard setrlimit(RLIMIT_NOFILE, &lowered) == 0 else {
            throw XCTSkip("setrlimit failed: \(errno)")
        }
        defer { setrlimit(RLIMIT_NOFILE, &original) }

        try DepthSafeRemoval.remove(
            at: target, provider: FileSystemIdentityProvider()
        )
        XCTAssertFalse(exists(target))
    }

    // MARK: - Semantics the path-based primitive had, kept

    /// A symlink is removed AS a link (R4) — never resolved, never followed
    /// into somebody else's tree, at either the target itself or anywhere
    /// below it.
    func testSymlinksAreUnlinkedAndNeverFollowed() throws {
        let outside = base.appendingPathComponent("outside")
        try mkdir(outside)
        let precious = outside.appendingPathComponent("precious.bin")
        try write(precious, bytes: 4096)

        let target = base.appendingPathComponent("linky")
        try mkdir(target.appendingPathComponent("nested"))
        try fm.createSymbolicLink(
            at: target.appendingPathComponent("nested/escape"),
            withDestinationURL: outside
        )
        try fm.createSymbolicLink(
            at: target.appendingPathComponent("file-link"),
            withDestinationURL: precious
        )

        try DepthSafeRemoval.remove(
            at: target, provider: FileSystemIdentityProvider()
        )
        XCTAssertFalse(exists(target))
        XCTAssertTrue(exists(outside), "the symlink's target directory lives")
        XCTAssertTrue(exists(precious), "and everything inside it")

        // The target ITSELF as a symlink: the link goes, the directory it
        // names does not.
        let linkTarget = base.appendingPathComponent("link-as-target")
        try fm.createSymbolicLink(at: linkTarget, withDestinationURL: outside)
        try DepthSafeRemoval.remove(
            at: linkTarget, provider: FileSystemIdentityProvider()
        )
        XCTAssertFalse(exists(linkTarget))
        XCTAssertTrue(exists(outside))
        XCTAssertTrue(exists(precious))
    }

    /// Names are handled as BYTES, not as `String`s composed into a `URL`.
    ///
    /// Two failure modes, one root: `d_name` is whatever the filesystem
    /// driver wrote. A repairing UTF-8 decode names a DIFFERENT entry — or
    /// none, leaving the directory permanently un-`rmdir`-able — and
    /// `URL.appendingPathComponent` percent-encodes, so a perfectly ordinary
    /// cache file called `50%25.bin` is silently missed by any implementation
    /// that composes paths instead of passing bytes to `unlinkat`.
    ///
    /// The hostile-but-LEGAL half always runs. The invalid-UTF-8 half needs a
    /// filesystem that will store one: APFS rejects the fixture outright
    /// (measured: `openat(O_CREAT)` → EILSEQ 92), so it skips there — the
    /// byte-exact handling stays correct-by-construction rather than
    /// evidenced, and this comment is the honest record of that.
    func testRemovesEntriesWhoseNamesAreHostileToPathComposition() throws {
        let target = base.appendingPathComponent("hostile-names")
        try mkdir(target)
        let hostile = [
            "50% off.bin", "a#b?c.bin", "colon:name.bin", "new\nline.bin",
            "back\\slash.bin", "café-NFD-e\u{0301}.bin", "..dots.bin",
        ]
        let targetFd = try openDirectory(target)
        defer { close(targetFd) }
        for name in hostile {
            let fd = openat(targetFd, name, O_CREAT | O_WRONLY, 0o644)
            guard fd >= 0 else {
                throw XCTSkip("fixture name rejected (\(name)): \(errno)")
            }
            close(fd)
        }
        guard mkdirat(targetFd, "sub dir%2F", 0o755) == 0 else {
            throw XCTSkip("mkdirat failed: \(errno)")
        }
        let nestedFd = openat(targetFd, "sub dir%2F", O_RDONLY | O_DIRECTORY)
        guard nestedFd >= 0 else { throw XCTSkip("openat failed: \(errno)") }
        let nested = openat(nestedFd, "50% off.bin", O_CREAT | O_WRONLY, 0o644)
        close(nested)
        close(nestedFd)

        try DepthSafeRemoval.remove(
            at: target, provider: FileSystemIdentityProvider()
        )
        XCTAssertFalse(exists(target),
                       "an entry the traversal could not name would leave the "
                           + "directory behind, un-rmdir-able")
    }

    /// The invalid-UTF-8 half, on a filesystem that will store one.
    func testRemovesEntriesWhoseNamesAreNotValidText() throws {
        let target = base.appendingPathComponent("undecodable")
        try mkdir(target)
        let targetFd = try openDirectory(target)
        defer { close(targetFd) }

        // 0xFF is not a legal UTF-8 byte anywhere.
        let rawFile: [CChar] = [0x62, -1, 0x62, 0]     // "b\xFFb"
        let rawDir: [CChar] = [0x64, -2, 0x64, 0]      // "d\xFEd"
        let fd = openat(targetFd, rawFile, O_CREAT | O_WRONLY, 0o644)
        guard fd >= 0 else {
            throw XCTSkip(
                "this filesystem refuses invalid-UTF-8 names (errno \(errno))"
            )
        }
        close(fd)
        guard mkdirat(targetFd, rawDir, 0o755) == 0 else {
            throw XCTSkip("mkdirat failed: \(errno)")
        }
        let nestedFd = openat(targetFd, rawDir, O_RDONLY | O_DIRECTORY)
        guard nestedFd >= 0 else { throw XCTSkip("openat failed: \(errno)") }
        let nestedFile = openat(nestedFd, rawFile, O_CREAT | O_WRONLY, 0o644)
        close(nestedFile)
        close(nestedFd)

        try DepthSafeRemoval.remove(
            at: target, provider: FileSystemIdentityProvider()
        )
        XCTAssertFalse(exists(target))
    }

    /// An absent target is an ERROR, never a silent success — the frozen
    /// ghost asymmetry the cleaner's per-item error reporting rests on.
    func testAnAbsentTargetIsReportedNotSwallowed() {
        let ghost = base.appendingPathComponent("nope/never")
        XCTAssertThrowsError(
            try DepthSafeRemoval.remove(
                at: ghost, provider: FileSystemIdentityProvider()
            )
        )
    }

    // MARK: - Mount doctrine (R15), enforced where the sizer cannot see

    /// A hermetic mount stand-in: `mountIdentity(ofDescriptor:)` reports a
    /// foreign filesystem id for ONE chosen inode. This is the
    /// descriptor-shaped injection the scanner's own mount tests use, and it
    /// cannot be defeated by path spelling.
    private final class ForeignMountProvider: FileSystemIdentityProvider {
        var foreignInode: UInt64?

        override func mountIdentity(
            ofDescriptor descriptor: Int32
        ) -> MountIdentity? {
            guard let real = super.mountIdentity(ofDescriptor: descriptor)
            else { return nil }
            if let foreignInode,
               super.identity(ofDescriptor: descriptor)?.inode == foreignInode {
                return MountIdentity(
                    filesystemID: (real.filesystemID.0 &+ 1, real.filesystemID.1),
                    device: real.device &+ 1
                )
            }
            return real
        }
    }

    /// A volume mounted BELOW the target refuses the deletion instead of
    /// recursing through it.
    ///
    /// The sizer already refuses boundary-bearing targets it can MEASURE.
    /// This is the same doctrine on the trees it cannot — which, since the
    /// deletion now reaches past `PATH_MAX` and the sizer does not, is
    /// precisely where the check would otherwise be missing.
    func testRefusesToDeleteThroughAMountBoundaryBelowTheTarget() throws {
        let target = base.appendingPathComponent("mount-parent")
        let mounted = target.appendingPathComponent("volume")
        try mkdir(mounted)
        let onVolume = mounted.appendingPathComponent("other-volume-data.bin")
        try write(onVolume, bytes: 2048)

        let provider = ForeignMountProvider()
        provider.foreignInode = FileSystemIdentityProvider()
            .identity(of: mounted)?.inode

        XCTAssertThrowsError(
            try DepthSafeRemoval.remove(at: target, provider: provider)
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("mounted inside"),
                "the refusal must name the boundary: "
                    + error.localizedDescription
            )
        }
        XCTAssertTrue(exists(onVolume),
                      "content on the other volume must be untouched")
    }

    // MARK: - `..` is a lookup, not a proof

    /// Fires a caller-supplied side effect the FIRST time the deletion opens
    /// one of the watched directories — i.e. while it is standing inside it,
    /// holding its descriptor. `mountIdentity(ofDescriptor:)` is called
    /// immediately after each child `openat`, which is exactly that instant.
    private final class FirstDescentHook: FileSystemIdentityProvider {
        var watched: Set<UInt64> = []
        var onFirstDescent: ((UInt64) -> Void)?
        private(set) var firedFor: UInt64?

        override func mountIdentity(
            ofDescriptor descriptor: Int32
        ) -> MountIdentity? {
            let result = super.mountIdentity(ofDescriptor: descriptor)
            if firedFor == nil,
               let inode = super.identity(ofDescriptor: descriptor)?.inode,
               watched.contains(inode) {
                firedFor = inode
                onFirstDescent?(inode)
            }
            return result
        }
    }

    /// A directory renamed into a FOREIGN parent while the deletion stands
    /// inside it must STOP the deletion, not redirect it.
    ///
    /// `openat(cur, "..")` names whatever the current directory's parent is
    /// NOW — it is a lookup, not a proof. Relocate the current directory and
    /// `..` lands in somebody else's tree, where the sibling names still
    /// pending from the REAL parent would then be opened and emptied by
    /// name. The rename below is a real `rename(2)`, fired at that exact
    /// instant; with the identity check deleted this test loses
    /// `foreign/<sibling>/precious.bin`.
    func testRefusesWhenTheCurrentDirectoryIsRelocatedMidDeletion() throws {
        let target = base.appendingPathComponent("relocating-target")
        let parent = target.appendingPathComponent("a")
        let siblings = ["p", "q"].map { parent.appendingPathComponent($0) }
        for sibling in siblings {
            try mkdir(sibling)
            try write(sibling.appendingPathComponent("f.bin"))
        }
        let foreign = base.appendingPathComponent("foreign")
        try mkdir(foreign)

        let real = FileSystemIdentityProvider()
        var byInode: [UInt64: URL] = [:]
        for sibling in siblings {
            byInode[try XCTUnwrap(real.identity(of: sibling)?.inode)] = sibling
        }

        let provider = FirstDescentHook()
        provider.watched = Set(byInode.keys)
        // The decoys are planted AT THE INSTANT of the rename, so the
        // fixture does not have to guess which sibling `readdir` hands back
        // first: whichever one the deletion entered is the one that moves,
        // and the OTHER name is the one still pending against the parent it
        // will fail to return to.
        provider.onFirstDescent = { inode in
            guard let moved = byInode[inode] else { return }
            rename(moved.path, foreign.appendingPathComponent("moved").path)
            for (other, url) in byInode where other != inode {
                let decoy = foreign.appendingPathComponent(url.lastPathComponent)
                try? self.mkdir(decoy)
                try? self.write(
                    decoy.appendingPathComponent("precious.bin"), bytes: 4096
                )
            }
        }

        XCTAssertThrowsError(
            try DepthSafeRemoval.remove(at: target, provider: provider)
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("moved while it was"),
                "the refusal must name the relocation: "
                    + error.localizedDescription
            )
        }
        let fired = try XCTUnwrap(provider.firedFor,
                                  "the fixture never performed the rename")
        for (inode, url) in byInode where inode != fired {
            XCTAssertTrue(
                exists(foreign.appendingPathComponent(
                    "\(url.lastPathComponent)/precious.bin"
                )),
                "content in the foreign parent must not be deleted by name"
            )
        }
    }

    // MARK: - Ordinary trees are still ordinary

    /// Wide, mixed, nested content: files, subdirectories, hardlinks and a
    /// fifo all go, and the parent above the target survives.
    func testRemovesAnOrdinaryMixedTreeAndLeavesItsParent() throws {
        let target = base.appendingPathComponent("ordinary")
        try mkdir(target.appendingPathComponent("one/two/three"))
        for index in 0..<200 {
            try write(target.appendingPathComponent("file-\(index).bin"))
        }
        try write(target.appendingPathComponent("one/a.bin"))
        try write(target.appendingPathComponent("one/two/b.bin"))
        try write(target.appendingPathComponent("one/two/three/c.bin"))
        try fm.linkItem(
            at: target.appendingPathComponent("one/a.bin"),
            to: target.appendingPathComponent("one/a-link.bin")
        )
        let fifo = target.appendingPathComponent("one/pipe")
        XCTAssertEqual(fifo.withUnsafeFileSystemRepresentation {
            mkfifo($0!, 0o644)
        }, 0, "fixture fifo")

        try DepthSafeRemoval.remove(
            at: target, provider: FileSystemIdentityProvider()
        )
        XCTAssertFalse(exists(target))
        XCTAssertTrue(exists(base), "the parent above the target survives")
    }
}
