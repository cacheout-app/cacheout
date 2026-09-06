import Foundation
import XCTest

/// CLIENT-side `AF_UNIX` sockets for the test suite, with SIGPIPE disarmed
/// (PR #460 codex r4, D5).
///
/// ## WHY THIS TYPE EXISTS: A BROKEN PIPE USED TO KILL THE WHOLE RUN
///
/// `SIGPIPE`'s default disposition TERMINATES the process, and a test
/// process is the whole suite. Two helpers — `HeadlessTests`'
/// `sendSocketCommand` and `RecommendationEngineTests`' file-private twin —
/// created a bare `socket(AF_UNIX, SOCK_STREAM, 0)` and wrote to it with
/// `Darwin.write`, with no `SO_NOSIGPIPE` and no `signal(SIGPIPE, SIG_IGN)`
/// anywhere in the harness. Production sets the option only on the SERVER's
/// ACCEPTED descriptor (`StatusSocket.start()`), which protects the daemon
/// and does nothing for a client in this process.
///
/// MEASURED before the fix (PR #460 codex r4): 2 of 9 full `swift test` runs
/// died at `StatusSocketIntegrationTests.testConcurrentClients` with
/// **signal 13**. In one of them only 1319 of 1448 cells had run, including
/// every cell in `WorktreeReclaimPerformerTests` and
/// `WorktreeStalenessAssessorTests`, i.e. the whole delete-time-gate
/// evidence base of this PR. NO cell fails in that state and the
/// "Executed N tests" line never prints, so a truncated run is easy to
/// mistake for a green one.
///
/// ARITHMETIC CORRECTION (PR #460 codex r5, D8). This comment and `60a1696`
/// both said "127 never ran". 1448 − 1319 = **129**. The two figures the
/// measurement actually produced are kept and the derived one is dropped
/// rather than re-derived, because nothing in that run recorded which of the
/// two endpoints was the approximate one — and a subtraction is not evidence
/// for either.
///
/// With `SO_NOSIGPIPE` set at creation, the same broken pipe returns
/// `-1`/`EPIPE` from `write(2)` and fails ONE cell.
///
/// The option is set on the descriptor rather than the signal disposition
/// changed process-wide on purpose: a `signal(SIGPIPE, SIG_IGN)` in a test
/// harness is inherited by everything the suite spawns and silently changes
/// what the code under test observes.
enum TestSocketClient {

    /// A `SOCK_STREAM` `AF_UNIX` client descriptor with `SO_NOSIGPIPE` set
    /// BEFORE any write can reach it. Caller owns the descriptor.
    static func makeStreamSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(
                domain: "TestSocketClient", code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey:
                            "socket() failed: errno \(errno)"]
            )
        }
        guard disarmSIGPIPE(on: fd) else {
            let code = errno
            close(fd)
            throw NSError(
                domain: "TestSocketClient", code: Int(code),
                userInfo: [NSLocalizedDescriptionKey:
                            "SO_NOSIGPIPE could not be set: errno \(code) — "
                            + "refusing to hand back a descriptor whose "
                            + "broken pipe would kill the suite"]
            )
        }
        return fd
    }

    /// `setsockopt(SO_NOSIGPIPE)`, true on success. Separated so the cell
    /// that proves the disarming works can also drive the UNDISARMED shape.
    @discardableResult
    static func disarmSIGPIPE(on fd: Int32) -> Bool {
        var on: Int32 = 1
        return setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE, &on,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0
    }

    /// `write(2)` of `bytes`, answering what the syscall answered: the byte
    /// count, or `-1` with `errno` captured before anything else can clobber
    /// it.
    static func write(_ bytes: [UInt8], to fd: Int32) -> (result: Int, errno: Int32) {
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return (0, 0) }
            let written = Darwin.write(fd, base, buffer.count)
            return (written, written < 0 ? errno : 0)
        }
    }

    /// Read `StatusSocket`'s newline-terminated reply WHOLE — loop until the
    /// `\n` that ends the line, EOF, or a full buffer (fn-4.14).
    ///
    /// ## WHY A LOOP: THE FLAKY READ WAS A SHORT READ
    ///
    /// The protocol is newline-delimited (`StatusSocket.writeJsonLine` appends
    /// `"\n"` and the SERVER's read side loops until it sees `0x0A`), but both
    /// test clients did a SINGLE `read(2)` on a `SOCK_STREAM` socket — which
    /// has NO message boundaries. A reply delivered to the kernel in more than
    /// one segment hands the first segment to that single `read`, and the
    /// caller parses TRUNCATED JSON. Not a timeout (the client read blocks
    /// with no `SO_RCVTIMEO` of its own) and not a lost race with the server's
    /// `close` (close does not discard delivered bytes): a SHORT READ, one the
    /// protocol's own framing already tells us how to finish.
    /// `StatusSocketIntegrationTests.testSegmentedReplyIsReadWholeNotFirstSegment`
    /// drives this loop against a server that writes in two spaced segments;
    /// under a single `read(2)` that fixture's reply comes back truncated
    /// (measured red 10 of 10 runs), under this loop it comes back whole.
    ///
    /// Historically the truncated string then met
    /// `try JSONSerialization.jsonObject(…) as! [String: Any]`, and a trapping
    /// cast KILLS the xctest process — the fn-4.14 strand class — which is why
    /// the callers now unwrap with `XCTUnwrap` and `StrandFenceTests` fences
    /// `as!` out of test sources entirely.
    static func readNewlineTerminatedReply(
        from fd: Int32, capacity: Int = 65536
    ) throws -> String {
        var buffer = [UInt8](repeating: 0, count: capacity)
        var total = 0
        while total < buffer.count {
            let n = buffer.withUnsafeMutableBufferPointer { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base + total, raw.count - total)
            }
            if n < 0 {
                throw NSError(
                    domain: "TestSocketClient", code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey:
                                "read() failed: errno \(errno)"]
                )
            }
            if n == 0 { break }   // EOF: the server closed after its reply.
            total += n
            if buffer[0..<total].contains(0x0A) { break }
        }
        guard total > 0 else {
            throw NSError(
                domain: "TestSocketClient", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No response"]
            )
        }
        return String(bytes: buffer[0..<total], encoding: .utf8) ?? ""
    }
}
