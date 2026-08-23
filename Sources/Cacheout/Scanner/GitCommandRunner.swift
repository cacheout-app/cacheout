/// # GitCommandRunner — the ONE git subprocess seam (fn-5.1, R9 / D17)
///
/// Every git invocation the stale-worktree epic makes — scan-time assessment
/// AND delete-time mutation — flows through this runner. It is a NEW
/// component, not a refactor of `CacheCleaner.runCleanCommand`: that one is
/// `private` and nulls both output streams, which is useless for porcelain
/// parsing. What IS cloned is its process discipline — `/usr/bin/env`,
/// argv-only (never a shell), a fixed PATH, an injected `HOME`, and a
/// BOUNDED wait via `Process.waitForExit(within:)` (a bare
/// `waitUntilExit()` misses its termination wakeup under concurrent
/// spawning/reaping — house doctrine, see `CacheCategory.swift`).
///
/// ## What this runner adds over the cleaner's
///
/// - **Captured stdout AND stderr**, drained CONCURRENTLY on background
///   workers that start BEFORE the wait. `git worktree list --porcelain`
///   or `git status` on a large tree easily exceeds the 64 KiB pipe buffer;
///   a wait-then-read design deadlocks (child blocked writing, parent
///   blocked waiting). The drains use bounded non-blocking reads rather
///   than `readabilityHandler` EOF, whose EOF notification is known to be
///   missed (SR-12080).
/// - **A FULL termination protocol on timeout expiry.** `terminate()` alone
///   is insufficient twice over: a child that ignores SIGTERM survives it,
///   and open pipe FDs wedge the reader joins. The pinned sequence is
///   `terminate()` → bounded grace wait → `SIGKILL` if still running →
///   close the pipe file handles → boundedly join BOTH drain workers. Every
///   step is bounded, so the runner returns `.timeout` even against a
///   SIGTERM-ignoring child, with no wedged reader and no surviving child.
///   "Every step" INCLUDES the close, which is the step that used to be the
///   exception: it takes the drain's lock, and until PR #460 codex r14 the
///   drain could hold that lock indefinitely against a live stream. What
///   bounds it now is stated where it lives, on `PipeDrain`.
/// - **A per-INVOCATION timeout.** Scan fan-out uses the ~10 s default (the
///   2 s probe precedent is too tight for `status` on a multi-GB worktree;
///   the 30 s clean timeout is too loose for scan fan-out), while
///   delete-time dispatch passes its own generous minutes-scale budget
///   through the SAME parameter — a mid-removal timeout leaves partial
///   state, so that caller must be able to buy patience.
/// - **An INSTANCE-scoped availability cache.** The executable and the
///   environment are per-instance immutable configuration, so a
///   process-global cache would let an empty-PATH instance poison a fresh
///   production-default one. The cache is guarded by an `NSLock` (house
///   precedent: `InstalledAppResolver`) with a probe-once-under-lock rule.
///
/// ## D17 — safety profiles are classified by COMMAND, never by call phase
///
/// Read-only git is NOT inherently side-effect-free: `status` writes
/// optional-lock/index-refresh state and EXECUTES the repo-configured
/// `core.fsmonitor` helper — and this epic deliberately runs read-only git
/// against parent repositories OUTSIDE the effective dev roots. So the
/// profile follows the COMMAND, wherever it runs:
///
/// - **Read-only** (`status`, `worktree list`, `rev-parse`, `symbolic-ref`,
///   `merge-base`, `show`, `--version`): `GIT_OPTIONAL_LOCKS=0` in the
///   environment (no optional-lock/index writes; git ≥ 2.15) AND
///   `-c core.fsmonitor=false` on argv (boolean form ≥ 2.35.1). Both clear
///   the macOS-14 / Apple-Git-2.39 floor. This applies at delete time too —
///   fn-5.4's status re-check and porcelain oracle recompute are read-only
///   COMMANDS and carry this profile.
/// - **Mutation** (anything NOT on the read-only allowlist — the fail-closed
///   default, `GitSafetyProfile.classify`): keeps `-c core.fsmonitor=false`
///   but NOT `GIT_OPTIONAL_LOCKS=0`, because a mutation needs real locking.
///   NO COMMAND THE APP ISSUES CLASSIFIES THIS WAY ANY MORE (PR #460 codex
///   r5/r6): the last two were `worktree remove` and `worktree prune`, and
///   both are gone — this process performs both removals itself. The profile
///   stays because it is the DEFAULT arm: an unrecognised or malformed argv
///   still lands here rather than being granted the read-only relaxations.
///
/// DECIDED and deliberately NOT neutralized, with reasons: `core.hooksPath`
/// (none of the listed commands run hooks), external diff/textconv drivers
/// (porcelain status never invokes an external diff), pagers (output is
/// captured over non-tty pipes, so git does not page).
///
/// `-c core.fsmonitor=false` is prepended to EVERY invocation regardless of
/// profile, so the one config-driven external-command executor in this
/// command set can never run. Only the environment differs by profile.
///
/// ## Availability
///
/// A cached `git --version` probe. `/usr/bin/env` exits 127 when the tool is
/// not on PATH, and a launch failure of `env` itself is the same class of
/// answer — both map to `.gitUnavailable`, never to a silent empty result.
/// Caveat worth encoding: on a toolchain-less machine the CLT shim at
/// `/usr/bin/git` pops a GUI installer and exits nonzero, so the probe
/// degrades to a VISIBLE unavailable verdict (D6 discipline; fn-5.5
/// surfaces it as a scanner issue).

import Foundation

// MARK: - Safety profile (D17)

/// Which D17 safety profile an invocation ran under. Classified by COMMAND,
/// never by call phase — see the file header.
enum GitSafetyProfile: String, Equatable, Sendable {
    /// `GIT_OPTIONAL_LOCKS=0` + `-c core.fsmonitor=false`.
    case readOnly
    /// `-c core.fsmonitor=false` only — mutations need real locking.
    case mutation

    /// Bare git commands D17 classifies READ-ONLY.
    ///
    /// `rev-list` joined them in PR #460 codex r18 (C4) for the detached-HEAD
    /// preservation query. It is a pure traversal of the object graph — it
    /// writes no ref, no index and no object — so the read-only relaxations
    /// are the correct pair for it, and leaving it off would have handed the
    /// FALLBACK `.mutation` profile to a command that cannot mutate while the
    /// file's own note says no command the app issues classifies that way.
    static let readOnlyCommands: Set<String> = [
        "status", "rev-parse", "symbolic-ref", "merge-base", "show", "version",
        "rev-list",
    ]

    /// `git worktree <sub>` subcommands D17 classifies READ-ONLY.
    static let readOnlyWorktreeSubcommands: Set<String> = ["list"]

    /// `git worktree <sub>` subcommands D17 classifies as MUTATIONS.
    static let mutationWorktreeSubcommands: Set<String> = ["remove", "prune"]

    /// Global git options that consume the FOLLOWING argument as their
    /// value. Skipping their values is what lets `-C <dir>` and
    /// `-c gc.worktreePruneExpire=now` sit in front of the subcommand
    /// without confusing classification (a `-C worktree` would otherwise
    /// read as the `worktree` command).
    private static let valueTakingGlobalOptions: Set<String> = [
        "-C", "-c", "--git-dir", "--work-tree", "--namespace",
        "--exec-path", "--config-env", "--super-prefix"
    ]

    /// The command (and, for `worktree`, its subcommand) an argv addresses,
    /// with global options and their values skipped. `nil` name means the
    /// argv carried no subcommand at all (e.g. bare `--version`).
    static func command(in arguments: [String]) -> (name: String?, subcommand: String?) {
        var index = arguments.startIndex
        var sawVersionFlag = false
        while index < arguments.endIndex {
            let token = arguments[index]
            guard token.hasPrefix("-") else { break }
            if token == "--version" { sawVersionFlag = true }
            if valueTakingGlobalOptions.contains(token) {
                index = arguments.index(index, offsetBy: 2, limitedBy: arguments.endIndex)
                    ?? arguments.endIndex
            } else {
                index = arguments.index(after: index)
            }
        }
        guard index < arguments.endIndex else {
            return (sawVersionFlag ? "version" : nil, nil)
        }
        let name = arguments[index]
        let subIndex = arguments.index(after: index)
        // The first NON-option token after the command name is its
        // subcommand (`worktree --porcelain list` is not a real spelling,
        // but skipping options here costs nothing and cannot mislead).
        var cursor = subIndex
        while cursor < arguments.endIndex, arguments[cursor].hasPrefix("-") {
            cursor = arguments.index(after: cursor)
        }
        let subcommand = cursor < arguments.endIndex ? arguments[cursor] : nil
        return (name, subcommand)
    }

    /// TOTAL classification of an argv. Unrecognized commands fall back to
    /// `.mutation` — the conservative direction: `GIT_OPTIONAL_LOCKS=0` must
    /// never be handed to a command that might write, while
    /// `-c core.fsmonitor=false` rides on every invocation regardless. A
    /// fallback that guessed `.readOnly` would be the unsafe one.
    static func classify(_ arguments: [String]) -> GitSafetyProfile {
        let (name, subcommand) = command(in: arguments)
        guard let name else { return .mutation }
        if name == "worktree" {
            guard let subcommand else { return .mutation }
            if readOnlyWorktreeSubcommands.contains(subcommand) { return .readOnly }
            return .mutation
        }
        return readOnlyCommands.contains(name) ? .readOnly : .mutation
    }
}

// MARK: - Outcome & invocation record

/// The four EXECUTION classes every git call resolves to. Downstream
/// (fn-5.2/fn-5.4) routes on exactly these — nothing collapses a failure
/// into an empty success.
enum GitCommandOutcome: Equatable, Sendable {
    /// Exit 0. `stdout` is raw BYTES: porcelain `-z` output is NUL-delimited
    /// and must never round-trip through line splitting (D8).
    case success(stdout: Data)
    /// Non-zero exit, with git's own stderr (lossily decoded — stderr is a
    /// human message, never a path used as a deletion target).
    case failure(exitCode: Int32, stderr: String)
    /// The per-invocation budget expired; the full termination protocol ran.
    case timeout
    /// `env` could not find git (exit 127), the launch itself failed, or the
    /// instance's cached availability probe already said no.
    case gitUnavailable
}

/// One recorded git invocation: the profile it ran under, the FULL argv, the
/// FULL environment, and the outcome. Tests assert the D17 profile per
/// command class off `argv`/`environment` here, so the assertion sees
/// exactly what the child saw.
struct GitCommandInvocation: Equatable, Sendable {
    let profile: GitSafetyProfile
    /// Everything handed to the executable, starting with `git` (the
    /// `/usr/bin/env` shape) and the unconditional fsmonitor neutralization.
    let argv: [String]
    let environment: [String: String]
    let outcome: GitCommandOutcome
}

// MARK: - Injection seam

/// The injectable seam every fn-5 consumer depends on instead of the
/// concrete runner. `Sendable` so an actor (the scanner) and the cleaner can
/// share ONE instance.
protocol GitCommandRunning: Sendable {
    /// The scan-time default budget; delete-time callers pass their own.
    var defaultTimeout: TimeInterval { get }

    /// Run `git <arguments>` under a per-INVOCATION budget.
    func run(_ arguments: [String], timeout: TimeInterval) async -> GitCommandInvocation
}

extension GitCommandRunning {
    /// Convenience for scan-time callers that want the default budget.
    func run(_ arguments: [String]) async -> GitCommandInvocation {
        await run(arguments, timeout: defaultTimeout)
    }
}

// MARK: - Runner

/// `@unchecked Sendable` under an explicit lock discipline: every stored
/// property is immutable except `cachedAvailability`, which is only ever
/// read or written while `lock` is held.
final class GitCommandRunner: GitCommandRunning, @unchecked Sendable {

    // MARK: Pinned constants

    /// The fixed PATH, cloned VERBATIM from `CacheCleaner.runCleanCommand`
    /// so both subprocess surfaces resolve the same tools. Homebrew first —
    /// a modern git ahead of the CLT shim.
    static let productionPATH =
        "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin"

    /// Scan-time default budget. Deliberately between the 2 s probe
    /// precedent (too tight for `status` on a multi-GB worktree) and the
    /// 30 s clean timeout (too loose for scan fan-out).
    static let scanTimeout: TimeInterval = 10

    /// How long a SIGTERM is given before SIGKILL, and how long each drain
    /// worker is given to finish. Both bounded; both injectable so tests
    /// exercise the protocol without paying production-scale waits.
    static let defaultTerminationGrace: TimeInterval = 2
    static let defaultDrainJoinBudget: TimeInterval = 2

    /// The argv-side half of the D17 profiles, applied UNCONDITIONALLY —
    /// fsmonitor is the one config-driven external-command executor in this
    /// command set, and every command the app issues either IS `status` or
    /// runs the same status machinery.
    static let fsmonitorNeutralization = "core.fsmonitor=false"

    /// The environment-side half of the READ-ONLY profile.
    static let optionalLocksVariable = "GIT_OPTIONAL_LOCKS"

    /// `/usr/bin/env` — argv only, never a shell.
    static let defaultExecutable = URL(fileURLWithPath: "/usr/bin/env")

    /// The production environment: the cleaner-cloned PATH plus the injected
    /// HOME (a git that consults `$HOME` must see the fixture home in tests,
    /// never the real account).
    static func productionEnvironment(home: URL) -> [String: String] {
        ["PATH": productionPATH, "HOME": home.path]
    }

    // MARK: Stored configuration (immutable)

    private let executableURL: URL
    /// The base environment before the profile's own variables are layered
    /// on. Exposed for equality assertions — the production default must be
    /// provable WITHOUT executing anything.
    let baseEnvironment: [String: String]
    let defaultTimeout: TimeInterval
    private let terminationGrace: TimeInterval
    private let drainJoinBudget: TimeInterval

    // MARK: Mutable state (lock-guarded)

    private let lock = NSLock()
    private var cachedAvailability: Bool?

    // MARK: Init

    /// Full-override initializer. The ENTIRE environment is substitutable so
    /// unavailability can be proven HERMETICALLY (a PATH of one empty
    /// directory makes `env` exit 127 on every host) — the production PATH
    /// contains `/usr/bin`, where the CLT git shim usually lives, so no test
    /// may use it to prove absence.
    init(
        environment: [String: String],
        executableURL: URL = GitCommandRunner.defaultExecutable,
        defaultTimeout: TimeInterval = GitCommandRunner.scanTimeout,
        terminationGrace: TimeInterval = GitCommandRunner.defaultTerminationGrace,
        drainJoinBudget: TimeInterval = GitCommandRunner.defaultDrainJoinBudget
    ) {
        self.baseEnvironment = environment
        self.executableURL = executableURL
        self.defaultTimeout = defaultTimeout
        self.terminationGrace = terminationGrace
        self.drainJoinBudget = drainJoinBudget
    }

    /// Production initializer — the cleaner-cloned environment.
    convenience init(home: URL, defaultTimeout: TimeInterval = GitCommandRunner.scanTimeout) {
        self.init(
            environment: GitCommandRunner.productionEnvironment(home: home),
            defaultTimeout: defaultTimeout
        )
    }

    // MARK: Public surface

    func run(_ arguments: [String], timeout: TimeInterval) async -> GitCommandInvocation {
        await withCheckedContinuation { continuation in
            // Off the cooperative pool: the wait is a bounded poll that
            // blocks its thread, and an actor caller must never block on it.
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.runSynchronously(arguments, timeout: timeout))
            }
        }
    }

    /// The instance's cached `git --version` verdict.
    func isGitAvailable() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.availability())
            }
        }
    }

    /// Blocking core — the async entry points offload onto this. Exposed at
    /// module scope so callers already on a background queue (and tests) can
    /// use it without a hop.
    func runSynchronously(_ arguments: [String], timeout: TimeInterval) -> GitCommandInvocation {
        let profile = GitSafetyProfile.classify(arguments)
        guard availability() else {
            return GitCommandInvocation(
                profile: profile,
                argv: Self.argv(for: arguments),
                environment: environment(for: profile),
                outcome: .gitUnavailable
            )
        }
        return execute(arguments, profile: profile, timeout: timeout)
    }

    // MARK: Availability (instance-scoped, probe-once-under-lock)

    /// Check-probe-store under ONE lock acquisition: two concurrent first
    /// callers can never both spawn a probe, and the verdict a caller sees
    /// is always this instance's own.
    ///
    /// This DOES hold `lock` across a whole subprocess execution, which is
    /// the longest hold in the file. Stated rather than left to be
    /// discovered: it is bounded — `defaultTimeout` + the termination grace
    /// + SIGKILL reap + both drain joins, all of them injected — and it is
    /// paid at most once per instance. It is not the shape r14's N2 was
    /// about; there is no second unbounded hold here.
    private func availability() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let cachedAvailability { return cachedAvailability }
        let probe = execute(["--version"], profile: .readOnly, timeout: defaultTimeout)
        let available: Bool
        if case .success = probe.outcome { available = true } else { available = false }
        cachedAvailability = available
        return available
    }

    // MARK: Argv & environment assembly

    /// `git -c core.fsmonitor=false <caller argv…>`. The first element is
    /// the TOOL NAME because the executable is `/usr/bin/env`; an injected
    /// stub executable therefore also receives `git` as its first argument.
    private static func argv(for arguments: [String]) -> [String] {
        ["git", "-c", fsmonitorNeutralization] + arguments
    }

    private func environment(for profile: GitSafetyProfile) -> [String: String] {
        var environment = baseEnvironment
        if profile == .readOnly {
            environment[Self.optionalLocksVariable] = "0"
        }
        return environment
    }

    // MARK: Execution

    private func execute(
        _ arguments: [String], profile: GitSafetyProfile, timeout: TimeInterval
    ) -> GitCommandInvocation {
        let argv = Self.argv(for: arguments)
        let environment = environment(for: profile)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = argv
        process.environment = environment
        // git must never be able to prompt: an inherited terminal would let
        // a credential helper block the whole scan. /dev/null reads EOF.
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            // `env` itself is missing/unrunnable — the same class of answer
            // as "git is not on PATH", never a silent zero.
            return GitCommandInvocation(
                profile: profile, argv: argv, environment: environment,
                outcome: .gitUnavailable
            )
        }

        // Both drains start BEFORE the wait: either stream filling the
        // 64 KiB pipe buffer would otherwise block the child forever while
        // the parent waits for an exit that can never come.
        let stdoutDrain = PipeDrain(pipe: stdoutPipe)
        let stderrDrain = PipeDrain(pipe: stderrPipe)
        stdoutDrain.start()
        stderrDrain.start()

        guard process.waitForExit(within: timeout) else {
            terminate(process)
            // PINNED ORDER: close the pipe handles FIRST, then join. An open
            // FD is exactly what wedges a reader when the child (or a
            // grandchild that inherited the write end) is still holding it.
            stdoutDrain.close()
            stderrDrain.close()
            stdoutDrain.join(within: drainJoinBudget)
            stderrDrain.join(within: drainJoinBudget)
            return GitCommandInvocation(
                profile: profile, argv: argv, environment: environment,
                outcome: .timeout
            )
        }

        // Normal exit: the drains reach EOF on their own, so join first and
        // close after — closing early could truncate buffered output.
        //
        // PINNED ORDER, second half (PR #460 codex r15, S-P2): the capture
        // rides INSIDE the close. r14 bounded `close()` and left the read of
        // the buffer — the same lock, no announcement, and the call that used
        // to run FIRST — unbounded. `closeAndCapture()` is the only spelling
        // of this pair that is bounded; see its doc for the measurement.
        stdoutDrain.join(within: drainJoinBudget)
        stderrDrain.join(within: drainJoinBudget)
        let capturedStdout = stdoutDrain.closeAndCapture()
        let capturedStderr = stderrDrain.closeAndCapture()

        let status = process.terminationStatus
        if status == 0 {
            return GitCommandInvocation(
                profile: profile, argv: argv, environment: environment,
                outcome: .success(stdout: capturedStdout)
            )
        }
        if status == 127 {
            // `/usr/bin/env` could not find the tool.
            return GitCommandInvocation(
                profile: profile, argv: argv, environment: environment,
                outcome: .gitUnavailable
            )
        }
        return GitCommandInvocation(
            profile: profile, argv: argv, environment: environment,
            outcome: .failure(
                exitCode: status,
                stderr: String(decoding: capturedStderr, as: UTF8.self)
            )
        )
    }

    /// terminate → bounded grace → SIGKILL if still running → bounded reap
    /// wait. Every step bounded; a SIGTERM-ignoring child cannot survive it.
    private func terminate(_ process: Process) {
        process.terminate()
        guard !process.waitForExit(within: terminationGrace) else { return }
        let pid = process.processIdentifier
        if pid > 0 {
            kill(pid, SIGKILL)
        }
        _ = process.waitForExit(within: terminationGrace)
    }
}

// MARK: - Concurrent pipe drain

/// One background drain worker per stream.
///
/// Reads are NON-BLOCKING and woken by `poll(2)`, so the worker never sits
/// inside a blocking `read` that only an FD close could interrupt — that
/// interruption is a use-after-close race (the FD number can be reused the
/// instant it closes). Instead the close and every read are serialized on
/// one lock: a close can therefore never land mid-read, and the worker sees
/// `isClosed` and returns on its next turn. `readabilityHandler` is
/// deliberately unused — its EOF notification is known to be missed
/// (SR-12080), which would hang the join.
///
/// ## What bounds ending a drain (PR #460 codex r14 N2, r15 S-P2)
///
/// The worker holds `lock` across its whole turn — the 20 ms `poll` included
/// — so anything that needs the same lock waits for it. Only ONE call
/// announces itself and is therefore bounded: `close()`. Reading the buffer
/// does not, which is why production ends a drain through
/// `closeAndCapture()` and never through `captured` alone (S-P2: r14 bounded
/// `close()` and left the capture — the same lock, no announcement, and the
/// call that ran FIRST — unbounded, measured at an 83.8 ms median against an
/// advertised 20 ms).
///
/// TWO mechanisms used to be able to make `close()`'s own wait long, and the
/// poll interval bounded NEITHER of them:
///
/// 1. The read loop `continue`d on every `count > 0` WITHOUT releasing the
///    lock. A descriptor whose write end is held open and written to
///    continuously (the inherited-write-end case this runner exists to
///    survive: a grandchild outliving the child the runner SIGKILLs) kept
///    `read` returning bytes, so the turn — and the lock — never ended.
///    `maxReadsPerLockedBatch` ends every turn instead.
/// 2. Even a SHORT turn starves a waiter if the worker unlocks and
///    immediately re-locks: `NSLock` lets the re-locker barge past a parked
///    waiter, and this worker's outer loop does exactly that thousands of
///    times a second under a live stream. MEASURED at commit 08deb6e over a
///    pipe fed by eight `dd bs=64` writers: a competing lock acquisition
///    waited 21-616 ms (median 201 ms over 20 samples) against an advertised
///    20 ms. `closeRequested` — announced WITHOUT `lock` and read by the
///    worker before it contends — is what actually removes the contention:
///    the worker returns rather than re-acquiring, so the closer's wait is
///    one bounded turn, not an unbounded queue of them.
///
/// LOCK ORDER, and the only rule that matters: `stateLock` is NEVER held
/// while `lock` is acquired. `close()` takes `stateLock`, releases it, then
/// takes `lock`; the worker holds `lock` and takes `stateLock` briefly
/// inside it. Hold-and-wait therefore never forms.
///
/// `@unchecked Sendable`: `captured`/`isClosed` are only touched under
/// `lock`, `closeRequested` only under `stateLock`, and `handle` is only
/// used under `lock` as well.
///
/// INTERNAL rather than file-private so `GitCommandRunnerTests` can time
/// `close()` against a live flood
/// (`testCloseIsNotStarvedByAContinuouslyWrittenWriteEnd`), the whole
/// end-a-drain pair against the same flood
/// (`testCapturingOutputIsNotStarvedByAContinuouslyWrittenWriteEnd`), and
/// `close()` against a descriptor that never runs dry
/// (`testAReadTurnThatNeverRunsDryStillEndsOnItsOwnBound`). Nothing outside
/// this file constructs one.
final class PipeDrain: @unchecked Sendable {

    /// How long a single `poll` waits before the worker rechecks `isClosed`.
    private static let pollIntervalMilliseconds: Int32 = 20

    /// The most `read(2)` calls one LOCKED turn may make before it hands the
    /// lock back. Large enough that an ordinary burst is drained in one turn
    /// (16 x 64 KiB = 1 MiB, sixteen times the pipe's own capacity), small
    /// enough that a turn is microseconds even when every read is full.
    private static let maxReadsPerLockedBatch = 16

    private let handle: FileHandle
    private let lock = NSLock()
    /// Guards `closeRequested` ALONE. A second lock rather than a field on
    /// `lock` because its whole job is to be reachable while `lock` is held
    /// by the worker — that is what lets `close()` announce itself without
    /// queueing behind the very loop it is trying to stop.
    private let stateLock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var isClosed = false
    private var closeRequested = false

    init(pipe: Pipe) {
        handle = pipe.fileHandleForReading
    }

    /// A drain over an ARBITRARY read handle. Production passes a pipe and
    /// nothing else; this exists so a test can hand the loop a descriptor
    /// that NEVER runs dry, which is the only scope that can notice
    /// `maxReadsPerLockedBatch`. A macOS pipe cannot be that scope: measured
    /// at commit 08deb6e, a reader of this shape outruns every writer this
    /// suite can spawn — 52k EAGAINs/s behind eight `yes` processes, 375k
    /// behind one — so a pipe turn ends on its own before the bound is
    /// reached, and deleting the bound reddens no pipe-fed cell.
    init(readingFrom handle: FileHandle) {
        self.handle = handle
    }

    /// Everything read so far, snapshotted under the lock — safe to call
    /// even if a join timed out and the worker is still running.
    ///
    /// NOT BOUNDED against a live worker, and not fixable in place: this
    /// takes `lock` WITHOUT announcing itself, so it parks behind a worker
    /// that unlocks and immediately re-locks, and `NSLock` hands the lock
    /// back to the barger. It is the same starvation `close()` was cured of
    /// at r14, on the same lock — the ONLY difference is the announcement.
    ///
    /// PRODUCTION NEVER CALLS THIS DIRECTLY; `closeAndCapture()` does, in the
    /// bounded order. It stays internal because a test may legitimately
    /// observe a drain that is deliberately still running.
    ///
    /// That sentence was ENFORCED BY NOTHING until PR #460 codex r16 (B-P3):
    /// no fence, no allowlist and no source cell anywhere under `Tests/` so
    /// much as mentioned `captured`, and the only thing standing against
    /// r14's starving order was a TIMING cell measured at RED 15/16 on that
    /// exact mutation. `testTheDrainIsEndedOnlyThroughTheBoundedSpelling`
    /// now pins it off the source: the order inside `closeAndCapture()`, the
    /// fact that nothing else in this file reads the buffer, and the fact
    /// that no other production file names `PipeDrain` at all.
    var captured: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    /// END the drain and take everything it read — the one bounded spelling
    /// of that pair, and what production uses.
    ///
    /// `close()` FIRST, because it is the only call that announces itself
    /// through `stateLock`: the worker sees `closeRequested` between turns
    /// and RETURNS instead of re-acquiring, so this wait is one turn (the
    /// 20 ms poll at worst) rather than an unbounded queue of them. The
    /// snapshot then runs against a worker that is provably not going to
    /// contend for the lock again.
    ///
    /// MEASURED on this branch at r15, 8 cold trios of EACH order against the
    /// same fixture (a `Pipe` fed by eight `dd bs=64` grandchild writers —
    /// the inherited-write-end case this runner exists to survive):
    ///
    ///   bare `captured` (r14's order)    4.8-342.4 ms, median 83.8
    ///   `closeAndCapture()` (this one)   0.13-0.96 ms, median 0.67
    ///
    /// Same lock, same load, same fixture — the announcement is the only
    /// difference. The figures move run to run (a second sweep gave
    /// 1.8-577.6 ms, median 166.8, against 0.06-0.77 ms, median 0.15) but the
    /// two régimes have never overlapped.
    /// `testCapturingOutputIsNotStarvedByAContinuouslyWrittenWriteEnd` re-prints
    /// both on every run and asserts the bounded half only — the starved half
    /// is recorded rather than asserted, because a cell that demands a wait BE
    /// long is a cell that goes red on a quiet machine.
    ///
    /// THAT CELL IS PROBABILISTIC (PR #460 codex r16, B-P3). Commit a269fc8
    /// recorded "RED 8/8" for the swapped-order mutation and a worst
    /// unmutated sample of 1.75 ms; re-measurement put the mutant at RED 6/8
    /// (reviewer) and RED 15/16 (here, two sweeps), and the worst unmutated
    /// sample at 9.2457 ms (reviewer) and 4.1117 ms over 192 samples (here).
    /// The cell now asserts the AGGREGATE — no sample past the 20 ms bound,
    /// not just the median — and the DETERMINISTIC guard on this order is
    /// the source fence `testTheDrainIsEndedOnlyThroughTheBoundedSpelling`,
    /// RED 8/8.
    ///
    /// WHAT THIS GIVES UP, stated rather than implied: after a join that
    /// timed out, closing before reading drops whatever is still sitting in
    /// the pipe unread. By construction those bytes are not the child's —
    /// the child has exited, so a join can only time out while some OTHER
    /// holder of the write end keeps it open, and the child's own bytes were
    /// drained inside the join budget (2 s against a 20 ms poll). The order
    /// this replaces did not reliably collect them either: it merely waited,
    /// unboundedly, for the lock while they arrived.
    func closeAndCapture() -> Data {
        close()
        return captured
    }

    func start() {
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        DispatchQueue.global(qos: .userInitiated).async {
            self.drain()
            self.finished.signal()
        }
    }

    /// Bounded join. Returns whether the worker finished within the budget;
    /// a timed-out join still leaves `captured` readable.
    @discardableResult
    func join(within timeout: TimeInterval) -> Bool {
        finished.wait(timeout: .now() + timeout) == .success
    }

    func close() {
        // ANNOUNCE FIRST, without `lock`. The worker reads this before it
        // contends for `lock` again, so it stops re-acquiring instead of
        // barging past this call.
        stateLock.lock()
        closeRequested = true
        stateLock.unlock()

        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        try? handle.close()
    }

    private var isCloseRequested: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closeRequested
    }

    private func drain() {
        var scratch = [UInt8](repeating: 0, count: 65_536)
        while true {
            // BEFORE contending: a closer that has announced itself must not
            // have to win a lock race against this loop. Returning here is
            // what makes its wait one turn rather than an unbounded queue of
            // them; `close()` still sets `isClosed` and closes the handle
            // under `lock`, which is now uncontended.
            if isCloseRequested { return }
            lock.lock()
            if isClosed {
                lock.unlock()
                return
            }
            let descriptor = handle.fileDescriptor
            var isDone = false
            // Set when the turn ended because it hit its bound rather than
            // because the descriptor ran dry — data is known to be waiting,
            // so the turn hands the lock back WITHOUT polling for it.
            var yieldedLock = false
            var readsThisTurn = 0
            readAvailable: while true {
                let count = read(descriptor, &scratch, scratch.count)
                if count > 0 {
                    buffer.append(contentsOf: scratch[0..<count])
                    readsThisTurn += 1
                    // THE BOUND. Without it a continuously written descriptor
                    // keeps this branch true forever and the lock is never
                    // handed back.
                    if readsThisTurn >= Self.maxReadsPerLockedBatch {
                        yieldedLock = true
                        break readAvailable
                    }
                    continue
                }
                if count == 0 {
                    isDone = true // EOF: every write end is closed.
                    break readAvailable
                }
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK {
                    break readAvailable // Nothing right now — go poll.
                }
                // A hard read error is terminal: polling a broken
                // descriptor would spin, and there is nothing left to read.
                isDone = true
                break readAvailable
            }
            if isDone {
                lock.unlock()
                return
            }
            if yieldedLock {
                lock.unlock()
                continue
            }
            // The poll is the ONE remaining bounded hold. Skipped outright
            // once a close is pending, so a closer never waits on a sleep
            // taken for a descriptor nobody is going to read again.
            if isCloseRequested {
                lock.unlock()
                return
            }
            var descriptors = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            _ = poll(&descriptors, 1, Self.pollIntervalMilliseconds)
            lock.unlock()
        }
    }
}
