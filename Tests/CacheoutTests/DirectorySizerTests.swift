import XCTest
import Darwin
@testable import Cacheout

/// Hermetic tests for `DirectorySizer` (fn-1.2, D2/D3/D6/D7/D8) and the
/// `CacheScanner` state derivation built on it (R6/R16/R19).
///
/// Every test runs against a UUID-derived fixture tree under the system temp
/// directory — zero reads of the real `$HOME`. Expected sizes are computed
/// INDEPENDENTLY of the sizer (raw `lstat` `st_blocks * 512`), never by
/// asking the code under test. chmod-000 fixtures restore 0755 before
/// teardown and skip under euid 0 (root ignores permission bits).
final class DirectorySizerTests: XCTestCase {

    private var base: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("DirectorySizerTests-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base {
            try? fm.removeItem(at: base)
        }
    }

    // MARK: - Helpers

    private func mkdir(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    private func writeFile(_ url: URL, bytes: Int = 4096) throws -> URL {
        try Data((0..<bytes).map { _ in UInt8.random(in: 0...255) })
            .write(to: url)
        return url
    }

    /// Independent fixture math: allocated size straight from `lstat`,
    /// bypassing everything the sizer uses.
    private func allocated(_ urls: URL...) -> Int64 {
        allocated(Array(urls))
    }

    private func allocated(_ urls: [URL]) -> Int64 {
        var total: Int64 = 0
        for url in urls {
            var st = stat()
            guard lstat(url.path, &st) == 0 else {
                XCTFail("lstat failed for fixture file \(url.path)")
                continue
            }
            total += Int64(st.st_blocks) * 512
        }
        return total
    }

    private func logicalSize(_ urls: [URL]) -> Int64 {
        var total: Int64 = 0
        for url in urls {
            var st = stat()
            guard lstat(url.path, &st) == 0 else { continue }
            total += Int64(st.st_size)
        }
        return total
    }

    private func chmod000(_ url: URL) throws {
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    }

    private func restorePerms(_ url: URL) {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func makeSizer(
        provider: FileSystemIdentityProvider = FileSystemIdentityProvider()
    ) -> DirectorySizer {
        DirectorySizer(provider: provider)
    }

    // MARK: - R2: bundles + hidden files + plain files, exact allocated total

    func testBundleHiddenAndPlainFixtureMeasuresExactAllocatedTotal() throws {
        let root = base.appendingPathComponent("caches")
        try mkdir(root)

        // Plain file, hidden file, file inside a .app bundle (D2: the old
        // .skipsPackageDescendants yielded the bundle as one 0-byte entry),
        // file inside a hidden directory (D3).
        let plain = try writeFile(root.appendingPathComponent("plain.bin"), bytes: 10_000)
        let hidden = try writeFile(root.appendingPathComponent(".hidden.bin"), bytes: 3_000)
        let bundleBin = root.appendingPathComponent("Fake.app/Contents/MacOS")
        try mkdir(bundleBin)
        let bundled = try writeFile(bundleBin.appendingPathComponent("fake"), bytes: 20_000)
        let hiddenDir = root.appendingPathComponent(".hiddendir")
        try mkdir(hiddenDir)
        let inner = try writeFile(hiddenDir.appendingPathComponent("inner.bin"), bytes: 5_000)

        let files = [plain, hidden, bundled, inner]
        let report = makeSizer().measure(at: root, mode: .scanRoot)

        XCTAssertEqual(report.exactAllocatedBytes, allocated(files),
                       "every regular file counts, hidden and bundled included")
        XCTAssertEqual(report.estimatedUpToBytes, 0, "no hardlinks in this fixture")
        XCTAssertEqual(report.logicalBytes, logicalSize(files))
        XCTAssertEqual(report.itemCount, files.count)
        XCTAssertTrue(report.denials.isEmpty)
        XCTAssertEqual(report.claims.count, files.count,
                       "every measured inode claims (R8)")
    }

    // MARK: - .deletionTarget leaf dispatch

    func testDeletionTargetSymlinkLeafIsZeroAndNeverWalked() throws {
        let target = base.appendingPathComponent("real-tree")
        try mkdir(target)
        try writeFile(target.appendingPathComponent("payload.bin"), bytes: 8_192)
        let link = base.appendingPathComponent("link-to-tree")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        let report = makeSizer().measure(at: link, mode: .deletionTarget)

        XCTAssertEqual(report.measuredBytes, 0, "a symlink deletion target is the link, not the tree")
        XCTAssertEqual(report.itemCount, 0)
        XCTAssertTrue(report.claims.isEmpty, "nothing behind the link may be claimed")
        XCTAssertTrue(report.denials.isEmpty)
    }

    func testDeletionTargetRegularFileMeasuresOwnAllocatedSize() throws {
        let file = try writeFile(base.appendingPathComponent("top-level.bin"), bytes: 12_288)

        let report = makeSizer().measure(at: file, mode: .deletionTarget)

        let expected = allocated(file)
        XCTAssertGreaterThan(expected, 0)
        XCTAssertEqual(report.exactAllocatedBytes, expected,
                       "regular-file target measures nonzero via independent fixture math")
        XCTAssertEqual(report.itemCount, 1)
        XCTAssertEqual(report.claims.count, 1)
    }

    func testDeletionTargetDirectoryIsEnumerated() throws {
        let dir = base.appendingPathComponent("dir-target")
        let nested = dir.appendingPathComponent("nested")
        try mkdir(nested)
        let a = try writeFile(dir.appendingPathComponent("a.bin"), bytes: 4_096)
        let c = try writeFile(nested.appendingPathComponent("c.bin"), bytes: 6_000)

        let report = makeSizer().measure(at: dir, mode: .deletionTarget)

        XCTAssertEqual(report.exactAllocatedBytes, allocated([a, c]))
        XCTAssertEqual(report.itemCount, 2)
    }

    /// Forces `.failed` lstat probes for exact paths.
    private final class FailingProbeProvider: FileSystemIdentityProvider {
        var failingPaths: Set<String> = []
        var failErrno: Int32 = EACCES

        override func probeKind(of url: URL) -> KindProbe {
            if failingPaths.contains(url.path) {
                return .failed(errno: failErrno)
            }
            return super.probeKind(of: url)
        }
    }

    func testDeletionTargetMetadataFailureIsRecordedDenial() throws {
        // A leaf that cannot even be lstat'ed is a classified denial, never
        // a silent zero (D6).
        let file = try writeFile(base.appendingPathComponent("unprobeable.bin"), bytes: 4_096)
        let provider = FailingProbeProvider()
        // .deletionTarget resolves ancestors first (/var/folders → /private/
        // var/folders), so the probe sees the RESOLVED spelling of the leaf.
        provider.failingPaths = [provider.resolveTargetKeepingLeaf(file).path]

        let report = makeSizer(provider: provider).measure(at: file, mode: .deletionTarget)

        XCTAssertEqual(report.measuredBytes, 0)
        XCTAssertEqual(report.denials.map(\.kind), [.permission])
        XCTAssertTrue(report.claims.isEmpty)
    }

    func testEnumeratedItemProbeFailureKeepsErrnoClassification() throws {
        // A walk item whose lstat fails must keep its errno classification
        // (EACCES → permission, EPERM → TCC), never collapse to a generic
        // metadata failure (D6/R6).
        let root = base.appendingPathComponent("classified-walk")
        try mkdir(root)
        let visible = try writeFile(root.appendingPathComponent("visible.bin"), bytes: 4_096)
        let blocked = try writeFile(root.appendingPathComponent("blocked.bin"), bytes: 8_192)

        let provider = FailingProbeProvider()
        // The enumerator yields canonical (/private-resolved) spellings.
        provider.failingPaths = [provider.canonicalize(blocked).path]

        provider.failErrno = EACCES
        let eaccesReport = makeSizer(provider: provider).measure(at: root, mode: .scanRoot)
        XCTAssertEqual(eaccesReport.denials.map(\.kind), [.permission])
        XCTAssertEqual(eaccesReport.exactAllocatedBytes, allocated(visible),
                       "the readable sibling still measures")

        provider.failErrno = EPERM
        let epermReport = makeSizer(provider: provider).measure(at: root, mode: .scanRoot)
        XCTAssertEqual(epermReport.denials.map(\.kind), [.tcc])
        XCTAssertEqual(epermReport.exactAllocatedBytes, allocated(visible))
    }

    func testDeletionTargetFifoIsZeroWithRecordedSkip() throws {
        let fifoURL = base.appendingPathComponent("pipe")
        guard mkfifo(fifoURL.path, 0o644) == 0 else {
            throw XCTSkip("mkfifo unavailable in this environment")
        }

        let report = makeSizer().measure(at: fifoURL, mode: .deletionTarget)

        XCTAssertEqual(report.measuredBytes, 0)
        XCTAssertEqual(report.itemCount, 0)
        XCTAssertEqual(report.skippedSpecialFiles.count, 1,
                       "an `other`-kind leaf is a recorded skip, not a silent zero")
        XCTAssertTrue(report.claims.isEmpty)
    }

    // MARK: - Hardlinks (D8 mitigation) + claims (R8)

    func testHardlinkedBytesAreEstimatedDedupedAndClaimedOnce() throws {
        let root = base.appendingPathComponent("hardlinks")
        try mkdir(root)
        let original = try writeFile(root.appendingPathComponent("a.bin"), bytes: 8_192)
        let link = root.appendingPathComponent("b.bin")
        try fm.linkItem(at: original, to: link)
        let unique = try writeFile(root.appendingPathComponent("unique.bin"), bytes: 4_096)

        let report = makeSizer().measure(at: root, mode: .scanRoot)

        XCTAssertEqual(report.exactAllocatedBytes, allocated(unique),
                       "hardlinked bytes never land in exact")
        XCTAssertEqual(report.estimatedUpToBytes, allocated(original),
                       "hardlinked inode counted ONCE, in estimatedUpToBytes")
        XCTAssertEqual(report.itemCount, 3, "three directory entries")
        XCTAssertEqual(report.claims.count, 2, "one claim per inode, never per link")

        let hardClaims = report.claims.filter { $0.observedHardlinked }
        XCTAssertEqual(hardClaims.count, 1)
        XCTAssertEqual(hardClaims.first?.canonicalByteSize, allocated(original))
    }

    func testUniqueFileEmitsClaimWithCanonicalByteSize() throws {
        // R8 baseline (review r9): acceptance transfers ONLY claimed bytes —
        // an unclaimed st_nlink == 1 file would report zero exact bytes after
        // its own successful deletion.
        let root = base.appendingPathComponent("unique-claim")
        try mkdir(root)
        let file = try writeFile(root.appendingPathComponent("only.bin"), bytes: 9_000)

        let report = makeSizer().measure(at: root, mode: .scanRoot)

        XCTAssertEqual(report.claims.count, 1)
        let claim = try XCTUnwrap(report.claims.first)
        XCTAssertFalse(claim.observedHardlinked)
        XCTAssertEqual(claim.canonicalByteSize, allocated(file))
        XCTAssertEqual(report.exactAllocatedBytes, allocated(file))
    }

    func testKnownInodeContributesZeroComponentsButStillClaims() throws {
        let root = base.appendingPathComponent("known-inodes")
        try mkdir(root)
        let known = try writeFile(root.appendingPathComponent("known.bin"), bytes: 8_192)
        let fresh = try writeFile(root.appendingPathComponent("fresh.bin"), bytes: 4_096)

        let sizer = makeSizer()
        let first = sizer.measure(at: root, mode: .scanRoot)
        let knownIdentity = try XCTUnwrap(
            first.claims.first { $0.canonicalByteSize == allocated(known) }?.identity
        )

        let second = sizer.measure(
            at: root, mode: .scanRoot, knownInodes: [knownIdentity]
        )

        XCTAssertEqual(second.exactAllocatedBytes, allocated(fresh),
                       "known-inode bytes locally excluded")
        XCTAssertEqual(second.claims.count, 2,
                       "the known inode STILL claims (R8: a failed sibling's bytes must remain transferable)")
        let knownClaim = second.claims.first { $0.identity == knownIdentity }
        XCTAssertEqual(knownClaim?.canonicalByteSize, allocated(known),
                       "claims carry the canonical value even when locally excluded")
    }

    // MARK: - Denials (D6, R6)

    func testDeniedRootIsDeniedNotEmpty() throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let denied = base.appendingPathComponent("denied-root")
        try mkdir(denied)
        try writeFile(denied.appendingPathComponent("invisible.bin"), bytes: 4_096)
        try chmod000(denied)
        defer { restorePerms(denied) }

        let report = makeSizer().measure(at: denied, mode: .scanRoot)

        XCTAssertEqual(report.measuredBytes, 0)
        XCTAssertFalse(report.denials.isEmpty,
                       "a denied root records a denial — never a silent (0,0)")
        XCTAssertEqual(report.denials.first?.kind, .permission)
    }

    func testEmptyDirectoryIsZeroWithNoDenials() throws {
        let empty = base.appendingPathComponent("empty")
        try mkdir(empty)

        let report = makeSizer().measure(at: empty, mode: .scanRoot)

        XCTAssertEqual(report.measuredBytes, 0)
        XCTAssertEqual(report.itemCount, 0)
        XCTAssertTrue(report.denials.isEmpty,
                       "0 + no denials is what distinguishes empty from denied")
    }

    func testPartiallyDeniedTreeMeasuresReadablePartAndRecordsDenial() throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let root = base.appendingPathComponent("partial")
        try mkdir(root)
        let ok = try writeFile(root.appendingPathComponent("ok.bin"), bytes: 4_096)
        let deniedSub = root.appendingPathComponent("locked")
        try mkdir(deniedSub)
        try writeFile(deniedSub.appendingPathComponent("hidden.bin"), bytes: 8_192)
        try chmod000(deniedSub)
        defer { restorePerms(deniedSub) }

        let report = makeSizer().measure(at: root, mode: .scanRoot)

        XCTAssertEqual(report.exactAllocatedBytes, allocated(ok),
                       "readable bytes still measured")
        XCTAssertFalse(report.denials.isEmpty)
        XCTAssertEqual(report.denials.first?.kind, .permission)
    }

    func testDenialClassificationEPERMIsTCCAndEACCESIsPermission() {
        let url = URL(fileURLWithPath: "/fixture/path")

        let eperm = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileReadNoPermission.rawValue,
            userInfo: [NSUnderlyingErrorKey: NSError(
                domain: NSPOSIXErrorDomain, code: Int(EPERM)
            )]
        )
        XCTAssertEqual(DirectorySizer.classifyDenial(eperm, at: url).kind, .tcc,
                       "EPERM under Cocoa 257 is a TCC denial")

        let eacces = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileReadNoPermission.rawValue,
            userInfo: [NSUnderlyingErrorKey: NSError(
                domain: NSPOSIXErrorDomain, code: Int(EACCES)
            )]
        )
        XCTAssertEqual(DirectorySizer.classifyDenial(eacces, at: url).kind, .permission,
                       "EACCES is a BSD permission denial")

        let bareCocoa = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileReadNoPermission.rawValue
        )
        XCTAssertEqual(DirectorySizer.classifyDenial(bareCocoa, at: url).kind, .permission)

        let unrelated = NSError(domain: "Fixture", code: 42)
        XCTAssertEqual(DirectorySizer.classifyDenial(unrelated, at: url).kind, .other)
    }

    // MARK: - Mount boundaries (R15)

    /// Remaps the device id of chosen inodes — hermetic foreign-volume cases.
    private final class DeviceRemappingProvider: FileSystemIdentityProvider {
        var deviceOverridesByInode: [UInt64: UInt64] = [:]

        override func identity(of url: URL) -> Identity? {
            guard let id = super.identity(of: url) else { return nil }
            if let device = deviceOverridesByInode[id.inode] {
                return Identity(device: device, inode: id.inode)
            }
            return id
        }
    }

    // MARK: - A path the sizer cannot address is its OWN denial kind

    /// The sizer walks by ABSOLUTE PATH, so a tree past `PATH_MAX` cannot be
    /// measured — and Foundation's error for it says "the file name "d" is
    /// invalid", which is false in a way that costs the user real time. The
    /// names are ordinary; the DEPTH is the problem, and no rename of "d"
    /// would ever help. Folded into `.other`, that sentence was what the
    /// sweep displayed as the reason. It is now its own class, with a detail
    /// that names the real cause and says what still works.
    func testAPathPastPathMaxDeniesWithItsRealCauseNotAnInvalidFileName() throws {
        let root = base.appendingPathComponent("past-path-max")
        try mkdir(root)
        // `FileManager` cannot address this tree either, so teardown needs
        // the relative-traversal tool.
        defer {
            let rm = Process()
            rm.executableURL = URL(fileURLWithPath: "/bin/rm")
            rm.arguments = ["-rf", root.path]
            try? rm.run()
            rm.waitUntilExit()
        }
        var current = root.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard current >= 0 else { throw XCTSkip("open failed: \(errno)") }
        for _ in 0..<600 {
            guard mkdirat(current, "d", 0o755) == 0 else {
                close(current)
                throw XCTSkip("mkdirat failed: \(errno)")
            }
            let next = openat(current, "d", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            close(current)
            guard next >= 0 else { throw XCTSkip("openat failed: \(errno)") }
            current = next
        }
        close(current)

        let report = DirectorySizer().measure(at: root, mode: .deletionTarget)
        XCTAssertEqual(report.denials.count, 1)
        let denial: SizeDenial = try XCTUnwrap(report.denials.first)
        XCTAssertEqual(denial.kind, SizeDenial.Kind.unaddressablePath)
        XCTAssertFalse(
            denial.detail.contains("invalid"),
            "the basename is innocent; blaming it sends the user after a "
                + "rename that cannot help: \(denial.detail)"
        )
        XCTAssertTrue(denial.detail.contains("deeper than an absolute path"),
                      denial.detail)
        // And the honest half: this is a SIZING limit only.
        XCTAssertTrue(denial.detail.contains("deletion is unaffected"),
                      denial.detail)
    }

    /// Replaces a named directory with a REAL self-referential symlink at the
    /// one instant the enumerator has yielded it and not yet opened it to
    /// descend — a `rename(2)` plus a `symlink(2)`, single-threaded, fired
    /// from the production sizer's own per-entry `probeKind`. No sleeps, no
    /// threads: the kernel decides what the enumerator sees next.
    private final class SwapDirectoryForASymlinkCycleProvider:
        FileSystemIdentityProvider {
        var trigger = ""
        private(set) var fired = false
        override func probeKind(of url: URL) -> KindProbe {
            let answer = super.probeKind(of: url)
            guard !fired, url.lastPathComponent == trigger else { return answer }
            fired = true
            let path = url.path
            _ = rename(path, path + ".moved")
            _ = symlink(url.lastPathComponent, path)
            return answer
        }
    }

    /// `ELOOP` IS NOT `ENAMETOOLONG` (PR #458 review r11, thread
    /// `PRRT_kwDORmg6_86Zn1Ph`).
    ///
    /// One `SizeDenial.Kind` covers both — the remedy class really is shared,
    /// restructure the path — but the SENTENCE was written for one of them.
    /// Measured before the split: a symlink cycle 60 bytes deep was reported
    /// as "this folder runs deeper than an absolute path can address
    /// (1024-byte limit) … deletion is unaffected". The length claim is false,
    /// the `PATH_MAX` number is irrelevant, and the deletion promise is
    /// unearned — `DepthSafeRemoval` resolves exactly one path, the target's
    /// parent, and a cycle ABOVE the target fails it with the same errno 62
    /// (measured: `remove` threw `posix(62)`).
    func testASymlinkCycleIsNotReportedAsAPathLengthOverflow() throws {
        let root = base.appendingPathComponent("cycle-root")
        let victim = root.appendingPathComponent("A")
        try mkdir(victim)
        try writeFile(victim.appendingPathComponent("payload.bin"))

        let provider = SwapDirectoryForASymlinkCycleProvider()
        provider.trigger = "A"
        let report = DirectorySizer(provider: provider)
            .measure(at: root, mode: .deletionTarget)

        XCTAssertTrue(provider.fired, "the fixture never armed the swap")
        // The fixture really does produce ELOOP, at a SHORT path.
        var st = stat()
        XCTAssertEqual(stat(victim.path, &st), -1)
        XCTAssertEqual(errno, ELOOP,
                       "the fixture must really produce ELOOP on this platform")
        XCTAssertLessThan(victim.path.utf8.count, Int(PATH_MAX),
                          "the fixture's path must be nowhere near PATH_MAX")

        let denial: SizeDenial = try XCTUnwrap(report.denials.first)
        XCTAssertEqual(report.denials.count, 1)
        XCTAssertEqual(denial.kind, SizeDenial.Kind.unaddressablePath,
                       "the remedy class is shared — restructure the path")
        XCTAssertTrue(
            denial.detail.contains("too many links"),
            "the detail must name symbolic-link resolution: \(denial.detail)"
        )
        XCTAssertFalse(
            denial.detail.contains("absolute path can address"),
            "blaming path LENGTH for a symlink cycle sends the user after a "
                + "shortening that cannot help: \(denial.detail)"
        )
        XCTAssertFalse(
            denial.detail.contains("\(PATH_MAX)"),
            "a byte limit is not what was hit: \(denial.detail)"
        )
        XCTAssertFalse(
            denial.detail.contains("deletion is unaffected"),
            "this errno does not say WHERE the cycle is, and a cycle above "
                + "the target defeats the one path the removal resolves: "
                + "\(denial.detail)"
        )
    }

    /// The measured half of that last claim, so the refusal to promise is
    /// evidenced rather than asserted: a cycle in an ANCESTOR really does
    /// defeat `DepthSafeRemoval`, which resolves the target's parent by path.
    func testACycleAboveTheTargetDefeatsTheRemovalsOneResolvedPath() throws {
        let anchor = base.appendingPathComponent("anchor")
        let target = anchor.appendingPathComponent("entry")
        try mkdir(target)
        try writeFile(target.appendingPathComponent("payload.bin"))
        // m0 -> m1 -> … -> m39 -> anchor: past SYMLOOP_MAX, no cycle needed.
        XCTAssertEqual(
            symlink("anchor", base.appendingPathComponent("m39").path), 0
        )
        for index in stride(from: 38, through: 0, by: -1) {
            XCTAssertEqual(
                symlink("m\(index + 1)",
                        base.appendingPathComponent("m\(index)").path), 0
            )
        }
        let spelled = base.appendingPathComponent("m0/entry")

        var st = stat()
        XCTAssertEqual(stat(spelled.path, &st), -1)
        XCTAssertEqual(errno, ELOOP)

        XCTAssertThrowsError(
            try DepthSafeRemoval.remove(
                at: spelled, expecting: nil,
                provider: FileSystemIdentityProvider(),
                containedIn: .unbound
            )
        ) { error in
            guard let failure = error as? DepthSafeRemoval.Failure else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(failure.cause, .posix(ELOOP),
                           "the removal's one resolved path is the target's "
                               + "PARENT, and the cycle is above it")
        }
        XCTAssertTrue(fm.fileExists(atPath: target.path),
                      "nothing may be destroyed on a refused removal")
    }

    /// Marks chosen inodes as mount points while keeping real devices —
    /// hermetic stand-in for the same-st_dev APFS firmlink mount.
    private final class MountPointInjectingProvider: FileSystemIdentityProvider {
        var mountPointInodes: Set<UInt64> = []

        override func isMountPoint(_ url: URL) -> Bool {
            if let id = identity(of: url), mountPointInodes.contains(id.inode) {
                return true
            }
            return super.isMountPoint(url)
        }
    }

    func testForeignDeviceSubtreeIsRecordedAndNotCounted() throws {
        let root = base.appendingPathComponent("mounts")
        try mkdir(root)
        let local = try writeFile(root.appendingPathComponent("local.bin"), bytes: 4_096)
        let foreign = root.appendingPathComponent("foreign-volume")
        try mkdir(foreign)
        try writeFile(foreign.appendingPathComponent("foreign.bin"), bytes: 8_192)

        let provider = DeviceRemappingProvider()
        let foreignInode = try XCTUnwrap(provider.identity(of: foreign)?.inode)
        provider.deviceOverridesByInode[foreignInode] = 0xDEAD_BEEF

        let report = makeSizer(provider: provider).measure(at: root, mode: .scanRoot)

        XCTAssertEqual(report.mountBoundaries.count, 1, "boundary recorded")
        XCTAssertEqual(report.mountBoundaries.first?.lastPathComponent, "foreign-volume")
        XCTAssertEqual(report.exactAllocatedBytes, allocated(local),
                       "foreign subtree not entered, not counted")
        XCTAssertEqual(report.itemCount, 1)
    }

    func testSameDeviceMountPointIsStillABoundary() throws {
        // A unified APFS volume group presents ONE st_dev across the
        // system/Data pair — device comparison alone misses the firmlink.
        let root = base.appendingPathComponent("firmlink")
        try mkdir(root)
        let local = try writeFile(root.appendingPathComponent("local.bin"), bytes: 4_096)
        let firmlinked = root.appendingPathComponent("data-volume")
        try mkdir(firmlinked)
        try writeFile(firmlinked.appendingPathComponent("beyond.bin"), bytes: 8_192)

        let provider = MountPointInjectingProvider()
        let inode = try XCTUnwrap(provider.identity(of: firmlinked)?.inode)
        provider.mountPointInodes.insert(inode)

        let report = makeSizer(provider: provider).measure(at: root, mode: .scanRoot)

        XCTAssertEqual(report.mountBoundaries.count, 1,
                       "isMountPoint alone must trigger the boundary")
        XCTAssertEqual(report.exactAllocatedBytes, allocated(local))
        XCTAssertEqual(report.itemCount, 1)
    }

    func testDeletionTargetThatIsAMountPointIsABoundaryNotAWalk() throws {
        // The within-walk check only sees entries the enumerator yields — a
        // mount-point directory handed DIRECTLY to measure must be refused at
        // the root, or the cleaner would delete through it (R15).
        let target = base.appendingPathComponent("mounted-target")
        try mkdir(target)
        try writeFile(target.appendingPathComponent("payload.bin"), bytes: 8_192)

        let provider = MountPointInjectingProvider()
        let inode = try XCTUnwrap(provider.identity(of: target)?.inode)
        provider.mountPointInodes.insert(inode)

        let report = makeSizer(provider: provider)
            .measure(at: target, mode: .deletionTarget)

        XCTAssertTrue(report.rootMountBoundary)
        XCTAssertEqual(report.mountBoundaries.count, 1)
        XCTAssertEqual(report.measuredBytes, 0, "payload beneath never counted")
        XCTAssertEqual(report.itemCount, 0, "tree never enumerated")
        XCTAssertTrue(report.claims.isEmpty, "nothing claimable behind a boundary")
    }

    func testDeletionTargetOnForeignDeviceIsABoundaryNotAWalk() throws {
        // Same rule via the OTHER signal: the target's device differs from
        // its parent's (a real mounted volume, not a firmlink).
        let target = base.appendingPathComponent("foreign-target")
        try mkdir(target)
        try writeFile(target.appendingPathComponent("payload.bin"), bytes: 8_192)

        let provider = DeviceRemappingProvider()
        let inode = try XCTUnwrap(provider.identity(of: target)?.inode)
        provider.deviceOverridesByInode[inode] = 0xDEAD_BEEF

        let report = makeSizer(provider: provider)
            .measure(at: target, mode: .deletionTarget)

        XCTAssertTrue(report.rootMountBoundary)
        XCTAssertEqual(report.measuredBytes, 0)
        XCTAssertEqual(report.itemCount, 0)
    }

    /// Mirrors the PRODUCTION `isMountPoint` contract — true only for the
    /// CANONICAL spelling, exactly as `statfs` compares `f_mntonname` — and
    /// records every spelling the sizer hands it.
    private final class CanonicalSpellingMountProvider:
        FileSystemIdentityProvider
    {
        var canonicalMountPaths: Set<String> = []
        private(set) var mountCheckedPaths: [String] = []

        override func isMountPoint(_ url: URL) -> Bool {
            mountCheckedPaths.append(url.path)
            if canonicalMountPaths.contains(url.path) { return true }
            return super.isMountPoint(url)
        }
    }

    func testSizerAlwaysHandsTheMountCheckACanonicalSpelling() throws {
        // The AUDIT cell for PR #457 review r4, which fixed three callers that
        // handed `isMountPoint` an aliased spelling. The sizer was judged
        // correct BY READING (`.scanRoot` canonicalizes, `.deletionTarget`
        // target-resolves, and the enumerator's children are rooted at that
        // resolved root) — this proves it instead, in both modes, through a
        // request whose ancestor really is a symlink.
        let real = base.appendingPathComponent("real")
        try mkdir(real.appendingPathComponent("tree/sub"))
        let alias = base.appendingPathComponent("aliaslink")
        try fm.createSymbolicLink(at: alias, withDestinationURL: real)
        let requested = alias.appendingPathComponent("tree")
        try writeFile(requested.appendingPathComponent("sub/payload.bin"),
                      bytes: 4_096)
        // The BOUNDARY is declared by its canonical spelling only — the shape
        // the three fixed callers were blind to.
        let canonicalSub = FileSystemIdentityProvider()
            .canonicalize(requested.appendingPathComponent("sub")).path
        XCTAssertNotEqual(canonicalSub,
                          requested.appendingPathComponent("sub").path,
                          "the fixture must really be aliased")

        for mode in [DirectorySizer.Mode.scanRoot, .deletionTarget] {
            let provider = CanonicalSpellingMountProvider()
            provider.canonicalMountPaths = [canonicalSub]

            let report = makeSizer(provider: provider)
                .measure(at: requested, mode: mode)

            XCTAssertEqual(
                report.mountBoundaries.map(\.lastPathComponent), ["sub"],
                "\(mode): the boundary is seen through the alias, so every "
                    + "path this walk hands the check is already canonical"
            )
            XCTAssertEqual(report.itemCount, 0, "\(mode): subtree not counted")
            XCTAssertFalse(
                provider.mountCheckedPaths.contains {
                    $0 == requested.path || $0.hasPrefix(requested.path + "/")
                },
                "\(mode): not one ALIASED spelling reaches the check: "
                    + "\(provider.mountCheckedPaths)"
            )
        }
    }
}

/// `CacheScanner` scan-time admission + `ScanResult` state derivation
/// (fn-1.2 model + derivation; R6/R16/R19).
final class CacheScannerDerivationTests: XCTestCase {

    private var base: URL!
    private var fixtureHome: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("CacheScannerDerivationTests-\(UUID().uuidString)")
        fixtureHome = base.appendingPathComponent("home")
        try fm.createDirectory(at: fixtureHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base {
            try? fm.removeItem(at: base)
        }
    }

    // MARK: - Helpers

    private func mkdir(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    private func writeFile(_ url: URL, bytes: Int = 4_096) throws -> URL {
        try Data((0..<bytes).map { _ in UInt8.random(in: 0...255) })
            .write(to: url)
        return url
    }

    private func allocated(_ urls: URL...) -> Int64 {
        var total: Int64 = 0
        for url in urls {
            var st = stat()
            guard lstat(url.path, &st) == 0 else {
                XCTFail("lstat failed for fixture file \(url.path)")
                continue
            }
            total += Int64(st.st_blocks) * 512
        }
        return total
    }

    private func makeScanner() -> CacheScanner {
        CacheScanner(home: fixtureHome)
    }

    private func makeCategory(at url: URL, name: String = "fixture-cache") -> CacheCategory {
        CacheCategory(
            name: name, slug: name, description: "test", icon: "trash",
            discovery: [.absolutePath(url.path)],
            riskLevel: .safe, rebuildNote: "", defaultSelected: true
        )
    }

    // MARK: - Derivation

    func testMeasuredStateWithComponentsAndCompatibilitySum() async throws {
        let dir = base.appendingPathComponent("measured")
        try mkdir(dir)
        let plain = try writeFile(dir.appendingPathComponent("plain.bin"), bytes: 6_000)
        let hidden = try writeFile(dir.appendingPathComponent(".hidden.bin"), bytes: 2_000)

        let result = await makeScanner().scanCategory(makeCategory(at: dir))

        XCTAssertEqual(result.state, .measured)
        XCTAssertNil(result.scanError)
        XCTAssertEqual(result.exactBytes, allocated(plain, hidden))
        XCTAssertEqual(result.estimatedUpToBytes, 0)
        XCTAssertEqual(result.sizeBytes, result.exactBytes + result.estimatedUpToBytes,
                       "sizeBytes is the compatibility component sum")
        XCTAssertTrue(result.exists)
    }

    func testHardlinkedCategorySplitsComponents() async throws {
        let dir = base.appendingPathComponent("hardlinked")
        try mkdir(dir)
        let original = try writeFile(dir.appendingPathComponent("a.bin"), bytes: 8_192)
        try fm.linkItem(at: original, to: dir.appendingPathComponent("b.bin"))
        let unique = try writeFile(dir.appendingPathComponent("c.bin"), bytes: 4_096)

        let result = await makeScanner().scanCategory(makeCategory(at: dir))

        XCTAssertEqual(result.exactBytes, allocated(unique))
        XCTAssertEqual(result.estimatedUpToBytes, allocated(original))
        XCTAssertEqual(result.sizeBytes, result.exactBytes + result.estimatedUpToBytes)
    }

    func testEmptyStateHasNoError() async throws {
        let dir = base.appendingPathComponent("empty")
        try mkdir(dir)

        let result = await makeScanner().scanCategory(makeCategory(at: dir))

        XCTAssertEqual(result.state, .empty)
        XCTAssertNil(result.scanError, "empty is a clean state, never an error")
        XCTAssertEqual(result.sizeBytes, 0)
        XCTAssertTrue(result.exists)
    }

    func testMissingStateWhenNoPathResolves() async throws {
        let absent = base.appendingPathComponent("does-not-exist")

        let result = await makeScanner().scanCategory(makeCategory(at: absent))

        XCTAssertEqual(result.state, .missing)
        XCTAssertNil(result.scanError)
        XCTAssertFalse(result.exists)
    }

    func testDeniedRootDerivesDeniedStateWithClassifiedError() async throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let dir = base.appendingPathComponent("denied")
        try mkdir(dir)
        try writeFile(dir.appendingPathComponent("invisible.bin"), bytes: 4_096)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        }

        let result = await makeScanner().scanCategory(makeCategory(at: dir))

        XCTAssertEqual(result.state, .denied, "chmod-000 root is denied, NOT empty")
        let scanError = try XCTUnwrap(result.scanError)
        XCTAssertEqual(scanError.kind, .permissionDenied)
        XCTAssertEqual(result.sizeBytes, 0)
    }

    func testPartiallyDeniedKeepsMeasuredBytes() async throws {
        try XCTSkipIf(geteuid() == 0, "root ignores permission bits")
        let dir = base.appendingPathComponent("partial")
        try mkdir(dir)
        let ok = try writeFile(dir.appendingPathComponent("ok.bin"), bytes: 4_096)
        let locked = dir.appendingPathComponent("locked")
        try mkdir(locked)
        try writeFile(locked.appendingPathComponent("hidden.bin"), bytes: 8_192)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }

        let result = await makeScanner().scanCategory(makeCategory(at: dir))

        XCTAssertEqual(result.state, .partiallyDenied)
        XCTAssertNotNil(result.scanError)
        XCTAssertEqual(result.sizeBytes, allocated(ok),
                       "partial denial keeps the measured bytes")
    }

    // MARK: - Scan-time admission (R19)

    func testInadmissibleProbeRootIsNeverEnumerated() async throws {
        // Probe stdout is untrusted: a probed category whose command emits a
        // path matching NO declared fallback must be refused at admission —
        // the tree is never walked, the refusal is the scan error.
        let escape = base.appendingPathComponent("escape-tree")
        try mkdir(escape)
        try writeFile(escape.appendingPathComponent("loot.bin"), bytes: 16_384)

        let category = CacheCategory(
            name: "probed-escape", slug: "probed-escape",
            description: "test", icon: "trash",
            discovery: [.probed(
                command: "echo '\(escape.path)'",
                requiresTool: nil,
                fallbacks: []
            )],
            riskLevel: .safe, rebuildNote: "", defaultSelected: true
        )

        let result = await makeScanner().scanCategory(category)

        XCTAssertEqual(result.state, .denied)
        let scanError = try XCTUnwrap(result.scanError, "refusal must surface as a scan error")
        XCTAssertEqual(scanError.kind, .admissionRefused)
        XCTAssertEqual(result.sizeBytes, 0,
                       "no byte of the refused tree may have been measured")
        XCTAssertEqual(result.itemCount, 0)
    }

    // MARK: - Injected-home path resolution (hermetic seam)

    func testStaticPathResolvesAndAdmitsUnderInjectedHome() async throws {
        // Discovery must anchor to the INJECTED home, not the real account
        // home — otherwise a `.staticPath` category under a fixture home is
        // reported `.missing` (or the real home's tree is refused against a
        // policy rooted at the fixture home), defeating the hermetic seam.
        let cacheDir = fixtureHome
            .appendingPathComponent("Library/Caches/fixture-static")
        try mkdir(cacheDir)
        let payload = try writeFile(
            cacheDir.appendingPathComponent("payload.bin"), bytes: 6_000
        )

        let category = CacheCategory(
            name: "static-under-home", slug: "static-under-home",
            description: "test", icon: "trash",
            discovery: [.staticPath("Library/Caches/fixture-static")],
            riskLevel: .safe, rebuildNote: "", defaultSelected: true
        )

        let result = await makeScanner().scanCategory(category)

        XCTAssertEqual(
            result.state, .measured,
            "static path must resolve AND admit under the injected home — "
            + "got \(result.state) (\(String(describing: result.scanError)))"
        )
        XCTAssertEqual(result.exactBytes, allocated(payload))
    }

    func testProbedRelativeFallbackResolvesUnderInjectedHome() async throws {
        // A failed probe's home-RELATIVE fallback must anchor to the same
        // injected home the admission policy roots at.
        let fallbackDir = fixtureHome
            .appendingPathComponent("Library/Caches/fixture-fallback")
        try mkdir(fallbackDir)
        let payload = try writeFile(
            fallbackDir.appendingPathComponent("payload.bin"), bytes: 4_096
        )

        let category = CacheCategory(
            name: "probed-fallback", slug: "probed-fallback",
            description: "test", icon: "trash",
            discovery: [.probed(
                command: "false", requiresTool: nil,
                fallbacks: ["Library/Caches/fixture-fallback"]
            )],
            riskLevel: .safe, rebuildNote: "", defaultSelected: true
        )

        let result = await makeScanner().scanCategory(category)

        XCTAssertEqual(result.state, .measured)
        XCTAssertEqual(result.exactBytes, allocated(payload))
    }
}
