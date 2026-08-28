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

    /// Reads a pid a stub wrote to `url`, or `nil` while it has not yet.
    private func recordedPid(at url: URL) -> pid_t? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// **C8 — THE TIMEOUT KILLED THE PARENT AND LEFT WHAT IT SPAWNED
    /// RUNNING** (PR #460 codex r18).
    ///
    /// Both termination steps targeted `process.processIdentifier` alone. A
    /// timed-out `git` that had spawned a descendant — a helper used while
    /// inspecting a submodule — therefore lost its parent and kept the
    /// descendant, which goes on holding the inherited pipe write end and
    /// traversing repositories after the runner has returned `.timeout`.
    ///
    /// `…SigtermIgnoringStubIsEscalatedToSigkill…` could not see it: its
    /// fixture launches `sleep`, and it asserts only on the SHELL's pid.
    /// This cell asserts on the DESCENDANT's. The stub blocks in `wait` — a
    /// BUILTIN, so it spawns exactly ONE extra process and every pid this
    /// cell creates is accounted for — and the descendant is
    /// `( trap '' TERM; exec sleep 300 )`, i.e. a single process, at the pid
    /// `$!` records, whose SIGTERM disposition is SIG_IGN and SURVIVES the
    /// `exec`. So the descendant dies of neither a signal aimed at the
    /// parent nor a SIGTERM aimed at the group. The shell itself takes the
    /// DEFAULT disposition and exits inside the grace, which makes this
    /// specifically the arm where the parent is already gone and the
    /// escalation has to be decided on the GROUP.
    ///
    /// MUTATIONS, each measured on this fixture with the target rebuilt,
    /// `swift test --filter …testATimedOutCommandsDescendantIsKilledWithIt`
    /// — one per ARM of the fix, because the two are independent:
    ///
    /// | mutation | result |
    /// |---|---|
    /// | `signal(_:to:group:)` aimed at the pid alone | RED 8/8 |
    /// | `treeStillThere` pinned to `false` (no group escalation) | RED 8/8 |
    ///
    /// The parent assertion passes on every one of those runs, which is
    /// exactly the blind spot `…SigtermIgnoringStubIsEscalatedToSigkill…`
    /// has: its fixture launches `sleep` and it checks only the shell's pid.
    func testATimedOutCommandsDescendantIsKilledWithIt() async throws {
        let stubs = base.appendingPathComponent("stubs-descendant")
        let parentPidFile = base.appendingPathComponent("parent.pid")
        let childPidFile = base.appendingPathComponent("descendant.pid")
        _ = try GitFixture.makeStubGit(in: stubs, body: """
        export PATH=/bin:/usr/bin
        echo $$ > "\(parentPidFile.path)"
        ( trap '' TERM; exec sleep 300 ) &
        echo $! > "\(childPidFile.path)"
        wait
        """)
        // HYGIENE: whatever this test spawns dies with it, mutation or not.
        defer {
            for file in [parentPidFile, childPidFile] {
                if let pid = recordedPid(at: file), pid > 0 {
                    kill(pid, SIGKILL)
                }
            }
        }
        let runner = GitCommandRunner(
            environment: stubEnvironment(pathDirectories: [stubs]),
            defaultTimeout: 30,
            terminationGrace: 0.5,
            drainJoinBudget: 1
        )
        let invocation = await runner.run(["status", "--porcelain"], timeout: 0.5)
        XCTAssertEqual(invocation.outcome, .timeout)

        XCTAssertTrue(
            waitUntil(5) { self.recordedPid(at: childPidFile) != nil },
            "the stub must have recorded the descendant it spawned"
        )
        let parent = try XCTUnwrap(recordedPid(at: parentPidFile))
        let descendant = try XCTUnwrap(recordedPid(at: childPidFile))
        XCTAssertNotEqual(parent, descendant)
        XCTAssertTrue(
            waitUntil(5) { kill(parent, 0) != 0 },
            "the timed-out child itself must be gone"
        )
        XCTAssertTrue(
            waitUntil(5) { kill(descendant, 0) != 0 },
            "the descendant must be killed WITH its parent — an orphan of a "
                + "timed-out git goes on holding the inherited pipe and "
                + "traversing repositories after the runner has answered"
        )
    }

    /// **C7 — A NORMAL EXIT WHOSE DRAIN NEVER FINISHED WAS REPORTED AS A
    /// COMPLETE SUCCESS** (PR #460 codex r18).
    ///
    /// Third finding on the same four statements: r14 bounded `close()`, r15
    /// bounded the capture, and the JOIN's own RESULT was dropped by both.
    /// It is not a boundedness bug — `closeAndCapture()` is bounded either
    /// way — it is a TRUNCATION bug. A drain reaches EOF only when every
    /// write end is closed, so a join that times out after git has exited
    /// means something git SPAWNED still holds the inherited write end; the
    /// close that follows drops whatever is still unread (its own disclosed
    /// cost), and the short bytes went back as `.success(stdout:)`, which the
    /// porcelain parsers downstream COUNT.
    ///
    /// The fixture is exactly that shape: the stub starts a grandchild that
    /// holds the inherited stdout and never closes it, and then EXITS 0
    /// itself. So the runner takes the normal-exit path — `waitForExit`
    /// succeeds — and the drain can never see EOF.
    ///
    /// THE HOLDER IS SILENT ON PURPOSE, AND THAT IS A MEASUREMENT, NOT A
    /// PREFERENCE. A holder that WRITES dies of SIGPIPE the instant the drain
    /// closes the read end, which hides the second half of the fix: with a
    /// `( while :; do echo drip; sleep 0.02; done ) &` holder, deleting
    /// `terminate(process, group:)` from this path is GREEN 8/8 — the writer
    /// dies of the close either way. `( exec sleep 300 )` never writes, so
    /// only the signal can end it.
    ///
    /// MUTATIONS, target rebuilt, `swift test --filter
    /// …testAnUnfinishedDrainOnANormalExitIsNotReportedAsSuccess`, one per
    /// ARM:
    ///
    /// | mutation | result |
    /// |---|---|
    /// | drop `guard stdoutJoined, stderrJoined` (r15's two bare joins) | RED 8/8 (2 failures) |
    /// | drop `terminate(process, group:)` from the join-failure arm | RED 8/8 (1 failure) |
    ///
    /// Unmutated GREEN 8/8, no stray process left in any state.
    func testAnUnfinishedDrainOnANormalExitIsNotReportedAsSuccess()
        async throws
    {
        let stubs = base.appendingPathComponent("stubs-outliving-holder")
        let holderPidFile = base.appendingPathComponent("holder.pid")
        _ = try GitFixture.makeStubGit(in: stubs, body: """
        export PATH=/bin:/usr/bin
        # A GRANDCHILD holding the inherited stdout and never closing it …
        ( exec sleep 300 ) &
        echo $! > "\(holderPidFile.path)"
        # … and the stub itself exits 0, so the runner takes the NORMAL path.
        echo done
        exit 0
        """)
        defer {
            if let pid = recordedPid(at: holderPidFile), pid > 0 {
                kill(pid, SIGKILL)
            }
        }
        let runner = GitCommandRunner(
            environment: stubEnvironment(pathDirectories: [stubs]),
            defaultTimeout: 30,
            terminationGrace: 0.5,
            drainJoinBudget: 0.5
        )
        // The per-invocation budget is generous: nothing here TIMES OUT in
        // the expiry sense, and a `.timeout` proves the join arm answered.
        let invocation = await runner.run(["status", "--porcelain"], timeout: 20)
        XCTAssertEqual(
            invocation.outcome, .timeout,
            "output that could not be read to completion must not be handed "
                + "back as a complete `.success`"
        )

        // AND THE ORPHAN IS REAPED (C8's protocol, on C7's path): the thing
        // holding the pipe is what stopped the drain, so leaving it running
        // would leak a holder per invocation.
        let holder = try XCTUnwrap(recordedPid(at: holderPidFile))
        XCTAssertTrue(
            waitUntil(5) { kill(holder, 0) != 0 },
            "the descendant that outlived git must not be left running"
        )
    }

    /// Repo root from this file's own path — the idiom
    /// `SourceAnchorIntegrityTests` uses, so a moved test file cannot make
    /// the fence below silently scan nothing.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Swift source with every comment blanked, newlines and therefore line
    /// numbering preserved. Line comments are blanked because a trailing
    /// `// try require(` laundered a bare call as checked in the first
    /// version of the fence below; block comments because one sitting between
    /// a wrapper and its operand would otherwise read as a missing wrapper.
    /// String literals are skipped, so a `//` inside one is not a comment.
    private func commentsBlanked(_ source: String) -> String {
        var out = ""
        out.reserveCapacity(source.count)
        var index = source.startIndex
        var inString = false
        var escaped = false
        while index < source.endIndex {
            let character = source[index]
            let after = source.index(after: index)
            let next: Character? = after < source.endIndex ? source[after] : nil
            if inString {
                out.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                index = after
                continue
            }
            if character == "\"" {
                inString = true
                out.append(character)
                index = after
                continue
            }
            if character == "/", next == "/" {
                while index < source.endIndex, source[index] != "\n" {
                    out.append(" ")
                    index = source.index(after: index)
                }
                continue
            }
            if character == "/", next == "*" {
                var depth = 1
                out.append("  ")
                index = source.index(index, offsetBy: 2)
                while index < source.endIndex, depth > 0 {
                    let inner = source[index]
                    let ahead = source.index(after: index)
                    let peek: Character? =
                        ahead < source.endIndex ? source[ahead] : nil
                    if inner == "/", peek == "*" {
                        depth += 1
                        out.append("  ")
                        index = source.index(index, offsetBy: 2)
                        continue
                    }
                    if inner == "*", peek == "/" {
                        depth -= 1
                        out.append("  ")
                        index = source.index(index, offsetBy: 2)
                        continue
                    }
                    out.append(inner == "\n" ? "\n" : " ")
                    index = source.index(after: index)
                }
                continue
            }
            out.append(character)
            index = after
        }
        return out
    }

    /// The balanced-brace extent of the body of the function whose
    /// declaration begins with `signature`.
    ///
    /// The first version bounded the region with `range(of: "\n    }\n")`,
    /// which is not a function's end but the first four-space-indented `}`
    /// INSIDE it. Everything past such a brace escaped the fence in silence
    /// while the vacuity floor still passed on the checked calls above the
    /// cut. Braces are counted from the body's `{` — the first one outside
    /// the parameter list — with string literals skipped.
    private func functionBody(
        startingWith signature: String, in source: String
    ) -> Range<String.Index>? {
        guard let declaration = source.range(of: signature) else { return nil }
        var parenDepth = 0
        var braceDepth = 0
        var bodyStart: String.Index?
        var inString = false
        var escaped = false
        var index = declaration.lowerBound
        while index < source.endIndex {
            let character = source[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                index = source.index(after: index)
                continue
            }
            switch character {
            case "\"": inString = true
            case "(": parenDepth += 1
            case ")": parenDepth -= 1
            case "{":
                if bodyStart == nil, parenDepth == 0 { bodyStart = index }
                if bodyStart != nil { braceDepth += 1 }
            case "}":
                if let begin = bodyStart {
                    braceDepth -= 1
                    if braceDepth == 0 {
                        return begin..<source.index(after: index)
                    }
                }
            default: break
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// EVERY SPAWN-SETUP SYMBOL IS CHECKED — asserted over the source,
    /// because the failure cannot be staged from outside (PR #461 codex r1
    /// P2, rebuilt twice by the merge gate).
    ///
    /// The defect: `posix_spawn_file_actions_*` and `posix_spawnattr_*`
    /// allocate, so under transient pressure they answer ENOMEM — and
    /// discarding that answer is not a lost message, it is a SILENTLY
    /// DIFFERENT CHILD. A dropped `adddup2` leaves git's stdout attached to
    /// whatever descriptor 1 already was: git exits 0, the drain sees an
    /// immediate EOF, and the EMPTY buffer is accepted as a complete answer —
    /// the exact class fn-4.24 closed at the execute boundary, re-entering
    /// through the spawn. A dropped attribute call defeats fn-4.27's group
    /// isolation just as quietly.
    ///
    /// NEGATIVE RESULT, recorded rather than worked around: no behavioural
    /// cell can stage this. `launch` takes `Pipe`s and builds its own
    /// descriptors, and `adddup2` does not validate that a descriptor is
    /// OPEN at setup time (only that it is non-negative), so a closed pipe
    /// does not reach the guard — it throws an ObjC exception from
    /// `fileDescriptor` first, one layer earlier. Staging real ENOMEM is not
    /// available to a test. Reshaping `launch` to accept raw descriptors
    /// purely to make the failure reachable would widen production API for
    /// evidence, which this project declines.
    ///
    /// THE PROPERTY IS ON THE SYMBOL, NOT THE CALL. Two rebuilds ago this
    /// fence enumerated six names; one rebuild ago it matched
    /// `posix_spawn…\s*\(` and required the wrapper immediately in front.
    /// Both were keyed on a CALL, and the gate walked through the gap that
    /// leaves: `let addclose = posix_spawn_file_actions_addclose` followed by
    /// `_ = addclose(&fileActions, 5)` names the symbol with no paren after
    /// it and calls it under a name the fence has never heard of — compiled
    /// and run to confirm it is working Swift. So the assertion is now: every
    /// appearance of a `posix_spawn*` identifier in the spawn path is the
    /// direct operand of `try require(`. A function value cannot be taken
    /// without naming the symbol, so aliasing is caught at the alias.
    ///
    /// Exemptions are by property or by name, never by pattern: identifiers
    /// ending `_t` are types, the two `destroy` calls run in `defer` with
    /// nothing to report to, and `posix_spawn` itself is checked by its own
    /// `guard`. ACKNOWLEDGED LIMIT: a symbol reached through `dlsym` by
    /// string is outside what any source fence can see.
    ///
    /// MUTATION: drop any `try require(` back to a bare call and this reds,
    /// naming `GitCommandRunner.swift:<line>` and the offending line — as do
    /// the alias, `_ =`, comment-laundering and `setsigmask` escapes.
    /// Reformats stay green: a wrapper split across lines, `try require (`
    /// with a space, a comment between wrapper and operand.
    func testEverySpawnSetupCallIsChecked() throws {
        let source = commentsBlanked(
            try String(
                contentsOf: repositoryRoot.appendingPathComponent(
                    "Sources/Cacheout/Scanner/GitCommandRunner.swift"
                ),
                encoding: .utf8
            )
        )
        guard let bodyRange = functionBody(
            startingWith: "static func launch(", in: source
        ) else { return XCTFail("the spawn path could not be located") }
        let body = String(source[bodyRange])
        XCTAssertTrue(
            body.contains("posix_spawn("),
            "the scanned region does not reach the spawn itself, so it was "
                + "truncated and anything past the cut escapes in silence"
        )

        let symbol = try NSRegularExpression(
            pattern: #"\bposix_spawn[A-Za-z0-9_]*\b"#
        )
        // The wrapper, by structure and not by spelling: any whitespace
        // between `try`, `require` and `(` and before the operand. A
        // correctly-wrapped call re-flowed across three lines was flagged by
        // the line-anchored version — a reformat reddening correct code.
        let wrapper = #"try\s+require\s*\(\s*$"#
        let exemptNames: Set<String> = [
            "posix_spawn_file_actions_destroy", "posix_spawnattr_destroy",
            "posix_spawn",
        ]

        let firstLine = source[source.startIndex..<bodyRange.lowerBound]
            .reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        var unchecked: [String] = []
        var checked = 0
        let whole = NSRange(body.startIndex..<body.endIndex, in: body)
        for match in symbol.matches(in: body, range: whole) {
            guard let range = Range(match.range, in: body) else { continue }
            let name = String(body[range])
            guard !name.hasSuffix("_t"), !exemptNames.contains(name)
            else { continue }
            let prefix = body[body.startIndex..<range.lowerBound]
            if prefix.range(of: wrapper, options: .regularExpression) != nil {
                checked += 1
                continue
            }
            let line = prefix.reduce(firstLine) { $1 == "\n" ? $0 + 1 : $0 }
            let lineStart = prefix.lastIndex(of: "\n")
                .map(body.index(after:)) ?? body.startIndex
            let text = body[lineStart...].prefix { $0 != "\n" }
                .trimmingCharacters(in: .whitespaces)
            unchecked.append(
                "GitCommandRunner.swift:\(line)  \(name)  —  "
                    + text.prefix(90)
            )
        }
        XCTAssertGreaterThanOrEqual(
            checked, 7,
            "found \(checked) wrapped setup symbols — fewer than the seven "
                + "the spawn path names, so this fence has gone vacuous"
        )
        XCTAssertEqual(
            unchecked, [],
            "an unchecked spawn-setup call spawns a silently different child: "
                + "a dropped adddup2 leaves git's stdout elsewhere, git exits "
                + "0, and the empty buffer is accepted as a complete answer"
        )
    }

    /// child's process group with `getpgid` AFTER launch, so the group fact
    /// was contingent on observing a LIVE leader — a git that spawned a
    /// helper and exited left `group == nil`, and the termination protocol
    /// then signalled only the corpse's pid while the descendant ran on.
    /// `SpawnedProcess.launch` establishes the group at CREATION
    /// (`POSIX_SPAWN_SETPGROUP`): the group id IS the pid, leader dead or
    /// alive, and nothing about signalling is conditional on liveness.
    ///
    /// The fixture is the defect's exact shape: the leader records its pid,
    /// spawns a TERM-immune descendant that holds the inherited stdout, and
    /// exits 0 — so by the time any signal is sent, the leader is LONG dead
    /// (asserted below, not assumed). The runner's join arm answers
    /// `.timeout` and the descendant must die BY PID anyway, which only the
    /// group — established at spawn — can reach.
    ///
    /// MUTATION (fn-4.27 acceptance): restoring post-launch discovery —
    /// `signalTree` consulting `getpgid(pid)` and requiring `== pid` before
    /// group-signalling, r18's semantics — turns THIS cell red 8/8 (the
    /// leader is provably reaped before `terminate`, so discovery always
    /// fails and the descendant survives), while the unmutated cell is
    /// green 8/8. Recorded in the fn-4.27 commit.
    func testALeaderThatExitsImmediatelyStillHasItsDescendantReapedByPid()
        async throws
    {
        let stubs = base.appendingPathComponent("stubs-exited-leader")
        let leaderPidFile = base.appendingPathComponent("leader.pid")
        let descendantPidFile = base.appendingPathComponent("exited-leader-descendant.pid")
        _ = try GitFixture.makeStubGit(in: stubs, body: """
        export PATH=/bin:/usr/bin
        echo $$ > "\(leaderPidFile.path)"
        ( trap '' TERM; exec sleep 300 ) &
        echo $! > "\(descendantPidFile.path)"
        exit 0
        """)
        // HYGIENE: whatever this test spawns dies with it, mutation or not.
        defer {
            if let pid = recordedPid(at: descendantPidFile), pid > 0 {
                kill(pid, SIGKILL)
            }
        }
        let runner = GitCommandRunner(
            environment: stubEnvironment(pathDirectories: [stubs]),
            defaultTimeout: 30,
            terminationGrace: 0.5,
            drainJoinBudget: 0.5
        )
        let invocation = await runner.run(["status", "--porcelain"], timeout: 20)

        // WHICH arm fired: the leader exited normally, so this is the
        // unfinished-drain refusal — never the expiry arm, never `.success`.
        XCTAssertEqual(invocation.outcome, .timeout)

        let leader = try XCTUnwrap(recordedPid(at: leaderPidFile))
        let descendant = try XCTUnwrap(recordedPid(at: descendantPidFile))
        XCTAssertNotEqual(leader, descendant)
        // The PRECONDITION the cell exists for, asserted rather than
        // assumed: the leader was already unsignallable when the runner
        // answered — a group fact discovered from a live leader could not
        // have existed here.
        XCTAssertNotEqual(
            kill(leader, 0), 0,
            "the leader must already be gone — this cell is about signalling "
                + "AFTER the leader's death"
        )
        XCTAssertTrue(
            waitUntil(5) { kill(descendant, 0) != 0 },
            "the descendant must be reaped BY PID after .timeout — only the "
                + "spawn-established group can reach it once the leader is dead"
        )
    }

    // MARK: - A hard read error is not EOF (fn-4.24)

    /// Serial call counter for the drain factory seam. `execute` builds its
    /// drains on ONE thread in a pinned source order, and a runner's first
    /// `run` makes exactly four: the availability probe's stdout (1) and
    /// stderr (2), then the command's stdout (3) and stderr (4). Locked
    /// anyway so the cell asserts the count without a data-race caveat.
    private final class DrainBuildCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// A `PipeDrain` whose `read(2)` fails HARD on the first call: a
    /// directory descriptor, `EISDIR` (errno 21) — the reproduction the task
    /// spec measured (PR #460 round 18, runner scope).
    private func drainOverADirectoryDescriptor(named name: String) throws -> PipeDrain {
        let directory = base.appendingPathComponent(name)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(
            descriptor, 0, "opening a directory read-only cannot fail here"
        )
        return PipeDrain(
            readingFrom: FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        )
    }

    /// The drain-level half of fn-4.24, with its EOF control.
    ///
    /// DEFECT (measured before the fix): a drain whose `read(2)` died hard
    /// ended EXACTLY like EOF — `finished` signalled, `join(within:)` true,
    /// nothing recorded — so `execute` had no fact to read and shipped the
    /// partial buffer as `.success`. The cell asserts WHICH failure ended
    /// the drain (EISDIR, not merely "some refusal"), and the control shows
    /// a genuine EOF records nothing, so the two endings are distinguishable.
    func testADrainThatDiedOnAHardReadErrorRecordsTheErrnoInsteadOfPosingAsEOF() throws {
        let drain = try drainOverADirectoryDescriptor(named: "read-error-target")
        drain.start()
        XCTAssertTrue(
            drain.join(within: 5),
            "a hard read error must still END the drain — polling a broken "
                + "descriptor would spin forever"
        )
        XCTAssertEqual(
            drain.terminalReadFailure, EISDIR,
            "the drain died on EISDIR; a died-on-error ending that records "
                + "nothing is indistinguishable from EOF, which is what let "
                + "a partial buffer ship as `.success` (fn-4.24)"
        )
        XCTAssertEqual(
            drain.closeAndCapture(), Data(),
            "no byte was ever readable from a directory descriptor"
        )

        // CONTROL: a drain that reaches genuine EOF records NO failure —
        // otherwise the execute gate would refuse every healthy invocation
        // and the cell above could be passing for the wrong reason.
        let pipe = Pipe()
        let eofDrain = PipeDrain(pipe: pipe)
        eofDrain.start()
        try pipe.fileHandleForWriting.write(contentsOf: Data("complete\n".utf8))
        try pipe.fileHandleForWriting.close()
        XCTAssertTrue(eofDrain.join(within: 5), "EOF must end the control drain")
        XCTAssertNil(
            eofDrain.terminalReadFailure,
            "a clean EOF is not a read failure; recording one here would "
                + "turn every healthy run into a refusal"
        )
        XCTAssertEqual(eofDrain.closeAndCapture(), Data("complete\n".utf8))
    }

    /// The execute-boundary half of fn-4.24, stdout arm: git exits 0, the
    /// STDOUT drain dies on a hard read error (a real EISDIR descriptor via
    /// the factory seam), and the invocation must be `.timeout` — never a
    /// `.success` whose short stdout a porcelain parser will count as a
    /// repository with fewer worktrees.
    ///
    /// CONTROL FIRST: the same stub through default drains is a plain
    /// `.success` carrying the expected bytes, so the refusal below cannot
    /// be the fixture refusing for reasons of its own. And the refusal is
    /// pinned to the read-failure GATE, not the join guard: a died-on-error
    /// drain joins within milliseconds, and the mutation run that deletes
    /// the gate turns exactly this cell green-to-red via `.success`.
    func testAHardStdoutReadErrorAfterANormalExitIsRefusedNotShippedAsSuccess() async throws {
        let stubs = base.appendingPathComponent("stubs-stdout-read-error")
        _ = try GitFixture.makeStubGit(in: stubs, body: """
        echo "worktree /tmp/x"
        exit 0
        """)

        let control = GitCommandRunner(
            environment: stubEnvironment(pathDirectories: [stubs]),
            defaultTimeout: 30
        )
        let controlRun = await control.run(["worktree", "list"], timeout: 20)
        guard case .success(let stdout) = controlRun.outcome else {
            return XCTFail(
                "CONTROL: the stub itself must succeed through default "
                    + "drains, got \(controlRun.outcome)"
            )
        }
        XCTAssertTrue(
            String(decoding: stdout, as: UTF8.self).contains("worktree /tmp/x"),
            "CONTROL: the stub's stdout must arrive intact"
        )

        let calls = DrainBuildCounter()
        // Built OUTSIDE the factory closure: the closure cannot throw, and
        // the strand fence rightly forbids `try!` in a test source.
        let broken = try drainOverADirectoryDescriptor(named: "broken-stdout-fd")
        let runner = GitCommandRunner(
            environment: stubEnvironment(pathDirectories: [stubs]),
            defaultTimeout: 30,
            drainFactory: { pipe in
                // Call 3 is the COMMAND'S stdout drain; the probe (1, 2) and
                // the command's stderr (4) stay healthy.
                if calls.next() == 3 { return broken }
                return PipeDrain(pipe: pipe)
            }
        )
        let invocation = await runner.run(["worktree", "list"], timeout: 20)
        XCTAssertEqual(
            calls.count, 4,
            "the factory must have built the probe's two drains and the "
                + "command's two — a different count means the broken drain "
                + "was not the command's stdout"
        )
        XCTAssertEqual(
            invocation.outcome, .timeout,
            "a stdout drain that died on a hard read error must be refused "
                + "at the execute boundary; before fn-4.24 it ended like EOF "
                + "and the truncated buffer shipped as `.success` — a "
                + "porcelain listing with fewer worktrees"
        )
    }

    /// The stderr arm of the same gate: a truncated stderr is a truncated
    /// answer too (on the failure path it is THE answer), so either drain
    /// dying on a hard read error refuses the invocation.
    func testAHardStderrReadErrorAfterANormalExitIsRefusedNotShippedAsSuccess() async throws {
        let stubs = base.appendingPathComponent("stubs-stderr-read-error")
        _ = try GitFixture.makeStubGit(in: stubs, body: """
        echo "worktree /tmp/x"
        exit 0
        """)

        let control = GitCommandRunner(
            environment: stubEnvironment(pathDirectories: [stubs]),
            defaultTimeout: 30
        )
        let controlRun = await control.run(["worktree", "list"], timeout: 20)
        guard case .success = controlRun.outcome else {
            return XCTFail(
                "CONTROL: the stub itself must succeed through default "
                    + "drains, got \(controlRun.outcome)"
            )
        }

        let calls = DrainBuildCounter()
        let broken = try drainOverADirectoryDescriptor(named: "broken-stderr-fd")
        let runner = GitCommandRunner(
            environment: stubEnvironment(pathDirectories: [stubs]),
            defaultTimeout: 30,
            drainFactory: { pipe in
                // Call 4 is the COMMAND'S stderr drain.
                if calls.next() == 4 { return broken }
                return PipeDrain(pipe: pipe)
            }
        )
        let invocation = await runner.run(["worktree", "list"], timeout: 20)
        XCTAssertEqual(calls.count, 4, "probe (2) + command (2) drains")
        XCTAssertEqual(
            invocation.outcome, .timeout,
            "a stderr drain that died on a hard read error must refuse the "
                + "invocation exactly like the stdout arm — fail closed on "
                + "either stream"
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
    /// ## THIS CELL IS PROBABILISTIC, AND ITS COMMIT SAID IT WAS NOT
    /// ## (PR #460 codex r16, B-P3)
    ///
    /// Commit a269fc8 recorded "RED 8/8 runs, mutated medians 26.2-146.3 ms"
    /// and "UNMUTATED: GREEN 8/8, worst single sample 1.75 ms". Neither
    /// figure survived re-measurement:
    ///
    /// - the reviewer's controlled comparison (same machine, same fixture,
    ///   one variable) put the mutant at RED 6/8 — runs whose medians were
    ///   13.7064 ms and 8.6280 ms exited 0 — with mutant medians spanning
    ///   8.63-138.67 ms, and put the UNMUTATED worst single sample at
    ///   9.2457 ms across 64 trios, 5x the recorded figure;
    /// - re-measured here at r16: mutant RED 15/16 over two 8-run sweeps (the
    ///   one green run's eight samples were all under 10 ms, max 9.9261),
    ///   and unmutated GREEN 24/24 over three 8-run sweeps — 192 cold
    ///   samples, worst single sample 4.1117 ms.
    ///
    /// So the true red rate is load-dependent and no single number states it.
    /// A regression restoring r14's starving order ships GREEN some runs.
    ///
    /// WHAT CHANGED HERE. The assertion is no longer the median alone: NO
    /// sample of the eight may exceed the advertised 20 ms bound. That is
    /// what the reviewer's two green mutant runs would have failed — a median
    /// of 13.7 ms is not a bounded wait, it is a distribution whose tail is
    /// already past the bound — and it costs nothing unmutated, where 192
    /// cold samples peaked at 4.1117 ms (a 4.9x margin). It does NOT make the
    /// cell deterministic and is not claimed to: a mutant on a quiet machine
    /// still passes it.
    ///
    /// WHAT MAKES THE REGRESSION UN-SHIPPABLE is therefore not this cell but
    /// `testTheDrainIsEndedOnlyThroughTheBoundedSpelling`, which reads the
    /// production source and pins the ORDER inside `closeAndCapture()` and
    /// the fact that nothing else in the tree reads the buffer. That one is
    /// RED 8/8 on the same mutation, deterministically. Until r16 the
    /// property "PRODUCTION NEVER CALLS THIS DIRECTLY", asserted in
    /// `PipeDrain.captured`'s own doc, was enforced by NOTHING: a grep over
    /// `Tests/` for a fence, an allowlist or a source cell mentioning
    /// `captured` returned nothing at all.
    ///
    /// MUTATION: swap the two lines inside `closeAndCapture()` (capture, then
    /// close) — r14's exact order. Measured red rates above.
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
        var byteCounts: [Int] = []
        for _ in 0..<8 {
            let trio = try measureDrainEndWaitMilliseconds(
                ending: true, writers: 8, settle: 0.3
            )
            byteCounts.append(trio.bytes)
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
        print("MEASURED-DRAIN-CLOSE-AND-CAPTURE-BYTES", byteCounts)
        XCTAssertLessThan(
            median, 25,
            "median cold `closeAndCapture()` wait \(median) ms against a live "
                + "stream; the advertised bound is one poll interval, 20 ms "
                + "(samples: \(sorted))"
        )
        // THE AGGREGATE, not the median alone (PR #460 codex r16, B-P3). A
        // median inside the bound with a tail well past it is exactly what
        // the starved order looks like on a half-loaded machine, and it is
        // what let the mutant exit 0 in two of the reviewer's eight runs.
        // Unmutated this costs nothing: 192 cold samples peaked at 4.1117 ms.
        let overBound = sorted.filter { $0 > 20 }
        XCTAssertEqual(
            overBound.count, 0,
            "\(overBound.count) of \(sorted.count) cold `closeAndCapture()` "
                + "waits exceeded the advertised 20 ms poll interval "
                + "(\(overBound)); a bounded call has no tail past its own "
                + "bound (all samples: \(sorted), bytes: \(byteCounts))"
        )
    }


    /// **THE FENCE THAT MAKES THE ORDER UN-SHIPPABLE** (PR #460 codex r16,
    /// B-P3).
    ///
    /// `PipeDrain.captured`'s own doc says "PRODUCTION NEVER CALLS THIS
    /// DIRECTLY; `closeAndCapture()` does, in the bounded order". Until this
    /// cell existed that sentence was enforced by NOTHING — a grep over
    /// `Tests/` for a fence, an allowlist or a source cell mentioning
    /// `captured` returned nothing — and the only thing standing between the
    /// repository and r14's starving order was
    /// `testCapturingOutputIsNotStarvedByAContinuouslyWrittenWriteEnd`, a
    /// TIMING cell measured at RED 15/16 on that exact mutation. One run in
    /// sixteen, the regression ships.
    ///
    /// Three propositions, read off the production tree rather than off a
    /// convention:
    ///
    /// 1. `closeAndCapture()`'s body CLOSES BEFORE IT READS. The bound comes
    ///    entirely from that order: `close()` is the only call that announces
    ///    itself through `stateLock`/`closeRequested`, so the snapshot after
    ///    it runs against a worker that is provably not going to contend
    ///    again. Reversed, the snapshot parks behind a barging worker.
    /// 2. NOTHING ELSE IN THE PRODUCTION TREE READS THE BUFFER. Every
    ///    `captured` outside that body is either the property's own
    ///    declaration or a comment; a name like `capturedStdout` is a
    ///    different word and is not matched.
    /// 3. `PipeDrain` is constructed in ONE production file. A second file
    ///    building one is a second end-a-drain path that this cell has no
    ///    reason to have checked.
    ///
    /// TWO LAYERS, because `captured` legitimately appears throughout the
    /// prose that explains the rule: layer 1 is the narrow claim that must
    /// return ZERO, layer 2 is the full inventory with each line categorised,
    /// so a reviewer sees what was admitted and why rather than trusting a
    /// regex.
    ///
    /// MUTATION: swap the two statements inside `closeAndCapture()` — RED
    /// 8/8, deterministically, which is the whole point of adding it beside a
    /// probabilistic cell rather than instead of one.
    func testTheDrainIsEndedOnlyThroughTheBoundedSpelling() throws {
        let relative = "Sources/Cacheout/Scanner/GitCommandRunner.swift"
        let source = try repoSource(relative)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        XCTAssertGreaterThan(
            lines.count, 400,
            "the fence must have read the runner, not an empty file"
        )

        // ---- (1) THE ORDER INSIDE `closeAndCapture()` --------------------
        let signature = "    func closeAndCapture() -> Data {"
        let opened = try XCTUnwrap(
            lines.firstIndex(of: signature),
            "`closeAndCapture()` is gone or was re-spelled — the bounded "
                + "spelling this fence pins no longer exists"
        )
        let closed = try XCTUnwrap(
            lines[(opened + 1)...].firstIndex(of: "    }"),
            "the body of `closeAndCapture()` never ends at its own indent"
        )
        let body = Array(lines[(opened + 1)..<closed])
        XCTAssertFalse(body.isEmpty, "the body reader found nothing")
        let closeAt = try XCTUnwrap(
            body.firstIndex { $0.contains("close()") },
            "`closeAndCapture()` no longer closes at all: \(body)"
        )
        let captureAt = try XCTUnwrap(
            body.firstIndex { line in
                line.range(of: "\\bcaptured\\b", options: .regularExpression) != nil
            },
            "`closeAndCapture()` no longer reads the buffer: \(body)"
        )
        XCTAssertLessThan(
            closeAt, captureAt,
            "`closeAndCapture()` reads the buffer BEFORE it closes — r14's "
                + "starving order. The bound is the announcement: only "
                + "`close()` sets `closeRequested`, and only after it has "
                + "does the snapshot run against a worker that will not "
                + "contend again. Body: \(body)"
        )

        // ---- (2) NOTHING ELSE READS THE BUFFER ---------------------------
        func isComment(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("//") || trimmed.hasPrefix("///")
        }
        // LAYER 2, the inventory: every production line mentioning the word,
        // categorised. LAYER 1 is `unexplained` and must be empty.
        var declaration: [String] = []
        var insideBoundedSpelling: [String] = []
        var prose: [String] = []
        var unexplained: [String] = []
        // Scoped to the ONE file that can name the property: `captured` is
        // an ordinary English word and an ordinary local name elsewhere in
        // the tree (`PathGuard`, `WorktreeReclaimPerformer`, `CacheCleaner`),
        // and none of those lines can touch a drain. What makes the scope
        // sufficient is (3) below: no other production file so much as
        // mentions `PipeDrain`, so no other file can hold one to read.
        for (offset, line) in lines.enumerated() {
            guard line.range(
                of: "\\bcaptured\\b", options: .regularExpression
            ) != nil else { continue }
            let anchor = "\(relative):\(offset + 1)"
            if isComment(line) {
                prose.append(anchor)
            } else if line == "    var captured: Data {" {
                declaration.append(anchor)
            } else if offset > opened, offset < closed {
                insideBoundedSpelling.append(anchor)
            } else {
                unexplained.append(
                    "\(anchor): \(line.trimmingCharacters(in: .whitespaces))"
                )
            }
        }
        XCTAssertEqual(
            unexplained, [],
            "production reads `PipeDrain.captured` outside the bounded "
                + "spelling. That read takes the drain's lock WITHOUT "
                + "announcing itself, so it parks behind a worker that "
                + "unlocks and immediately re-locks — the starvation r15 "
                + "measured at an 83.8 ms median against an advertised 20 ms"
        )
        XCTAssertEqual(
            declaration.count, 1,
            "the buffer accessor must be declared exactly once: \(declaration)"
        )
        XCTAssertEqual(
            insideBoundedSpelling.count, 1,
            "`closeAndCapture()` must read the buffer exactly once: "
                + "\(insideBoundedSpelling)"
        )
        XCTAssertFalse(prose.isEmpty, "the inventory read no comments at all "
                           + "— layer 2 has stopped parsing")

        // ---- (3) ONE FILE CAN EVEN NAME A DRAIN --------------------------
        // This is what makes (2)'s single-file scope sufficient, so it is not
        // a decorative extra: a `PipeDrain` held anywhere else would be a
        // second end-a-drain path with no fence over it.
        var mentions: [String] = []
        for file in try productionSwiftSources() where
            file.lastPathComponent != "GitCommandRunner.swift"
        {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (offset, line) in text.split(
                separator: "\n", omittingEmptySubsequences: false
            ).enumerated() where line.contains("PipeDrain")
                && !isComment(String(line))
            {
                mentions.append(
                    "\(file.lastPathComponent):\(offset + 1): "
                        + "\(line.trimmingCharacters(in: .whitespaces))"
                )
            }
        }
        XCTAssertEqual(
            mentions, [],
            "another production file has CODE naming `PipeDrain`, so it can "
                + "hold one and read its buffer — and layer 2 above only "
                + "looked at \(relative). (Comments naming the type are "
                + "admitted: prose explaining the rule is not a use of it.)"
        )
    }

    /// Every `.swift` under `Sources/Cacheout` — the tree the fence above
    /// makes its claims about.
    private func productionSwiftSources() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CacheoutTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Cacheout")
        var files: [URL] = []
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        )
        while let next = enumerator?.nextObject() as? URL {
            if next.pathExtension == "swift" { files.append(next) }
        }
        XCTAssertGreaterThan(
            files.count, 20, "the production tree was not read"
        )
        return files
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

    /// A TRANSIENT failure must not be remembered as "git is not installed"
    /// (PR #460 codex r21).
    ///
    /// `availability()` converted every non-success probe outcome to `false`
    /// and cached it for the runner's lifetime. So one `Process.run()` hitting
    /// EMFILE/EBADF under momentary pressure, or one probe timing out, left
    /// every later scan and clean answering `gitUnavailable` until the app was
    /// restarted — telling the user to install software they already have.
    /// Ask the standing question this branch asks of every refusal: can a
    /// retry differ? For exit 127 it cannot; for a launch failure it can.
    ///
    /// The transient failure is staged the way it really happens — the
    /// executable is momentarily not runnable (mode 000), then it is. No
    /// injected outcome; `Process.run()` genuinely throws on the first call.
    ///
    /// MUTATION: restore the unconditional `cachedAvailability = available`
    /// and the recovery assertion goes red — the runner keeps answering
    /// `.gitUnavailable` after the host recovers.
    func testATransientLaunchFailureIsNotCachedAsGitBeingAbsent()
        async throws
    {
        let stubs = base.appendingPathComponent("stubs-transient")
        try fm.createDirectory(at: stubs, withIntermediateDirectories: true)
        let stub = stubs.appendingPathComponent("git")
        try """
        #!/bin/bash
        echo "git version 2.99.0-stub"
        exit 0
        """.write(to: stub, atomically: true, encoding: .utf8)
        // NOT RUNNABLE YET — `Process.run()` throws, which is the transient
        // class (EMFILE/EBADF/EACCES), not "the tool is missing".
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: stub.path)

        let runner = GitCommandRunner(
            environment: try emptyPathEnvironment(), executableURL: stub
        )
        let duringPressure = await runner.run(["--version"])
        XCTAssertEqual(
            duringPressure.outcome, .gitUnavailable,
            "an unrunnable executable is still gitUnavailable"
        )
        XCTAssertFalse(
            duringPressure.unavailabilityIsDefinitive,
            "a throwing launch is NOT a definitive not-found — only exit 127 is"
        )

        // The host recovers.
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let afterRecovery = await runner.run(["--version"])
        guard case .success = afterRecovery.outcome else {
            return XCTFail(
                "the runner remembered a transient failure and never retried — "
                    + "stale-worktree work stays disabled until the app is "
                    + "restarted. Got \(afterRecovery.outcome)"
            )
        }
    }

    /// The other half: exit 127 IS definitive, and IS remembered
    /// (PR #460 codex r21). Without this, "cache only definitive" could be
    /// satisfied by caching nothing, which would re-probe forever on a host
    /// with no git.
    func testADefinitiveNotFoundIsRememberedAndNotReProbed() async throws {
        let stub = base.appendingPathComponent("stubs/exit127-definitive")
        try GitFixture.makeUnavailableStub(at: stub)
        let runner = GitCommandRunner(
            environment: try emptyPathEnvironment(), executableURL: stub
        )
        let first = await runner.run(["--version"])
        XCTAssertEqual(first.outcome, .gitUnavailable)
        XCTAssertTrue(
            first.unavailabilityIsDefinitive,
            "exit 127 from the launcher is the one answer a retry cannot change"
        )
        let second = await runner.run(["worktree", "list"])
        XCTAssertEqual(
            second.outcome, .gitUnavailable,
            "a definitive absence stays remembered"
        )
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
