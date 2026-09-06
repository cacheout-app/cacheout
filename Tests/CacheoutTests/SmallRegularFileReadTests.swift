import XCTest
@testable import Cacheout

/// `FileSystemIdentityProvider.smallRegularFile(at:limit:)` — one no-follow,
/// bounded descriptor for kind, identity and bytes (PR #461 codex r2).
///
/// It replaces eight `String(contentsOf:)`/`Data(contentsOf:)` reads across
/// the worktree inventory and the reclaim performer. Every one of them asked
/// `probeKind` about a PATH and then handed that same PATH to a reader that
/// resolves it again and FOLLOWS symlinks, so a `HEAD` or `config` swapped
/// between the two calls was opened through the replacement.
///
/// MUTATION, each applied alone and MEASURED, not asserted:
/// - drop `O_NOFOLLOW` -> reds `testASymlinkIsRefusedRatherThanFollowed`,
///   and nothing else;
/// - drop BOTH size checks (the `fstat` precondition and the post-read
///   backstop) -> reds `testAFileLargerThanTheLimitIsRefusedNotTruncated`,
///   and nothing else. Dropping only one is caught by the other, which is
///   deliberate: the file can grow between the two;
/// - drop `S_IFREG` -> reds `testAFifoIsRefusedWithoutParkingTheReader`
///   before it reaches `…ADirectoryIsRefused`;
/// - drop `O_NONBLOCK` -> the SUITE HANGS. Measured: killed at 300 s with no
///   tally line. That is the guard's whole point, and it is why the FIFO cell
///   carries a wall-clock assertion rather than only a nil check — a reader
///   that parks does not fail, it stops.
/// All four are deterministic (a source predicate over a fixture), so one
/// run each is conclusive; unmutated the suite is 9/9 green.
final class SmallRegularFileReadTests: XCTestCase {

    private var base: URL!
    private let provider = FileSystemIdentityProvider()

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("small-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func write(_ text: String, to name: String) throws -> URL {
        let url = base.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testAPlainFileReadsWholeAndCarriesItsOwnIdentity() throws {
        let file = try write("ref: refs/heads/main\n", to: "HEAD")
        let found = try XCTUnwrap(provider.smallRegularFile(at: file, limit: 4096))
        XCTAssertEqual(String(data: found.bytes, encoding: .utf8), "ref: refs/heads/main\n")
        XCTAssertEqual(
            found.identity, provider.identity(of: file),
            "the bytes and the identity must describe the same object"
        )
    }

    /// THE FINDING. `probeKind` says regular file; the old readers then
    /// resolved the path AGAIN and followed whatever was there by then.
    func testASymlinkIsRefusedRatherThanFollowed() throws {
        let target = try write("secret\n", to: "target")
        let link = base.appendingPathComponent("HEAD")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertNil(
            provider.smallRegularFileText(at: link, limit: 4096),
            "a symlink at the name must not be followed — that is how a scan "
                + "is steered into a TCC-protected or unresponsive target"
        )
        XCTAssertEqual(
            provider.smallRegularFileText(at: target, limit: 4096), "secret\n",
            "the target itself still reads: the refusal is the LINK's"
        )
    }

    /// THE OTHER FINDING. Refused, never truncated — a truncating reader
    /// would let a multi-gigabyte file whose first bytes spell a valid HEAD
    /// pass as one.
    func testAFileLargerThanTheLimitIsRefusedNotTruncated() throws {
        let big = try write(String(repeating: "x", count: 5000), to: "config")
        XCTAssertNil(provider.smallRegularFileText(at: big, limit: 1000))
        XCTAssertEqual(
            provider.smallRegularFileText(at: big, limit: 8000)?.count, 5000,
            "under the limit it still reads whole"
        )
    }

    func testAFileExactlyAtTheLimitIsAccepted() throws {
        let file = try write(String(repeating: "y", count: 512), to: "edge")
        XCTAssertEqual(
            provider.smallRegularFileText(at: file, limit: 512)?.count, 512
        )
    }

    func testADirectoryIsRefused() throws {
        let directory = base.appendingPathComponent("objects")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        XCTAssertNil(provider.smallRegularFile(at: directory, limit: 4096))
    }

    /// `O_NOFOLLOW` alone does not save the open of a FIFO: a named pipe left
    /// at one of these names parks the opening thread until a writer appears,
    /// which on a scan thread is a hang. `O_NONBLOCK` is what makes the
    /// `fstat` refusal below reachable at all.
    func testAFifoIsRefusedWithoutParkingTheReader() throws {
        let fifo = base.appendingPathComponent("HEAD")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0, "fixture: mkfifo failed")
        let started = Date()
        XCTAssertNil(provider.smallRegularFile(at: fifo, limit: 4096))
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 2.0,
            "the read parked on a FIFO with no writer"
        )
    }

    func testAnEmptyFileIsEmptyRatherThanMissing() throws {
        let file = try write("", to: "empty")
        let found = try XCTUnwrap(provider.smallRegularFile(at: file, limit: 4096))
        XCTAssertEqual(found.bytes, Data())
    }

    func testAnAbsentFileIsNil() {
        XCTAssertNil(
            provider.smallRegularFile(
                at: base.appendingPathComponent("nope"), limit: 4096
            )
        )
    }

    func testInvalidUTF8IsNilForTheTextForm() throws {
        let file = base.appendingPathComponent("binary")
        try Data([0xFF, 0xFE, 0xFF]).write(to: file)
        XCTAssertNil(provider.smallRegularFileText(at: file, limit: 4096))
        XCTAssertNotNil(
            provider.smallRegularFile(at: file, limit: 4096),
            "the bytes form still answers: only the decode fails"
        )
    }
}
