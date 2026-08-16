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
        // A REAL volume may still be attached inside the fixture (the mount
        // cases below). `rm -rf` does NOT set `FTS_XDEV`, so it would happily
        // walk into a mounted volume and erase it — the very thing the code
        // under test refuses to do. Detach first, always, before deleting.
        for mounted in Self.mountPoints(under: base).sorted(by: >) {
            _ = Self.run("/usr/bin/hdiutil", ["detach", mounted, "-force"])
        }
        // `rm -rf` uses `fts`, i.e. relative traversal, so it can clean up
        // fixtures that `FileManager` cannot address.
        let rm = Process()
        rm.executableURL = URL(fileURLWithPath: "/bin/rm")
        rm.arguments = ["-rf", base.path]
        try? rm.run()
        rm.waitUntilExit()
    }

    // MARK: - Real-volume plumbing

    /// Every currently mounted filesystem whose mount point is at or below
    /// `url`, read from `getmntinfo(3)` — the kernel's own table, not a
    /// string guess.
    private static func mountPoints(under url: URL) -> [String] {
        // The kernel spells mount points canonically (`/private/var/...`);
        // `FileManager.temporaryDirectory` spells them through the `/var`
        // symlink, so an unresolved comparison silently finds NOTHING — and
        // this list is what keeps `rm -rf` out of an attached volume.
        let root = FileSystemIdentityProvider().realPath(of: url.path)
            ?? url.path
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        var found: [String] = []
        for index in 0..<Int(count) {
            var entry = buffer[index]
            let mountedOn = withUnsafeBytes(of: &entry.f_mntonname) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if mountedOn == root || mountedOn.hasPrefix(root + "/") {
                found.append(mountedOn)
            }
        }
        return found
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func inode(of url: URL) throws -> UInt64 {
        try XCTUnwrap(FileSystemIdentityProvider().identity(of: url)?.inode)
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
            at: target, expecting: nil, provider: FileSystemIdentityProvider()
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
            at: target, expecting: nil, provider: FileSystemIdentityProvider()
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
            at: target, expecting: nil, provider: FileSystemIdentityProvider()
        )
        XCTAssertFalse(exists(target))
        XCTAssertTrue(exists(outside), "the symlink's target directory lives")
        XCTAssertTrue(exists(precious), "and everything inside it")

        // The target ITSELF as a symlink: the link goes, the directory it
        // names does not.
        let linkTarget = base.appendingPathComponent("link-as-target")
        try fm.createSymbolicLink(at: linkTarget, withDestinationURL: outside)
        try DepthSafeRemoval.remove(
            at: linkTarget, expecting: nil, provider: FileSystemIdentityProvider()
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
            at: target, expecting: nil, provider: FileSystemIdentityProvider()
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
            at: target, expecting: nil, provider: FileSystemIdentityProvider()
        )
        XCTAssertFalse(exists(target))
    }

    /// An absent target is an ERROR, never a silent success — the frozen
    /// ghost asymmetry the cleaner's per-item error reporting rests on.
    func testAnAbsentTargetIsReportedNotSwallowed() {
        let ghost = base.appendingPathComponent("nope/never")
        XCTAssertThrowsError(
            try DepthSafeRemoval.remove(
                at: ghost, expecting: nil, provider: FileSystemIdentityProvider()
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
                    fsidMajor: real.fsidMajor &+ 1,
                    fsidMinor: real.fsidMinor,
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
            try DepthSafeRemoval.remove(at: target, expecting: nil, provider: provider)
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

    /// A volume mounted ON THE TARGET ITSELF refuses the deletion, with a
    /// REAL attached volume rather than an injected identity.
    ///
    /// The admission-time mount check (`PathGuard`) is a PATH check taken
    /// before the item is queued; this deletion runs later, on a background
    /// queue. A volume attached in between makes the target a mount root, and
    /// nothing the guard did earlier is still true. The proof has to be taken
    /// here, from the descriptor actually opened, against the parent
    /// descriptor held OUTSIDE it — a root that supplies its own reference
    /// point can never disagree with itself.
    func testRefusesADeletionRootThatBecameAMountedVolume() throws {
        let target = base.appendingPathComponent("attached-root")
        try mkdir(target)
        let image = base.appendingPathComponent("volume.dmg")
        guard Self.run("/usr/bin/hdiutil", [
            "create", "-size", "8m", "-fs", "APFS", "-volname",
            "CacheoutDepthSafe", "-type", "UDIF", "-quiet", image.path,
        ]) == 0 else { throw XCTSkip("hdiutil create unavailable") }
        guard Self.run("/usr/bin/hdiutil", [
            "attach", image.path, "-mountpoint", target.path,
            "-nobrowse", "-noverify", "-quiet",
        ]) == 0 else { throw XCTSkip("hdiutil attach unavailable") }
        defer {
            _ = Self.run("/usr/bin/hdiutil", ["detach", target.path, "-force"])
        }
        XCTAssertEqual(
            Self.mountPoints(under: target).count, 1,
            "fixture: the target must really be a mount root"
        )

        let precious = target.appendingPathComponent("precious.bin")
        try write(precious, bytes: 4096)
        let nested = target.appendingPathComponent("nested")
        try mkdir(nested)
        let deep = nested.appendingPathComponent("deep.bin")
        try write(deep, bytes: 4096)

        XCTAssertThrowsError(
            try DepthSafeRemoval.remove(
                at: target, expecting: nil, provider: FileSystemIdentityProvider()
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("mount boundary"),
                "the refusal must name the boundary: "
                    + error.localizedDescription
            )
        }
        XCTAssertTrue(exists(precious),
                      "a file at the mounted volume's root must survive")
        XCTAssertTrue(exists(deep),
                      "and so must everything below it")
    }

    /// The same refusal, hermetically: the ROOT's mount differs from the
    /// mount of the parent descriptor the removal already holds.
    ///
    /// This is the case a root-anchored comparison structurally cannot see —
    /// take the reference from the opened root and every descendant agrees
    /// with it by construction, so the boundary check answers a question
    /// about the mounted volume's INTERIOR while the volume itself is being
    /// emptied.
    func testRefusesADeletionRootWhoseMountDiffersFromTheHeldParent() throws {
        let target = base.appendingPathComponent("foreign-root")
        try mkdir(target)
        let precious = target.appendingPathComponent("volume-data.bin")
        try write(precious, bytes: 2048)
        let nested = target.appendingPathComponent("nested")
        try mkdir(nested)
        let deep = nested.appendingPathComponent("deep.bin")
        try write(deep, bytes: 2048)

        let provider = ForeignMountProvider()
        provider.foreignInode = try inode(of: target)

        XCTAssertThrowsError(
            try DepthSafeRemoval.remove(at: target, expecting: nil, provider: provider)
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("mount boundary"),
                "the refusal must name the boundary: "
                    + error.localizedDescription
            )
        }
        XCTAssertTrue(exists(precious),
                      "nothing on the other volume may be unlinked, and the "
                          + "root's own files are the FIRST thing an "
                          + "unguarded traversal unlinks")
        XCTAssertTrue(exists(deep))
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

    /// A directory relocated while the deletion stands BELOW it must STOP the
    /// deletion on the way back up, not redirect it.
    ///
    /// `openat(cur, "..")` names whatever the current directory's parent is
    /// NOW — it is a lookup, not a proof. The rename here moves a level the
    /// traversal has ALREADY entered and proven, while it is one level
    /// deeper still, so no check taken on the way DOWN can see it: the
    /// grandchild's own binding to its parent is untouched by the move. Only
    /// the ascent check catches it, and it must, because `..` then lands in
    /// somebody else's tree where the sibling names still pending from the
    /// REAL parent would be opened and emptied by name. The rename is a real
    /// `rename(2)`, fired at that exact instant; with the ascent identity
    /// check deleted this test loses `foreign/<sibling>/precious.bin`.
    func testRefusesWhenAnEnteredDirectoryIsRelocatedMidDeletion() throws {
        let target = base.appendingPathComponent("relocating-target")
        let parent = target.appendingPathComponent("a")
        let siblings = ["p", "q"].map { parent.appendingPathComponent($0) }
        for sibling in siblings {
            try mkdir(sibling.appendingPathComponent("inner"))
            try write(sibling.appendingPathComponent("inner/f.bin"))
        }
        let foreign = base.appendingPathComponent("foreign")
        try mkdir(foreign)

        // Keyed by the GRANDCHILD's inode: the rename fires when the
        // traversal is standing inside `inner`, i.e. after `p` itself has
        // been entered, proven and emptied.
        var byInnerInode: [UInt64: URL] = [:]
        for sibling in siblings {
            let inner = sibling.appendingPathComponent("inner")
            byInnerInode[try inode(of: inner)] = sibling
        }

        let provider = FirstDescentHook()
        provider.watched = Set(byInnerInode.keys)
        // The decoys are planted AT THE INSTANT of the rename, so the
        // fixture does not have to guess which sibling `readdir` hands back
        // first: whichever one the deletion entered is the one that moves,
        // and the OTHER name is the one still pending against the parent it
        // will fail to return to.
        provider.onFirstDescent = { inner in
            guard let moved = byInnerInode[inner] else { return }
            rename(moved.path, foreign.appendingPathComponent("moved").path)
            for (other, url) in byInnerInode where other != inner {
                let decoy = foreign.appendingPathComponent(url.lastPathComponent)
                try? self.mkdir(decoy)
                try? self.write(
                    decoy.appendingPathComponent("precious.bin"), bytes: 4096
                )
            }
        }

        XCTAssertThrowsError(
            try DepthSafeRemoval.remove(at: target, expecting: nil, provider: provider)
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("moved while it was"),
                "the refusal must name the relocation: "
                    + error.localizedDescription
            )
        }
        let fired = try XCTUnwrap(provider.firedFor,
                                  "the fixture never performed the rename")
        for (inner, url) in byInnerInode where inner != fired {
            XCTAssertTrue(
                exists(foreign.appendingPathComponent(
                    "\(url.lastPathComponent)/precious.bin"
                )),
                "content in the foreign parent must not be deleted by name"
            )
        }
    }

    /// A directory that left the held parent BEFORE it was emptied must not
    /// be emptied at all.
    ///
    /// The descriptor survives the `rename(2)` — that is what descriptors
    /// do — so the destructive pass runs happily inside a directory that now
    /// lives in somebody else's tree, unlinking whatever its new owner has
    /// put there. A check taken on the way back UP cannot help: by then the
    /// contents are gone. The binding has to be re-proven against the held
    /// parent BEFORE the first `unlinkat`, and the proof is containment —
    /// the child's `..` still resolving to the inode we are holding — not a
    /// path and not a recorded name.
    func testRefusesToEmptyAChildThatLeftTheHeldParentFirst() throws {
        let target = base.appendingPathComponent("escaping-child")
        let child = target.appendingPathComponent("c")
        try mkdir(child)
        try write(child.appendingPathComponent("own.bin"))
        let foreign = base.appendingPathComponent("foreign")
        try mkdir(foreign)
        let relocated = foreign.appendingPathComponent("moved")

        let provider = FirstDescentHook()
        provider.watched = [try inode(of: child)]
        // Real `rename(2)` at the instant the child is open and about to be
        // emptied, followed by the new owner writing into that location.
        provider.onFirstDescent = { _ in
            rename(child.path, relocated.path)
            try? self.write(
                relocated.appendingPathComponent("precious.bin"), bytes: 4096
            )
        }

        XCTAssertThrowsError(
            try DepthSafeRemoval.remove(at: target, expecting: nil, provider: provider)
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("moved while it was"),
                "the refusal must name the relocation: "
                    + error.localizedDescription
            )
        }
        XCTAssertNotNil(provider.firedFor,
                        "the fixture never performed the rename")
        XCTAssertTrue(
            exists(relocated.appendingPathComponent("precious.bin")),
            "content placed in the relocated directory belongs to its new "
                + "owner and must not be unlinked"
        )
    }

    /// The deletion ROOT is proven the same way, against the parent
    /// descriptor held since the first line.
    ///
    /// The target is opened by name in that parent and then, before anything
    /// is unlinked, several syscalls go by. A `rename(2)` in that window
    /// moves the whole deletion into a tree the user never selected, and the
    /// first thing an unproven traversal does there is empty the root — the
    /// deepest-reaching mistake this type could make, since the root is
    /// where the largest directories are.
    func testRefusesADeletionRootThatLeftItsParentBeforeTheDeletion() throws {
        let target = base.appendingPathComponent("escaping-root")
        try mkdir(target)
        try write(target.appendingPathComponent("own.bin"))
        let foreign = base.appendingPathComponent("foreign")
        try mkdir(foreign)
        let relocated = foreign.appendingPathComponent("moved")

        let provider = FirstDescentHook()
        provider.watched = [try inode(of: target)]
        provider.onFirstDescent = { _ in
            rename(target.path, relocated.path)
            try? self.write(
                relocated.appendingPathComponent("precious.bin"), bytes: 4096
            )
        }

        XCTAssertThrowsError(
            try DepthSafeRemoval.remove(at: target, expecting: nil, provider: provider)
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("moved while it was"),
                "the refusal must name the relocation: "
                    + error.localizedDescription
            )
        }
        XCTAssertNotNil(provider.firedFor,
                        "the fixture never performed the rename")
        XCTAssertTrue(
            exists(relocated.appendingPathComponent("precious.bin")),
            "content placed in the relocated root belongs to its new owner "
                + "and must not be unlinked"
        )
    }

    // MARK: - The inspection binding (PR #458 review — the P1)

    /// The verdict is a fact about an OBJECT, so the deletion proves the
    /// object — from the descriptor it opened, not from the path.
    ///
    /// A path re-resolved after the descriptor is held re-opens the race the
    /// descriptor closed; the cleaner's own pre-delete `lstat` is exactly
    /// that, and a swap landing between it and this `openat` beats it. Here
    /// the mismatch is stated directly instead of raced for: the caller
    /// inspected some other inode, so this tree is not the one it vetted.
    func testRefusesADeletionRootThatIsNotTheInspectedObject() throws {
        let target = base.appendingPathComponent("bound-target")
        try mkdir(target.appendingPathComponent("nested"))
        let precious = target.appendingPathComponent("nested/precious.bin")
        try write(precious, bytes: 4096)

        let elsewhere = FileSystemIdentityProvider.Identity(
            device: 0, inode: 0
        )
        XCTAssertThrowsError(
            try DepthSafeRemoval.remove(
                at: target, expecting: .directory(elsewhere),
                provider: FileSystemIdentityProvider()
            )
        ) { error in
            XCTAssertEqual(
                (error as? DepthSafeRemoval.Failure)?.cause,
                .notTheInspectedObject
            )
            XCTAssertTrue(
                error.localizedDescription
                    .contains("no longer the one that was inspected"),
                error.localizedDescription
            )
        }
        XCTAssertTrue(exists(precious),
                      "a tree nobody inspected must not lose one entry")

        // The positive control, so the guard is a proof and not a refusal
        // machine: bound to the object that IS there, the same call deletes.
        let identity = try XCTUnwrap(
            FileSystemIdentityProvider().identity(of: target)
        )
        try DepthSafeRemoval.remove(
            at: target, expecting: .directory(identity),
            provider: FileSystemIdentityProvider()
        )
        XCTAssertFalse(exists(target))
    }

    /// A verdict about a DIRECTORY is not satisfied by whatever leaf now
    /// stands at the name.
    ///
    /// The kind gate IS the open, so a swapped-in regular file arrives here
    /// as `ENOTDIR` on the leaf arm — where an unbound deletion would simply
    /// unlink it. It belongs to whoever put it there.
    func testRefusesALeafStandingWhereADirectoryWasInspected() throws {
        let target = base.appendingPathComponent("was-a-directory")
        try write(target, bytes: 128)

        let inspected = FileSystemIdentityProvider.Identity(
            device: 1, inode: 1
        )
        XCTAssertThrowsError(
            try DepthSafeRemoval.remove(
                at: target, expecting: .directory(inspected),
                provider: FileSystemIdentityProvider()
            )
        ) { error in
            XCTAssertEqual(
                (error as? DepthSafeRemoval.Failure)?.cause,
                .notTheInspectedObject
            )
        }
        XCTAssertTrue(exists(target), "the new owner's file survives")
    }

    /// The other arm of the same binding: a verdict of "there is no
    /// directory tree here" is voided by a directory appearing at the name.
    ///
    /// `.unestablished` — a probe that proved nothing — is refused on the
    /// same guard, because it is not a licence to delete anything.
    func testRefusesADirectoryStandingWhereNoTreeWasInspected() throws {
        let target = base.appendingPathComponent("appeared")
        try mkdir(target)
        let precious = target.appendingPathComponent("precious.bin")
        try write(precious, bytes: 4096)

        for verdict in [UserDataProbeResult.InspectedRoot.noDirectoryTree,
                        .unestablished] {
            XCTAssertThrowsError(
                try DepthSafeRemoval.remove(
                    at: target, expecting: verdict,
                    provider: FileSystemIdentityProvider()
                ), "\(verdict)"
            ) { error in
                XCTAssertEqual(
                    (error as? DepthSafeRemoval.Failure)?.cause,
                    .notTheInspectedObject, "\(verdict)"
                )
            }
            XCTAssertTrue(exists(precious), "\(verdict)")
        }

        // And the leaf arm's own positive control: a link, bound to the
        // verdict that is actually about it, is unlinked AS a link.
        let link = base.appendingPathComponent("linked")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        try DepthSafeRemoval.remove(
            at: link, expecting: .noDirectoryTree,
            provider: FileSystemIdentityProvider()
        )
        XCTAssertFalse(exists(link))
        XCTAssertTrue(exists(precious), "and never through it")
    }

    /// Only `ENOTDIR` means "this is a leaf". Every other open failure keeps
    /// its own errno instead of being re-answered by a syscall that was
    /// never asked the question.
    ///
    /// The kind gate being the open means the open's errno is now the KIND
    /// ANSWER, and exactly one code says "not a directory". Letting the rest
    /// fall through to the leaf `unlinkat` would report an unreadable
    /// directory as `EPERM` ("Operation not permitted", which is what
    /// `unlink` says about any directory) instead of `EACCES` ("Permission
    /// denied") — a remedy the user cannot act on, for a condition that is
    /// cleared by a `chmod`. Nothing is destroyed either way; the guard buys
    /// the honest sentence.
    func testAnOpenFailureThatIsNotENOTDIRKeepsItsOwnErrno() throws {
        let target = base.appendingPathComponent("unreadable-directory")
        try mkdir(target)
        try fm.setAttributes([.posixPermissions: 0o000],
                             ofItemAtPath: target.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755],
                                  ofItemAtPath: target.path)
        }
        let probe = target.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        if probe >= 0 {
            close(probe)
            throw XCTSkip("this process can open a 000 directory (root?)")
        }

        XCTAssertThrowsError(
            try DepthSafeRemoval.remove(
                at: target, expecting: nil,
                provider: FileSystemIdentityProvider()
            )
        ) { error in
            XCTAssertEqual(
                (error as? DepthSafeRemoval.Failure)?.cause, .posix(EACCES),
                "an unreadable directory is a permission problem, not "
                    + "'Operation not permitted': "
                    + error.localizedDescription
            )
        }
    }

    // MARK: - Unprovable location

    /// Blinds `mountIdentity(ofDescriptor:)` for ONE chosen inode — the
    /// descriptor-shaped way to ask what happens when the question cannot be
    /// answered at all (`fstatfs` failing on a held descriptor).
    private final class UnprovableMountProvider: FileSystemIdentityProvider {
        var blindInode: UInt64?

        override func mountIdentity(
            ofDescriptor descriptor: Int32
        ) -> MountIdentity? {
            if let blindInode,
               super.identity(ofDescriptor: descriptor)?.inode == blindInode {
                return nil
            }
            return super.mountIdentity(ofDescriptor: descriptor)
        }
    }

    /// Blinds `identity(ofDescriptor:)` for ONE chosen inode, after letting
    /// `answerFirst` questions about it through.
    ///
    /// The delay is what makes the LAST arm reachable: the traversal asks
    /// about the same inode twice per descent — once as the directory it is
    /// standing in, once as the `..` a containment proof lands on — and an
    /// `fstat` that worked a moment ago and fails now is exactly what an I/O
    /// error looks like.
    private final class UnprovableIdentityProvider: FileSystemIdentityProvider {
        var blindInode: UInt64?
        var answerFirst = 0
        private var seen = 0

        override func identity(ofDescriptor descriptor: Int32) -> Identity? {
            let real = super.identity(ofDescriptor: descriptor)
            guard let blindInode, real?.inode == blindInode else { return real }
            seen += 1
            return seen > answerFirst ? nil : real
        }
    }

    /// AN IDENTITY THAT CANNOT BE READ IS NOT A MATCH, at every place the
    /// traversal asks for one.
    ///
    /// Each of these arms guards a different question — the held parent's
    /// own identity, the identity a descent is about to be proven against,
    /// and the identity `..` landed on — and each of them decides whether a
    /// destructive pass runs. Answering "unreadable" with anything other
    /// than a refusal means unlinking by name inside a directory nobody can
    /// place. `fstat` failing on a held descriptor is rare, which is
    /// precisely why it needs a test rather than an assumption.
    func testRefusesWhenAnIdentityCannotBeRead() throws {
        // `answerFirst` selects WHICH arm fires; the fixture asserts the
        // content that arm is standing in front of.
        let cases: [(name: String, blind: String, answerFirst: Int, depth: Int)] = [
            ("the held parent's identity", "parent", 0, 0),
            ("the directory a descent is proven against", "target", 0, 0),
            ("the identity `..` landed on", "target", 1, 1),
        ]
        for (label, blind, answerFirst, depth) in cases {
            let target = base.appendingPathComponent("unreadable-\(label.hashValue)")
            let child = target.appendingPathComponent("child")
            try mkdir(child)
            let precious = child.appendingPathComponent("keep.bin")
            try write(precious, bytes: 2048)

            let provider = UnprovableIdentityProvider()
            provider.blindInode = try inode(of: blind == "parent" ? base : target)
            provider.answerFirst = answerFirst

            XCTAssertThrowsError(
                try DepthSafeRemoval.remove(
                    at: target, expecting: nil, provider: provider
                ), label
            ) { error in
                let failure = error as? DepthSafeRemoval.Failure
                XCTAssertEqual(failure?.cause, .unprovableLocation, label)
                XCTAssertEqual(failure?.depth, depth, label)
            }
            XCTAssertTrue(
                exists(precious),
                "\(label): a subtree whose location cannot be proven must "
                    + "not be emptied"
            )
        }
    }

    /// A mount question that cannot be answered REFUSES — on both sides of
    /// the root's comparison, and again at every child.
    ///
    /// The root's boundary proof is `parent == root`, and an unreadable
    /// answer on EITHER side leaves it unproven. Falling through to the
    /// comparison would then delete on a `nil == nil` agreement or on an
    /// arbitrary default — a mounted volume being emptied because the
    /// question about it errored is the worst possible reading of the R15
    /// doctrine. Unprovable ⇒ refused, nothing destroyed.
    func testRefusesWhenAMountIdentityCannotBeRead() throws {
        for blinded in ["parent", "root", "child"] {
            let target = base.appendingPathComponent("unprovable-\(blinded)")
            let nested = target.appendingPathComponent("nested")
            try mkdir(nested)
            let precious = nested.appendingPathComponent("keep.bin")
            try write(precious, bytes: 2048)

            let provider = UnprovableMountProvider()
            switch blinded {
            case "parent": provider.blindInode = try inode(of: base)
            case "root": provider.blindInode = try inode(of: target)
            default: provider.blindInode = try inode(of: nested)
            }

            XCTAssertThrowsError(
                try DepthSafeRemoval.remove(
                    at: target, expecting: nil, provider: provider
                ), blinded
            ) { error in
                XCTAssertEqual(
                    (error as? DepthSafeRemoval.Failure)?.cause,
                    .unprovableLocation, blinded
                )
                XCTAssertTrue(
                    error.localizedDescription
                        .contains("could not prove which volume"),
                    error.localizedDescription
                )
            }
            XCTAssertTrue(exists(precious),
                          "nothing may be unlinked on an unproven volume "
                              + "(\(blinded))")
        }
    }

    /// A containment proof whose `..` cannot be OPENED is a posix failure
    /// with its own code — not "unprovable", and not containment.
    ///
    /// The two are different remedies: `EACCES` here is cleared by a
    /// `chmod`, while `.unprovableLocation` tells the user nothing they can
    /// act on. Driven with a REAL `chmod(2)` on the held parent, fired at
    /// the instant the child is open and about to be proven — which is the
    /// only way this arm is reachable, since the same permission that stops
    /// `..` opening now would have stopped it a moment earlier.
    func testAContainmentProofThatCannotOpenDotDotKeepsItsErrno() throws {
        let target = base.appendingPathComponent("unopenable-parent")
        let child = target.appendingPathComponent("child")
        try mkdir(child)
        try write(child.appendingPathComponent("keep.bin"))
        let restore = { [fm] in
            try? fm.setAttributes([.posixPermissions: 0o755],
                                  ofItemAtPath: target.path)
        }
        defer { restore() }

        let provider = FirstDescentHook()
        provider.watched = [try inode(of: child)]
        provider.onFirstDescent = { [fm] _ in
            try? fm.setAttributes([.posixPermissions: 0o000],
                                  ofItemAtPath: target.path)
        }

        XCTAssertThrowsError(
            try DepthSafeRemoval.remove(
                at: target, expecting: nil, provider: provider
            )
        ) { error in
            let failure = error as? DepthSafeRemoval.Failure
            if failure?.cause == .posix(EPERM) || failure?.cause == nil {
                return XCTFail("unexpected: \(error)")
            }
            XCTAssertEqual(failure?.cause, .posix(EACCES),
                           error.localizedDescription)
        }
        XCTAssertNotNil(provider.firedFor, "the fixture never fired")
        restore()
        XCTAssertTrue(exists(child.appendingPathComponent("keep.bin")),
                      "an unproven child must not be emptied")
    }

    // MARK: - Residual #1, MEASURED

    /// THIS TEST PINS A RESIDUAL, NOT A GUARANTEE. It asserts what an
    /// ancestor relocation actually costs, because the header comment used
    /// to claim the exposure was "one directory's enumeration" and that is
    /// false.
    ///
    /// A `rename(2)` of a directory the traversal has already entered and
    /// proven leaves every proof BELOW it true — `..` from a child still
    /// names the relocated directory — so the traversal keeps going and
    /// keeps unlinking, at every depth, including entries the new owner
    /// writes there after the move. Measured here: a file the new owner puts
    /// one level down, another two levels down, and another in a sibling
    /// branch not yet visited are ALL destroyed. What bounds it is the
    /// unwind's `..` re-anchor, which refuses the moment the traversal tries
    /// to climb OUT of the relocated tree — so the damage stops at that
    /// subtree (a bystander elsewhere in the new parent survives), and the
    /// deletion fails `.relocated` rather than reporting success.
    ///
    /// POSIX has no primitive that closes this: a directory cannot be pinned
    /// to its parent for the duration of a read.
    func testAncestorRelocationDestroysTheNewOwnersWholeSubtree() throws {
        let target = base.appendingPathComponent("relocating-ancestor")
        let ancestor = target.appendingPathComponent("a")
        try mkdir(ancestor.appendingPathComponent("sub/deeper"))
        try mkdir(ancestor.appendingPathComponent("other"))
        let foreign = base.appendingPathComponent("new-owner")
        try mkdir(foreign.appendingPathComponent("bystander"))
        let bystander = foreign.appendingPathComponent("bystander/keep.bin")
        try write(bystander, bytes: 1024)
        let relocated = foreign.appendingPathComponent("moved")

        // Fired while the traversal stands INSIDE `a/sub` — i.e. after `a`
        // itself was entered and proven, which is the only way an ancestor
        // relocation gets past the descent-time containment proof.
        let planted = ["sub/one-level.bin", "sub/deeper/two-levels.bin",
                       "other/sibling-branch.bin"]
        /// What the fixture ACTUALLY created — a `XCTAssertFalse(exists:)`
        /// over a file that was never written passes for the wrong reason.
        var reallyPlanted: [String] = []
        let provider = FirstDescentHook()
        provider.watched = [try inode(of: ancestor.appendingPathComponent("sub"))]
        provider.onFirstDescent = { _ in
            guard rename(ancestor.path, relocated.path) == 0 else { return }
            // The new owner writes into the tree it now owns, at three
            // places the traversal has not looked at yet.
            for name in planted {
                let url = relocated.appendingPathComponent(name)
                guard (try? self.write(url)) != nil, self.exists(url) else {
                    continue
                }
                reallyPlanted.append(name)
            }
        }

        XCTAssertThrowsError(
            try DepthSafeRemoval.remove(
                at: target, expecting: nil, provider: provider
            )
        ) { error in
            XCTAssertEqual(
                (error as? DepthSafeRemoval.Failure)?.cause, .relocated,
                "the deletion must FAIL, never report success"
            )
        }
        XCTAssertNotNil(provider.firedFor,
                        "the fixture never performed the rename")

        XCTAssertEqual(reallyPlanted, planted,
                       "the fixture must really have written every file "
                           + "whose loss this test measures")

        // THE MEASURED BLAST RADIUS. Every one of these is the new owner's,
        // and every one of them is gone.
        for lost in planted {
            XCTAssertFalse(
                exists(relocated.appendingPathComponent(lost)),
                "residual understated: \(lost) survived, so the scope claim "
                    + "in the header is now too pessimistic — re-measure it"
            )
        }
        // AND THE BOUND. It is the relocated subtree, not the new parent.
        XCTAssertTrue(exists(bystander),
                      "the damage must not spread outside the tree that moved")
    }

    // MARK: - The enumeration handle

    /// Every entry name `fdopendir` hands back for the descriptor, sorted.
    /// The descriptor is CONSUMED, exactly as production consumes it.
    private func names(consuming descriptor: Int32) -> [String] {
        guard let stream = fdopendir(descriptor) else {
            close(descriptor)
            return ["<fdopendir failed: \(errno)>"]
        }
        defer { closedir(stream) }
        var found: [String] = []
        while let entry = readdir(stream) {
            var raw = entry.pointee.d_name
            let name = withUnsafeBytes(of: &raw) { bytes in
                String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
            }
            found.append(name)
        }
        return found.sorted()
    }

    /// The handle `fdopendir` consumes must be close-on-exec AND its own
    /// description — two properties `dup(2)` gives up, both of them silently.
    ///
    /// Close-on-exec because this process spawns children (`Process`) while
    /// permanent deletions run on a background queue, and an inherited
    /// directory handle keeps deleted objects alive for the child's
    /// lifetime. Own description because `dup` shares the FILE OFFSET with
    /// the descriptor the traversal keeps holding, so a second read of the
    /// same directory reports it EMPTY — the one answer a deleter must never
    /// be given wrongly. Asked of the kernel (`fcntl(F_GETFD)`, a real second
    /// `readdir` pass), not of the code under test.
    func testTheEnumerationHandleIsCloseOnExecAndSeparatelyPositioned() throws {
        let directory = base.appendingPathComponent("enumerable")
        try mkdir(directory)
        for index in 0..<3 {
            try write(directory.appendingPathComponent("f\(index).bin"))
        }
        let held = try openDirectory(directory)
        defer { close(held) }

        let first = DepthSafeRemoval.enumerationDescriptor(for: held)
        XCTAssertGreaterThanOrEqual(first, 0, "enumeration handle")
        XCTAssertEqual(
            fcntl(first, F_GETFD) & FD_CLOEXEC, FD_CLOEXEC,
            "the handle is inheritable by anything this process spawns"
        )
        let firstPass = names(consuming: first)
        XCTAssertEqual(
            firstPass, [".", "..", "f0.bin", "f1.bin", "f2.bin"],
            "fixture: the directory's real contents"
        )

        let second = DepthSafeRemoval.enumerationDescriptor(for: held)
        XCTAssertGreaterThanOrEqual(second, 0, "second enumeration handle")
        XCTAssertEqual(
            names(consuming: second), firstPass,
            "a second enumeration of the same held descriptor must see the "
                + "same directory, not an empty one"
        )
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
            at: target, expecting: nil, provider: FileSystemIdentityProvider()
        )
        XCTAssertFalse(exists(target))
        XCTAssertTrue(exists(base), "the parent above the target survives")
    }
}
