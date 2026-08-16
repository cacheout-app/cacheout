import XCTest
import Darwin
@testable import Cacheout

/// Unit tests for `DeepRemover`, the descriptor-relative removal primitive
/// behind every permanent delete.
///
/// Everything here is measured with THIS FILE'S OWN syscalls — `readdir` for
/// entry counts, `proc_pidinfo(PROC_PIDLISTFDS)` for the process's real open
/// descriptors, `lstat` for identity. Nothing asserts on a number the code
/// under test reports about itself: a regressor that forgot to update a
/// counter would still be caught.
final class DeepRemoverTests: XCTestCase {

    private var base: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("DeepRemoverTests-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        DeepRemover.testHook = nil
        DeepRemover.fdWindowOverride = nil
        // `FileManager` cannot delete an over-`PATH_MAX` fixture; `rm -rf`
        // chdir's its way down.
        let rm = Process()
        rm.executableURL = URL(fileURLWithPath: "/bin/rm")
        rm.arguments = ["-rf", base.path]
        try? rm.run()
        rm.waitUntilExit()
    }

    // MARK: - Independent measurement

    /// Directory entry count from this test's own `readdir`; -1 when the
    /// directory does not exist, so "gone" and "empty" stay distinguishable.
    private func entryCount(at url: URL) -> Int {
        guard let dir = opendir(url.path) else { return -1 }
        defer { closedir(dir) }
        var count = 0
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(cString: raw.baseAddress!
                    .assumingMemoryBound(to: CChar.self))
            }
            if name != "." && name != ".." { count += 1 }
        }
        return count
    }

    /// The number of descriptors THIS PROCESS currently holds, straight from
    /// the kernel. The independent yardstick for "how many fds does the walk
    /// hold" — `DeepRemover` is never asked.
    private func openDescriptorCount() -> Int {
        let pid = getpid()
        let sizeNeeded = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard sizeNeeded > 0 else { return -1 }
        let capacity = Int(sizeNeeded) + 32 * MemoryLayout<proc_fdinfo>.stride
        var buffer = [UInt8](repeating: 0, count: capacity)
        let written = buffer.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(capacity))
        }
        guard written > 0 else { return -1 }
        return Int(written) / MemoryLayout<proc_fdinfo>.stride
    }

    /// A chain of `depth` directories of 20-byte components with `leafFiles`
    /// files at the bottom, built ENTIRELY fd-relatively — past `PATH_MAX`
    /// no path-based API can create, stat, enumerate or delete it. Throws on
    /// failure so a fixture that silently did not get built cannot make the
    /// claims below vacuously true.
    @discardableResult
    private func makeChain(
        under root: URL, depth: Int, leafFiles: Int
    ) throws -> Int {
        struct FixtureError: Error { let detail: String }
        var fd = open(root.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else {
            throw FixtureError(detail: "open(\(root.path)): \(errno)")
        }
        defer { close(fd) }
        for index in 0..<depth {
            let name = String(format: "d%019d", index)
            guard mkdirat(fd, name, 0o755) == 0 || errno == EEXIST else {
                throw FixtureError(detail: "mkdirat(\(name)): \(errno)")
            }
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY)
            guard child >= 0 else {
                throw FixtureError(detail: "openat(\(name)): \(errno)")
            }
            close(fd)
            fd = child
        }
        for index in 0..<leafFiles {
            let file = openat(fd, "f\(index).bin", O_CREAT | O_WRONLY, 0o644)
            guard file >= 0 else {
                throw FixtureError(detail: "openat(create f\(index)): \(errno)")
            }
            var byte: UInt8 = 0x7
            _ = withUnsafeBytes(of: &byte) { write(file, $0.baseAddress, 1) }
            close(file)
        }
        return depth + leafFiles
    }

    @discardableResult
    private func writeFile(_ url: URL, bytes: Int = 64) throws -> URL {
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    // MARK: - Depth is not a limit

    /// THE DEFECT, at the primitive. A tree whose deepest path runs past
    /// `PATH_MAX` is removed WHOLE — no ENAMETOOLONG, no half-deleted tree —
    /// and the wide siblings beside the deep chain go with it.
    ///
    /// `removefile(3)` (what `FileManager.removeItem` calls) unlinks in
    /// `readdir` order until the first over-long path and then returns
    /// ENAMETOOLONG having already destroyed whatever it reached: measured
    /// with the raw syscall on this exact shape, 41 entries in and 31 left;
    /// with 200 siblings, 201 in and 176 left.
    func testOverPathMaxTreeIsRemovedWholeWithItsWideSiblings() throws {
        let target = base.appendingPathComponent("target")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for index in 0..<40 {
            try writeFile(target.appendingPathComponent("sib\(index).bin"))
        }
        try makeChain(under: target, depth: 120, leafFiles: 3)
        XCTAssertEqual(entryCount(at: target), 41,
                       "fixture precondition: wide AND deep")

        // The fixture is genuinely past `PATH_MAX`, not merely large — proved
        // with a raw `open` of the spelled-out deepest path, not by asking
        // any of this app's own walks what they managed to count.
        var deepest = target.path
        for index in 0..<120 {
            deepest += "/" + String(format: "d%019d", index)
        }
        XCTAssertGreaterThan(deepest.utf8.count, Int(PATH_MAX),
                             "fixture precondition: the path is over-long")
        XCTAssertEqual(open(deepest, O_RDONLY | O_DIRECTORY), -1)
        XCTAssertEqual(errno, ENAMETOOLONG,
                       "fixture precondition: no path-based API can reach it")

        try DeepRemover.removeTree(at: target)
        XCTAssertEqual(entryCount(at: target), -1,
                       "the whole tree is gone, siblings and chain alike")
        XCTAssertEqual(entryCount(at: base), 0, "…and nothing else went")
    }

    /// The descriptor budget is BOUNDED while the depth is not — measured by
    /// asking the KERNEL how many descriptors this process holds at every
    /// directory the walk enters, never by reading a counter `DeepRemover`
    /// keeps about itself.
    ///
    /// A remover that holds one descriptor per level would peak at ~300 here.
    /// The window is 64, so the peak must stay near it; the tree still has to
    /// disappear completely, which is what makes the bound a bound and not a
    /// refusal.
    func testDeepTreeIsRemovedWithinABoundedDescriptorBudget() throws {
        let target = base.appendingPathComponent("target")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try makeChain(under: target, depth: 300, leafFiles: 2)

        let baseline = openDescriptorCount()
        XCTAssertGreaterThan(baseline, 0, "proc_pidinfo must work")
        let peak = Locked(0)
        DeepRemover.testHook = { event in
            guard case .entered = event else { return }
            peak.update { $0 = max($0, DeepRemoverTests.liveDescriptorCount()) }
        }
        defer { DeepRemover.testHook = nil }

        try DeepRemover.removeTree(at: target)

        XCTAssertEqual(entryCount(at: target), -1,
                       "a 300-deep tree is removed, not refused")
        let held = peak.value - baseline
        XCTAssertLessThan(
            held, 100,
            "the walk must hold ~the window (64), not one descriptor per "
                + "level: peak \(peak.value) against a \(baseline) baseline "
                + "over a 300-deep tree"
        )
        XCTAssertGreaterThan(
            peak.value, baseline,
            "sanity: the measurement is live, not a constant"
        )
        XCTAssertLessThanOrEqual(
            openDescriptorCount(), baseline + 2,
            "every descriptor the walk opened is closed again"
        )
    }

    /// `proc_pidinfo` from a `@Sendable` context.
    fileprivate static func liveDescriptorCount() -> Int {
        let pid = getpid()
        let sizeNeeded = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard sizeNeeded > 0 else { return -1 }
        let capacity = Int(sizeNeeded) + 32 * MemoryLayout<proc_fdinfo>.stride
        var buffer = [UInt8](repeating: 0, count: capacity)
        let written = buffer.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(capacity))
        }
        guard written > 0 else { return -1 }
        return Int(written) / MemoryLayout<proc_fdinfo>.stride
    }

    // MARK: - The ancestor recovered through ".." must be the SAME ancestor

    /// Past the descriptor window an ancestor's descriptor is closed and
    /// recovered with `openat(child, "..")` when the walk pops back to it.
    /// If the subtree was MOVED in the meantime, `..` names a directory this
    /// removal was never admitted to touch — so the recovered descriptor is
    /// checked against the `(st_dev, st_ino)` recorded while it was held, and
    /// a mismatch fails closed.
    ///
    /// Driven deterministically: the window is narrowed to 2 so a
    /// three-directory fixture reaches the recovery, and the move happens in
    /// the hook that fires immediately before the `openat("..")`.
    func testAncestorMovedMidWalkFailsClosedInsteadOfUnlinkingElsewhere() throws {
        let target = base.appendingPathComponent("target")
        let inner = target.appendingPathComponent("a")
        try writeFile(inner.appendingPathComponent("b/leaf.bin"))
        let elsewhere = base.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)

        DeepRemover.fdWindowOverride = 2
        defer { DeepRemover.fdWindowOverride = nil }
        let moved = Locked(false)
        DeepRemover.testHook = { event in
            guard case .willReopenAncestor = event else { return }
            moved.update { already in
                guard !already else { return }
                already = rename(inner.path, elsewhere
                    .appendingPathComponent("a").path) == 0
            }
        }
        defer { DeepRemover.testHook = nil }

        XCTAssertThrowsError(try DeepRemover.removeTree(at: target)) { error in
            let failure = error as? DeepRemover.Failure
            XCTAssertNotNil(failure, "a typed failure, not a Cocoa error")
            XCTAssertEqual(failure?.operation, "open")
            XCTAssertEqual(failure?.relativePath, "target/a/..")
        }
        XCTAssertTrue(moved.value, "fixture precondition: the move happened")
        XCTAssertEqual(
            entryCount(at: elsewhere.appendingPathComponent("a")), 0,
            "the moved directory is STILL THERE — the walk refused to unlink "
                + "a name out of a directory it was never admitted to touch"
        )
    }

    // MARK: - Unresolved spelling, honest failure

    /// R4 at the primitive: a symlink is removed AS a link. Neither the link
    /// target nor anything under it is touched, whether the symlink is the
    /// removal ROOT or an entry inside the tree.
    func testSymlinksAreRemovedAsLinksAndNeverFollowed() throws {
        let outside = base.appendingPathComponent("outside")
        let treasure = try writeFile(outside.appendingPathComponent("keep.bin"))
        let target = base.appendingPathComponent("target")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: target.appendingPathComponent("link"), withDestinationURL: outside
        )

        try DeepRemover.removeTree(at: target)
        XCTAssertEqual(entryCount(at: target), -1, "the tree goes")
        XCTAssertTrue(fm.fileExists(atPath: treasure.path),
                      "the symlink's target is untouched")

        // …and as the root itself.
        let rootLink = base.appendingPathComponent("rootlink")
        try fm.createSymbolicLink(at: rootLink, withDestinationURL: outside)
        try DeepRemover.removeTree(at: rootLink)
        XCTAssertFalse(fm.fileExists(atPath: rootLink.path), "the link goes")
        XCTAssertTrue(fm.fileExists(atPath: treasure.path),
                      "…its target still does not")
    }

    /// The race the classification alone cannot cover: an entry that WAS a
    /// directory when `readdir` reported it, replaced by a symlink before the
    /// walk enters it. `O_NOFOLLOW` on the entering `openat` turns that into
    /// a failure instead of a deletion spree outside the tree.
    ///
    /// Driven deterministically from the hook that fires immediately before
    /// that `openat`.
    func testDirectorySwappedForASymlinkMidWalkIsNeverFollowed() throws {
        let outside = base.appendingPathComponent("outside")
        let treasure = try writeFile(outside.appendingPathComponent("keep.bin"))
        let target = base.appendingPathComponent("target")
        let sub = target.appendingPathComponent("sub")
        try writeFile(sub.appendingPathComponent("junk.bin"))

        let swapped = Locked(false)
        DeepRemover.testHook = { event in
            guard case .willEnter(let name, _) = event, name == "sub" else {
                return
            }
            swapped.update { already in
                guard !already else { return }
                guard rename(sub.path, target.appendingPathComponent("stash").path)
                        == 0 else { return }
                already = symlink(outside.path, sub.path) == 0
            }
        }
        defer { DeepRemover.testHook = nil }

        XCTAssertThrowsError(try DeepRemover.removeTree(at: target)) { error in
            let failure = error as? DeepRemover.Failure
            XCTAssertEqual(failure?.operation, "open")
            // macOS reports the `O_DIRECTORY | O_NOFOLLOW` refusal of a
            // symlink as ENOTDIR; ELOOP is the other spelling. Without
            // `O_NOFOLLOW` the open would SUCCEED — `outside` is a
            // directory — which is what the surviving treasure below pins.
            XCTAssertTrue(
                failure?.code == ENOTDIR || failure?.code == ELOOP,
                "the no-follow open refuses the swapped entry: "
                    + "\(failure?.code.description ?? "nil")"
            )
        }
        XCTAssertTrue(swapped.value, "fixture precondition: the swap happened")
        XCTAssertTrue(
            fm.fileExists(atPath: treasure.path),
            "the walk must never leave the tree through a symlink planted "
                + "between readdir and openat"
        )
        XCTAssertEqual(entryCount(at: outside), 1, "…nor empty its target")
    }

    /// The frozen ghost-target asymmetry the cleaner depends on: an absent
    /// removal ROOT is an ERROR, never a silent success.
    func testAbsentRootThrowsInsteadOfSucceedingSilently() {
        XCTAssertThrowsError(
            try DeepRemover.removeTree(at: base.appendingPathComponent("ghost"))
        ) { error in
            XCTAssertEqual((error as? DeepRemover.Failure)?.code, ENOENT)
        }
    }

    /// A plain file and an empty directory both go, and the failure message
    /// distinguishes a tree left intact from one partly destroyed — with the
    /// wording each surface reads.
    func testFailureWordingSeparatesIntactFromPartiallyRemoved() throws {
        let intact = DeepRemover.Failure(
            target: "/tmp/target", relativePath: "target/a", operation: "unlink",
            code: EACCES, removedEntries: 0
        )
        let partial = DeepRemover.Failure(
            target: "/tmp/target", relativePath: "target", operation: "rmdir",
            code: EACCES, removedEntries: 21
        )
        XCTAssertTrue(
            intact.localizedDescription
                .contains("nothing in this tree was removed"),
            intact.localizedDescription
        )
        XCTAssertFalse(
            intact.localizedDescription.lowercased()
                .contains("partially removed"),
            intact.localizedDescription
        )
        XCTAssertTrue(
            partial.localizedDescription.lowercased()
                .contains("partially removed"),
            partial.localizedDescription
        )
        XCTAssertTrue(
            partial.localizedDescription.contains("21 entries"),
            "the count of what was destroyed is stated, not implied: "
                + partial.localizedDescription
        )
    }
}

/// Minimal mutex box so the `@Sendable` walk hook can record into the test.
private final class Locked<Value>: @unchecked Sendable {
    private var storage: Value
    private let lock = NSLock()

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func update(_ body: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&storage)
    }
}
