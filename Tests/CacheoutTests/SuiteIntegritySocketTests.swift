import XCTest
@testable import Cacheout

/// D5 (PR #460 codex r4): a broken pipe on a TEST client socket must fail ONE
/// CELL, never terminate the run.
///
/// This is a VERIFICATION-INTEGRITY cell, not a product cell. The failure it
/// pins does not fail anything: `SIGPIPE`'s default disposition kills the
/// process, so the "Executed N tests" line never prints and every cell that
/// had not run yet is silently skipped. 8fa8ad3 closed the trapping-subscript
/// shape of the same class; this closes the signal shape.
final class SuiteIntegritySocketTests: XCTestCase {

    /// The disarming, driven deterministically: writing to a socket whose own
    /// write side has been shut down is the one broken-pipe shape that needs
    /// no peer and no race.
    ///
    /// MEASURED on Darwin 25.5 (`socketpair` + `shutdown(SHUT_WR)` +
    /// `write`): `errno 32 EPIPE`. Without `SO_NOSIGPIPE` the same write
    /// raises SIGPIPE and this process dies — which is exactly what the
    /// mutation test for this guard looks like: delete the `disarmSIGPIPE`
    /// call inside `makeStreamSocket` and the run terminates on signal 13
    /// instead of reporting a failure.
    func testAWriteToABrokenPipeReturnsEPIPERatherThanKillingTheRun() throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(
            socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0,
            "socketpair(2) failed: errno \(errno)"
        )
        // `pair` is a two-element literal `socketpair(2)` fills in, so a
        // subscript here could not trap — but the statement-position fence
        // forbids the shape rather than each site's reasoning about itself
        // (PR #460 codex r6, D4).
        let fd = try XCTUnwrap(pair.first)
        let descriptors = pair
        defer { descriptors.forEach { close($0) } }

        XCTAssertTrue(
            TestSocketClient.disarmSIGPIPE(on: fd),
            "SO_NOSIGPIPE could not be set: errno \(errno)"
        )
        XCTAssertEqual(shutdown(fd, SHUT_WR), 0, "shutdown() failed: errno \(errno)")

        let outcome = TestSocketClient.write(Array("payload".utf8), to: fd)
        XCTAssertEqual(outcome.result, -1, "the write should have failed")
        XCTAssertEqual(
            outcome.errno, EPIPE,
            "expected EPIPE (\(EPIPE)), got \(outcome.errno) — if this "
                + "process is still alive with a different errno the pipe was "
                + "not actually broken"
        )
    }

    /// Every client descriptor the shared helper hands out is disarmed at
    /// creation — the property the two `sendSocketCommand` helpers depend on.
    /// Asserted through `getsockopt` so a `makeStreamSocket` that stopped
    /// setting the option fails HERE, deterministically, instead of in
    /// whichever concurrent-client cell happens to lose the race next.
    func testEveryClientSocketTheHelperHandsOutIsDisarmedAtCreation() throws {
        let fd = try TestSocketClient.makeStreamSocket()
        defer { close(fd) }

        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(
            getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, &length), 0,
            "getsockopt failed: errno \(errno)"
        )
        XCTAssertNotEqual(
            value, 0,
            "the helper handed out a client socket that would kill the suite "
                + "on a broken pipe"
        )
    }
}
