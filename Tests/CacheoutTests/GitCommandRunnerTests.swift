/// # GitCommandRunnerTests — fn-5.1 (R9 / D17)
///
/// The subprocess seam's contract: argv-only execution (never a shell),
/// captured stdout AND stderr drained concurrently past the 64 KiB pipe
/// buffer, the per-INVOCATION timeout, the FULL termination protocol against
/// a SIGTERM-IGNORING child, the D17 safety profiles classified per COMMAND,
/// and an INSTANCE-scoped availability cache.
///
/// HERMETIC BY CONSTRUCTION: every "git is missing" proof uses an injected
/// environment (a PATH of one empty directory) or an injected stub
/// executable. NOTHING here asserts on the host's git layout, and the
/// production-default environment is proven by EQUALITY, never by execution
/// — the production PATH contains `/usr/bin`, where the CLT git shim usually
/// lives, so executing under it could never prove absence.

import XCTest
@testable import Cacheout

// MARK: - Shared git fixtures (also used by GitWorktreeInventoryTests)

/// Hermetic real-git fixture support. Every invocation pins
/// `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM` to `/dev/null` and an injected
/// `HOME`, so no test can read (or write) the developer's real git config.
enum GitFixture {

    /// The PATH real-git fixtures search. Independent of
    /// `GitCommandRunner.productionPATH` on purpose: the production default
    /// is asserted by equality elsewhere and must never become an execution
    /// dependency.
    static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin"

    static func environment(home: URL, extra: [String: String] = [:]) -> [String: String] {
        var environment = [
            "PATH": searchPath,
            "HOME": home.path,
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_SYSTEM": "/dev/null"
        ]
        for (key, value) in extra { environment[key] = value }
        return environment
    }

    /// Run real git for FIXTURE CONSTRUCTION only — never the code under
    /// test. Returns (exit status, stdout bytes).
    @discardableResult
    static func git(
        _ arguments: [String], home: URL, environment extra: [String: String] = [:]
    ) throws -> (status: Int32, stdout: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.environment = environment(home: home, extra: extra)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        XCTAssertTrue(process.waitForExit(within: 30), "fixture git call hung: \(arguments)")
        return (process.terminationStatus, data)
    }

    /// `git init` + one empty commit, hermetically.
    static func makeRepository(at url: URL, home: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let initialized = try git(
            ["-c", "init.defaultBranch=main", "init", url.path], home: home
        )
        XCTAssertEqual(initialized.status, 0, "git init failed at \(url.path)")
        let committed = try git(
            ["-C", url.path, "-c", "user.name=t", "-c", "user.email=t@t",
             "commit", "--allow-empty", "-m", "x"],
            home: home
        )
        XCTAssertEqual(committed.status, 0, "git commit failed at \(url.path)")
    }

    /// A `git` stub on PATH. `body` is the bash after the `--version`
    /// fast-path (every stub answers the availability probe so the behavior
    /// under test is the one the test names).
    static func makeStubGit(in directory: URL, body: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = """
        #!/bin/bash
        for argument in "$@"; do
          if [ "$argument" = "--version" ]; then
            echo "git version 2.99.0-stub"
            exit 0
          fi
        done
        \(body)
        """
        let url = directory.appendingPathComponent("git")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
        return url
    }

    /// A stub that answers NOTHING — not even the probe — and exits 127.
    static func makeUnavailableStub(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "#!/bin/bash\nexit 127\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
    }
}

// MARK: - Test doubles

/// The injectable seam in its simplest form: fn-5.2/fn-5.4 script outcomes
/// through exactly this shape.
private struct ScriptedGitRunner: GitCommandRunning {
    let defaultTimeout: TimeInterval = 1
    let outcome: GitCommandOutcome

    func run(_ arguments: [String], timeout: TimeInterval) async -> GitCommandInvocation {
        GitCommandInvocation(
            profile: GitSafetyProfile.classify(arguments),
            argv: ["git"] + arguments,
            environment: [:],
            outcome: outcome
        )
    }
}

/// Proof the runner is usable from an actor context (the scanner is one).
private actor GitRunnerActorClient {
    private let runner: any GitCommandRunning

    init(runner: any GitCommandRunning) { self.runner = runner }

    func version() async -> GitCommandInvocation { await runner.run(["--version"]) }
}

// MARK: - Tests

final class GitCommandRunnerTests: XCTestCase {

    private var base: URL!
    private var home: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("GitCommandRunnerTests-\(UUID().uuidString)")
        home = base.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base { try? fm.removeItem(at: base) }
    }

    // MARK: Helpers

    private func stubEnvironment(pathDirectories: [URL]) -> [String: String] {
        [
            "PATH": pathDirectories.map(\.path).joined(separator: ":"),
            "HOME": home.path
        ]
    }

    private func emptyPathEnvironment() throws -> [String: String] {
        let empty = base.appendingPathComponent("empty-path-\(UUID().uuidString)")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        return stubEnvironment(pathDirectories: [empty])
    }

    /// Bounded poll — the house's `waitForExit(within:)` idiom, never a
    /// fixed sleep.
    private func waitUntil(
        _ timeout: TimeInterval, _ condition: () -> Bool
    ) -> Bool {
        let deadline = DispatchTime.now() + timeout
        var interval: UInt32 = 1_000
        while !condition() {
            if DispatchTime.now() >= deadline { return false }
            usleep(interval)
            interval = min(interval * 2, 16_000)
        }
        return true
    }

    private func repoSource(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CacheoutTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Production environment: EQUALITY only, never execution

    func testProductionEnvironmentIsTheCleanerClonedPathAssertedByEquality() throws {
        XCTAssertEqual(
            GitCommandRunner.productionEnvironment(home: home),
            [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin",
                "HOME": home.path
            ],
            "the production environment is the cleaner's PATH plus the injected HOME"
        )
        XCTAssertEqual(
            GitCommandRunner(home: home).baseEnvironment,
            GitCommandRunner.productionEnvironment(home: home),
            "the production initializer installs exactly that environment"
        )
    }

    func testProductionPathLiteralIsClonedVerbatimFromTheCleaner() throws {
        let cleaner = try repoSource("Sources/Cacheout/Cleaner/CacheCleaner.swift")
        XCTAssertTrue(
            cleaner.contains("\"\(GitCommandRunner.productionPATH)\""),
            "the runner's PATH must be the cleaner's PATH, verbatim"
        )
    }

    // MARK: - Real git: success and failure classes

    func testRealGitVersionSucceedsWithCapturedStdout() async throws {
        let runner = GitCommandRunner(environment: GitFixture.environment(home: home))
        let invocation = await runner.run(["--version"])
        guard case .success(let stdout) = invocation.outcome else {
            return XCTFail("expected success, got \(invocation.outcome)")
        }
        let text = String(decoding: stdout, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("git version"), "captured stdout was: \(text)")
    }

    func testFailingSubcommandReturnsExitCodeAndCapturedStderr() async throws {
        let notARepo = base.appendingPathComponent("not-a-repo")
        try fm.createDirectory(at: notARepo, withIntermediateDirectories: true)
        let runner = GitCommandRunner(environment: GitFixture.environment(home: home))
        let invocation = await runner.run(
            ["-C", notARepo.path, "status", "--porcelain", "--ignore-submodules=none"]
        )
        guard case .failure(let exitCode, let stderr) = invocation.outcome else {
            return XCTFail("expected failure, got \(invocation.outcome)")
        }
        XCTAssertNotEqual(exitCode, 0)
        XCTAssertTrue(
            stderr.contains("not a git repository"),
            "git's own stderr must survive capture; got: \(stderr)"
        )
    }

    // MARK: - gitUnavailable, proven hermetically

    func testEmptyPathEnvironmentYieldsGitUnavailable() async throws {
        let runner = GitCommandRunner(environment: try emptyPathEnvironment())
        let invocation = await runner.run(["--version"])
        XCTAssertEqual(invocation.outcome, .gitUnavailable)
        let available = await runner.isGitAvailable()
        XCTAssertFalse(available)
    }

    func testInjectedExecutableExiting127YieldsGitUnavailable() async throws {
        let stub = base.appendingPathComponent("stubs/exit127")
        try GitFixture.makeUnavailableStub(at: stub)
        let runner = GitCommandRunner(
            environment: try emptyPathEnvironment(), executableURL: stub
        )
        let invocation = await runner.run(["worktree", "list", "--porcelain", "-z"])
        XCTAssertEqual(invocation.outcome, .gitUnavailable)
    }

    func testUnrunnableExecutableYieldsGitUnavailableNotACrash() async throws {
        let missing = base.appendingPathComponent("stubs/does-not-exist")
        let runner = GitCommandRunner(
            environment: try emptyPathEnvironment(), executableURL: missing
        )
        let invocation = await runner.run(["--version"])
        XCTAssertEqual(invocation.outcome, .gitUnavailable)
    }

    // MARK: - 64 KiB pipe deadlock

    func testBothStreamsPast64KiBSimultaneouslyDoNotDeadlock() async throws {
        let stubs = base.appendingPathComponent("stubs-bigout")
        _ = try GitFixture.makeStubGit(in: stubs, body: """
        chunk=$(printf 'x%.0s' {1..1000})
        for i in {1..200}; do
          printf '%s' "$chunk"
          printf '%s' "$chunk" >&2
        done
        exit 0
        """)
        let runner = GitCommandRunner(
            environment: stubEnvironment(pathDirectories: [stubs]), defaultTimeout: 30
        )
        let invocation = await runner.run(["status", "--porcelain"])
        guard case .success(let stdout) = invocation.outcome else {
            return XCTFail("both streams past 64 KiB deadlocked: \(invocation.outcome)")
        }
        XCTAssertEqual(stdout.count, 200_000, "stdout drained completely")
    }

    func testStderrPast64KiBIsCapturedCompletelyOnFailure() async throws {
        let stubs = base.appendingPathComponent("stubs-bigerr")
        _ = try GitFixture.makeStubGit(in: stubs, body: """
        chunk=$(printf 'e%.0s' {1..1000})
        for i in {1..200}; do
          printf '%s' "$chunk" >&2
          printf '%s' "$chunk"
        done
        exit 3
        """)
        let runner = GitCommandRunner(
            environment: stubEnvironment(pathDirectories: [stubs]), defaultTimeout: 30
        )
        let invocation = await runner.run(["status", "--porcelain"])
        guard case .failure(let exitCode, let stderr) = invocation.outcome else {
            return XCTFail("expected failure, got \(invocation.outcome)")
        }
        XCTAssertEqual(exitCode, 3)
        XCTAssertEqual(stderr.count, 200_000, "stderr drained completely")
    }

    // MARK: - Per-invocation timeout & the FULL termination protocol

    func testHangingStubTimesOutAtTheInjectedPerInvocationTimeout() async throws {
        let stubs = base.appendingPathComponent("stubs-hang")
        _ = try GitFixture.makeStubGit(in: stubs, body: """
        export PATH=/bin:/usr/bin
        sleep 120
        """)
        let runner = GitCommandRunner(
            environment: stubEnvironment(pathDirectories: [stubs]),
            defaultTimeout: 30,
            terminationGrace: 0.5,
            drainJoinBudget: 1
        )
        // The PER-INVOCATION budget wins over the runner-wide default.
        let invocation = await runner.run(["status", "--porcelain"], timeout: 0.5)
        XCTAssertEqual(invocation.outcome, .timeout)
    }

    func testSigtermIgnoringStubIsEscalatedToSigkillAndStillReportsTimeout() async throws {
        let stubs = base.appendingPathComponent("stubs-sigterm")
        let pidFile = base.appendingPathComponent("stub.pid")
        let survivedFile = base.appendingPathComponent("stub.survived")
        _ = try GitFixture.makeStubGit(in: stubs, body: """
        export PATH=/bin:/usr/bin
        trap '' TERM
        echo $$ > "\(pidFile.path)"
        i=0
        while [ $i -lt 1200 ]; do
          sleep 0.1
          i=$((i + 1))
        done
        echo survived > "\(survivedFile.path)"
        """)
        let runner = GitCommandRunner(
            environment: stubEnvironment(pathDirectories: [stubs]),
            defaultTimeout: 30,
            terminationGrace: 0.5,
            drainJoinBudget: 1
        )
        let invocation = await runner.run(["status", "--porcelain"], timeout: 0.5)

        // The runner reports timeout even though SIGTERM was ignored …
        XCTAssertEqual(invocation.outcome, .timeout)
        // … and the drain joins returned rather than wedging on the open FDs
        // (a wedged join would have blocked the call above forever).

        let recorded = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(pid_t(recorded), "stub recorded its pid")
        XCTAssertTrue(
            waitUntil(5) { kill(pid, 0) != 0 },
            "the SIGTERM-ignoring child must be SIGKILLed, not left running"
        )
        XCTAssertFalse(
            fm.fileExists(atPath: survivedFile.path),
            "the child never reached its post-loop marker"
        )
    }

    // MARK: - The drain's lock: bounded turns, and a closer nobody barges past

    /// A shell that starts `count` writers on the pipe's write end and then
    /// blocks. The writers are GRANDCHILDREN — killing the shell leaves them
    /// running, which is exactly the shape the runner's timeout path meets
    /// (the child is SIGKILLed, something it spawned still holds the
    /// inherited write end) and the shape the drain has to survive.
    ///
    /// `dd bs=64` deliberately, not `cat /dev/zero`: what starves a waiter is
    /// the RATE OF READS, not the byte rate, and 64-byte writes keep the
    /// drain's loop spinning at full speed while pouring ~10 MB/s rather than
    /// ~3 GB/s into the capture buffer.
    @discardableResult
    private func startWriters(
        on pipe: Pipe, count: Int, pidFile: URL
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", """
        export PATH=/bin:/usr/bin
        i=0
        while [ $i -lt \(count) ]; do
          dd if=/dev/zero bs=64 2>/dev/null &
          echo $! >> "\(pidFile.path)"
          i=$((i + 1))
        done
        wait
        """]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func killRecordedWriters(_ pidFile: URL) {
        let text = (try? String(contentsOf: pidFile, encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n") {
            if let pid = pid_t(line.trimmingCharacters(in: .whitespaces)) { kill(pid, SIGKILL) }
        }
    }

    /// One (pipe, writers, drain) trio: start the flood, let it reach steady
    /// state, then time `close()` COLD. Cold matters — a thread that has just
    /// released `NSLock` wins the next race trivially, so a warm probe would
    /// measure the wrong thing entirely.
    private func measureCloseWaitMilliseconds(
        writers: Int, settle: TimeInterval
    ) throws -> Double {
        let pidFile = base.appendingPathComponent("writers-\(UUID().uuidString).pid")
        let pipe = Pipe()
        let shell = try startWriters(on: pipe, count: writers, pidFile: pidFile)
        defer {
            shell.terminate()
            killRecordedWriters(pidFile)
        }
        let drain = PipeDrain(pipe: pipe)
        drain.start()
        Thread.sleep(forTimeInterval: settle)
        XCTAssertGreaterThan(
            drain.captured.count, 0,
            "the fixture never fed the drain — nothing would be contended"
        )
        Thread.sleep(forTimeInterval: 0.05)
        let started = DispatchTime.now().uptimeNanoseconds
        drain.close()
        let waited = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        XCTAssertTrue(
            drain.join(within: 5), "the worker must return once the close is announced"
        )
        return waited
    }

    /// One (pipe, writers, drain) trio timing ONE cold call against a flood
    /// at steady state. `ending == true` times `closeAndCapture()` — what
    /// production calls; `false` times the bare `captured` — r14's order,
    /// measured and printed but never asserted.
    ///
    /// COLD both ways: a thread that has just released `NSLock` wins the next
    /// race trivially, so the probe must not have touched the lock before.
    private func measureDrainEndWaitMilliseconds(
        ending: Bool, writers: Int, settle: TimeInterval
    ) throws -> (waited: Double, bytes: Int) {
        let pidFile = base.appendingPathComponent("writers-\(UUID().uuidString).pid")
        let pipe = Pipe()
        let shell = try startWriters(on: pipe, count: writers, pidFile: pidFile)
        defer {
            shell.terminate()
            killRecordedWriters(pidFile)
        }
        let drain = PipeDrain(pipe: pipe)
        drain.start()
        Thread.sleep(forTimeInterval: settle)
        Thread.sleep(forTimeInterval: 0.05)

        let started = DispatchTime.now().uptimeNanoseconds
        let bytes = ending ? drain.closeAndCapture().count : drain.captured.count
        let waited = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6

        if !ending { drain.close() }
        XCTAssertTrue(
            drain.join(within: 5), "the worker must return once the close lands"
        )
        return (waited, bytes)
    }

    /// S-P2 (PR #460 codex r15). r14's N2 bounded `close()` and left
    /// `captured` — THE SAME LOCK, NO ANNOUNCEMENT, and the call `run()` made
    /// FIRST — unbounded. `run()`'s normal-exit path read both buffers and
    /// only THEN closed, so the read that mattered was the starvable one.
    ///
    /// Reachable in production precisely in the case this runner exists to
    /// survive: the child exits 0 while a grandchild holds the inherited
    /// write end, so the drain never sees EOF, `join` spends its whole budget
    /// and the buffer is then read against a LIVE worker — one that unlocks
    /// and immediately re-locks thousands of times a second, which `NSLock`
    /// lets it win.
    ///
    /// MEASURED at r15, 8 cold trios of each order on the same fixture shape:
    ///
    ///   bare `captured` (r14's order)    4.8-342.4 ms, median 83.8
    ///   `closeAndCapture()` (this one)   0.13-0.96 ms, median 0.67
    ///
    /// The advertised bound is one poll interval, 20 ms — what the sibling
    /// `testCloseIsNotStarvedByAContinuouslyWrittenWriteEnd` asserts for
    /// `close()`. The bare capture exceeded it in 6 of those 8 trios, by
    /// 1.8x-13.7x; an earlier sweep of the same cell gave 7 of 8 by 4x-23x
    /// (1.8-577.6 ms, median 166.8) against 0.06-0.77 ms, median 0.15.
    ///
    /// Only the bounded half is ASSERTED: two of the eight starved trios came
    /// back under 10 ms, so a cell demanding that the unbounded order BE slow
    /// would be a cell that goes red on a quiet machine. The starved figure
    /// is printed instead, so it stays re-derivable on every run.
    ///
    /// MUTATION: swap the two lines inside `closeAndCapture()` (capture, then
    /// close) — r14's exact order. Red rate over 8 runs is in the commit
    /// message.
    func testCapturingOutputIsNotStarvedByAContinuouslyWrittenWriteEnd() throws {
        var starved: [Double] = []
        for _ in 0..<8 {
            let trio = try measureDrainEndWaitMilliseconds(
                ending: false, writers: 8, settle: 0.3
            )
            XCTAssertGreaterThan(trio.bytes, 0, "the fixture never fed the drain")
            starved.append(trio.waited)
        }
        print(
            "MEASURED-DRAIN-BARE-CAPTURE-MS",
            starved.sorted().map { String(format: "%.4f", $0) }
        )

        var waits: [Double] = []
        for _ in 0..<8 {
            let trio = try measureDrainEndWaitMilliseconds(
                ending: true, writers: 8, settle: 0.3
            )
            XCTAssertGreaterThan(
                trio.bytes, 0,
                "the capture must carry the flood's bytes — a close that "
                    + "emptied the buffer would satisfy a timing bound by "
                    + "losing the output"
            )
            waits.append(trio.waited)
        }
        let sorted = waits.sorted()
        let median = sorted[sorted.count / 2]
        print(
            "MEASURED-DRAIN-CLOSE-AND-CAPTURE-MS",
            sorted.map { String(format: "%.4f", $0) }
        )
        XCTAssertLessThan(
            median, 25,
            "median cold `closeAndCapture()` wait \(median) ms against a live "
                + "stream; the advertised bound is one poll interval, 20 ms "
                + "(samples: \(sorted))"
        )
    }

    /// N2 (PR #460 codex r14). `drain()` took `lock`, entered
    /// `readAvailable: while true` and `continue`d on every `count > 0`
    /// WITHOUT releasing it — so a descriptor being written continuously kept
    /// the turn, and the lock, alive indefinitely. `close()` takes the same
    /// lock before it can set `isClosed`, so the runner's advertised bounded
    /// termination was bypassed in precisely the inherited-write-end case its
    /// own comments say it handles.
    ///
    /// The header claimed the 20 ms poll interval "bounds how long `close()`
    /// can wait for the lock". It bounded NEITHER half of the real wait: the
    /// unbounded read turn rides in FRONT of the poll, and even a short turn
    /// starves a waiter because the worker unlocks and immediately re-locks,
    /// which `NSLock` lets it win.
    ///
    /// Seven cold trios rather than one: a single sample from a barging lock
    /// is a coin flip, and the MEDIAN is what separates the two régimes
    /// cleanly. Measured red rates for both mutations are in the commit
    /// message.
    ///
    /// MUTATION A (the turn bound): delete the `readsThisTurn >=
    /// Self.maxReadsPerLockedBatch` break in `drain()`.
    /// MUTATION B (the announcement): drop the `stateLock`/`closeRequested`
    /// half — `close()` back to taking `lock` first, and the worker back to
    /// re-acquiring unconditionally.
    func testCloseIsNotStarvedByAContinuouslyWrittenWriteEnd() throws {
        var waits: [Double] = []
        for _ in 0..<7 {
            waits.append(try measureCloseWaitMilliseconds(writers: 8, settle: 0.3))
        }
        let sorted = waits.sorted()
        let median = sorted[sorted.count / 2]
        XCTAssertLessThan(
            median, 25,
            "median cold `close()` wait \(median) ms against a live stream; "
                + "the advertised bound is one poll interval, 20 ms "
                + "(samples: \(sorted))"
        )
    }

    /// The TURN BOUND, at the only seam that can see it.
    ///
    /// `drain()`'s read turn used to have no exit but EOF, a read error, or
    /// the descriptor running dry — it `continue`d, holding `lock`, for as
    /// long as bytes kept arriving, and `close()` needs that lock before it
    /// can set `isClosed`. Announcing a close does not help against that
    /// shape: the announcement is only read BETWEEN turns.
    ///
    /// A pipe cannot express the shape. MEASURED against a faithful copy of
    /// the loop at commit 08deb6e, a reader of this shape outruns every
    /// writer this suite can spawn (52k EAGAINs/s behind eight `yes`
    /// processes, 375k behind one; longest turn seen 116 ms), so a pipe turn
    /// ends on its own and deleting the bound reddens no pipe-fed cell —
    /// `testCloseIsNotStarvedByAContinuouslyWrittenWriteEnd` was measured
    /// GREEN with it deleted, 8 runs, and so was a twelve-trio variant fed by
    /// `yes` (that variant is not in the suite: no mutation of the turn bound
    /// could redden it, so it evidenced nothing this cell does not).
    /// A regular file does
    /// express it exactly: `read` returns a full buffer every time until EOF
    /// and never EAGAIN, which is what a write end held open and written to
    /// continuously looks like from inside the loop.
    ///
    /// The double is LESS capable than production, never more: a file cannot
    /// block, cannot be closed by a peer, and reaches a real EOF — so a
    /// mutation cannot hide behind it.
    ///
    /// MUTATION: delete the `readsThisTurn >= Self.maxReadsPerLockedBatch`
    /// break in `drain()` — RED here, because `close()` then waits out the
    /// whole gibibyte.
    func testAReadTurnThatNeverRunsDryStillEndsOnItsOwnBound() throws {
        // A SPARSE gibibyte: no disk is consumed and no bytes are written,
        // but every read returns 64 KiB of it.
        let file = base.appendingPathComponent("never-dry.bin")
        XCTAssertTrue(fm.createFile(atPath: file.path, contents: nil))
        let writing = try FileHandle(forWritingTo: file)
        XCTAssertEqual(ftruncate(writing.fileDescriptor, 1 << 30), 0)
        try writing.close()

        let reading = try FileHandle(forReadingFrom: file)
        let drain = PipeDrain(readingFrom: reading)
        drain.start()
        // Long enough that the worker is provably inside a turn.
        Thread.sleep(forTimeInterval: 0.05)

        let started = DispatchTime.now().uptimeNanoseconds
        drain.close()
        let waited = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6

        XCTAssertLessThan(
            waited, 25,
            "cold `close()` waited \(waited) ms behind a descriptor that never "
                + "runs dry; the advertised bound is one poll interval, 20 ms"
        )
        XCTAssertTrue(
            drain.join(within: 5), "the worker must return once the close lands"
        )
    }

    // MARK: - D17 profiles, per COMMAND class

    private func assertReadOnlyProfile(
        _ invocation: GitCommandInvocation,
        _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(invocation.profile, .readOnly, label, file: file, line: line)
        XCTAssertEqual(
            Array(invocation.argv.prefix(3)), ["git", "-c", "core.fsmonitor=false"],
            "\(label): fsmonitor neutralization on argv", file: file, line: line
        )
        XCTAssertEqual(
            invocation.environment["GIT_OPTIONAL_LOCKS"], "0",
            "\(label): GIT_OPTIONAL_LOCKS=0 in the environment", file: file, line: line
        )
    }

    private func assertMutationProfile(
        _ invocation: GitCommandInvocation,
        _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(invocation.profile, .mutation, label, file: file, line: line)
        XCTAssertEqual(
            Array(invocation.argv.prefix(3)), ["git", "-c", "core.fsmonitor=false"],
            "\(label): fsmonitor neutralization rides on mutations too",
            file: file, line: line
        )
        XCTAssertNil(
            invocation.environment["GIT_OPTIONAL_LOCKS"],
            "\(label): mutations need real locking", file: file, line: line
        )
    }

    func testEveryReadOnlyCommandCarriesTheReadOnlyProfile() async throws {
        let runner = GitCommandRunner(environment: try emptyPathEnvironment())
        let commands: [(String, [String])] = [
            ("status", ["-C", "/tmp", "status", "--porcelain", "--ignore-submodules=none"]),
            ("worktree list", ["-C", "/tmp", "-c", "gc.worktreePruneExpire=now",
                               "worktree", "list", "--porcelain", "-z"]),
            ("rev-parse", ["-C", "/tmp", "rev-parse", "--verify", "--quiet", "refs/heads/main"]),
            ("symbolic-ref", ["-C", "/tmp", "symbolic-ref", "refs/remotes/origin/HEAD"]),
            ("merge-base", ["-C", "/tmp", "merge-base", "--is-ancestor", "HEAD", "main"]),
            ("show", ["-C", "/tmp", "show", "-s", "--format=%cI", "HEAD"]),
            ("version", ["--version"])
        ]
        for (label, arguments) in commands {
            assertReadOnlyProfile(await runner.run(arguments), label)
        }
    }

    /// The CLASSIFIER, not the app's behaviour: since PR #460 codex r5 the
    /// app issues no mutating git command at all — `worktree remove` and
    /// `worktree prune` are both gone. What is pinned here is that the
    /// fail-closed default arm still withholds the read-only relaxations from
    /// an argv that is not on the read-only allowlist, which is what protects
    /// the NEXT command anyone adds.
    func testWorktreeMutationsCarryTheMutationProfile() async throws {
        let runner = GitCommandRunner(environment: try emptyPathEnvironment())
        assertMutationProfile(
            await runner.run(["-C", "/tmp", "worktree", "remove", "/tmp/wt"]),
            "worktree remove"
        )
        assertMutationProfile(
            await runner.run(["-C", "/tmp", "worktree", "prune", "--expire=now"]),
            "worktree prune"
        )
    }

    func testUnrecognizedCommandsFallBackToTheMutationProfile() {
        // The conservative direction: GIT_OPTIONAL_LOCKS=0 is never handed
        // to a command that might write.
        XCTAssertEqual(GitSafetyProfile.classify(["commit", "-m", "x"]), .mutation)
        XCTAssertEqual(GitSafetyProfile.classify(["worktree", "add", "/tmp/x"]), .mutation)
        XCTAssertEqual(GitSafetyProfile.classify(["worktree"]), .mutation)
        XCTAssertEqual(GitSafetyProfile.classify([]), .mutation)
    }

    func testClassificationSkipsGlobalOptionValuesSoTheyCannotMasquerade() {
        // `-C worktree` must not read as the `worktree` command, and
        // `-c core.x=status` must not read as `status`.
        XCTAssertEqual(
            GitSafetyProfile.classify(["-C", "worktree", "commit"]), .mutation
        )
        XCTAssertEqual(
            GitSafetyProfile.classify(["-c", "core.x=status", "worktree", "remove", "/x"]),
            .mutation
        )
        XCTAssertEqual(
            GitSafetyProfile.classify(["-C", "status", "worktree", "list"]), .readOnly
        )
        XCTAssertEqual(
            GitSafetyProfile.command(in: ["-C", "/x", "-c", "a=b", "worktree", "list"]).name,
            "worktree"
        )
        XCTAssertEqual(
            GitSafetyProfile.command(in: ["-C", "/x", "-c", "a=b", "worktree", "list"]).subcommand,
            "list"
        )
    }

    // MARK: - The poisoned fsmonitor helper never runs

    func testPoisonedFsmonitorHelperNeverExecutesDuringARunnerDrivenStatus() async throws {
        let repository = base.appendingPathComponent("fsmonitor-repo")
        try GitFixture.makeRepository(at: repository, home: home)

        let sentinel = base.appendingPathComponent("fsmonitor.sentinel")
        let helper = base.appendingPathComponent("poisoned-fsmonitor.sh")
        try """
        #!/bin/bash
        echo poisoned > "\(sentinel.path)"
        exit 1
        """.write(to: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        try GitFixture.git(
            ["-C", repository.path, "config", "core.fsmonitor", helper.path], home: home
        )
        try GitFixture.git(
            ["-C", repository.path, "config", "core.fsmonitorHookVersion", "2"], home: home
        )

        // TEETH: without the neutralization the helper DOES run.
        try GitFixture.git(
            ["-C", repository.path, "status", "--porcelain", "--ignore-submodules=none"],
            home: home
        )
        XCTAssertTrue(
            fm.fileExists(atPath: sentinel.path),
            "control: an un-neutralized status executes the fsmonitor helper"
        )
        try fm.removeItem(at: sentinel)

        // The runner-driven status must NOT.
        let runner = GitCommandRunner(environment: GitFixture.environment(home: home))
        let invocation = await runner.run(
            ["-C", repository.path, "status", "--porcelain", "--ignore-submodules=none"]
        )
        assertReadOnlyProfile(invocation, "poisoned-repo status")
        XCTAssertFalse(
            fm.fileExists(atPath: sentinel.path),
            "the fsmonitor helper must never execute under the read-only profile"
        )
    }

    // MARK: - Instance-scoped availability cache

    func testAvailabilityCacheIsInstanceScopedAndDoesNotPoisonOtherInstances() async throws {
        let unavailable = GitCommandRunner(environment: try emptyPathEnvironment())
        let firstVerdict = await unavailable.isGitAvailable()
        XCTAssertFalse(firstVerdict)
        let refused = await unavailable.run(["worktree", "list", "--porcelain", "-z"])
        XCTAssertEqual(refused.outcome, .gitUnavailable)

        // A SECOND instance backed by an INJECTED known-good stub git — no
        // dependence on the host's layout in either direction.
        let stubs = base.appendingPathComponent("stubs-good")
        _ = try GitFixture.makeStubGit(in: stubs, body: "echo ok\nexit 0\n")
        let available = GitCommandRunner(
            environment: stubEnvironment(pathDirectories: [stubs])
        )
        let secondVerdict = await available.isGitAvailable()
        XCTAssertTrue(secondVerdict, "a fresh instance probes its OWN environment")
        let stubRun = await available.run(["status"])
        guard case .success(let stdout) = stubRun.outcome else {
            return XCTFail("the stub-backed instance must execute")
        }
        XCTAssertEqual(String(decoding: stdout, as: UTF8.self), "ok\n")

        // … and the first instance's verdict is unchanged.
        let firstVerdictAgain = await unavailable.isGitAvailable()
        XCTAssertFalse(firstVerdictAgain)
    }

    func testAvailabilityIsProbedOnceAndThenCached() async throws {
        let stubs = base.appendingPathComponent("stubs-counting")
        let counter = base.appendingPathComponent("probe-count")
        try fm.createDirectory(at: stubs, withIntermediateDirectories: true)
        // A stub that RECORDS every `--version` probe it is asked to answer.
        let script = """
        #!/bin/bash
        for argument in "$@"; do
          if [ "$argument" = "--version" ]; then
            printf 'p' >> "\(counter.path)"
            echo "git version 2.99.0-stub"
            exit 0
          fi
        done
        exit 0
        """
        let stub = stubs.appendingPathComponent("git")
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let runner = GitCommandRunner(environment: stubEnvironment(pathDirectories: [stubs]))
        for _ in 0..<4 { _ = await runner.run(["status"]) }
        _ = await runner.isGitAvailable()

        let probes = (try? String(contentsOf: counter, encoding: .utf8)) ?? ""
        XCTAssertEqual(probes, "p", "the availability probe runs exactly once per instance")
    }

    // MARK: - Shape guarantees

    func testTheNewGitFilesNeverConstructAShellString() throws {
        for relativePath in [
            "Sources/Cacheout/Scanner/GitCommandRunner.swift",
            "Sources/Cacheout/Scanner/GitWorktreeInventory.swift"
        ] {
            let code = try repoSource(relativePath)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            XCTAssertGreaterThan(code.count, 500, "\(relativePath): the gate read real code")
            for forbidden in ["/bin/bash", "/bin/sh", "/bin/zsh", "sh -c"] {
                XCTAssertFalse(
                    code.contains(forbidden),
                    "\(relativePath) must never build a shell invocation (\(forbidden))"
                )
            }
        }
    }

    func testRunnerIsUsableFromAnActorContextAndInjectableAsATestDouble() async throws {
        let scripted = ScriptedGitRunner(outcome: .timeout)
        let client = GitRunnerActorClient(runner: scripted)
        let scriptedInvocation = await client.version()
        XCTAssertEqual(scriptedInvocation.outcome, .timeout)

        let real = GitCommandRunner(environment: try emptyPathEnvironment())
        let realClient = GitRunnerActorClient(runner: real)
        let realInvocation = await realClient.version()
        XCTAssertEqual(realInvocation.outcome, .gitUnavailable)
    }
}
