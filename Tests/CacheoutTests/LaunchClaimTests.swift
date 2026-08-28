import XCTest
@testable import Cacheout

/// `LaunchClaim` — deciding and starting destructive work as ONE act
/// (PR #461 codex r1, corrected twice by the merge gate).
///
/// The defect: `FirstWinsRendezvous` decides which OUTCOME is reported, not
/// whether the work STARTED. A detached task still queued when the off-pool
/// timer wins observes nothing; the timeout branch sees `isRunning == false`,
/// reports truthfully that nothing runs, re-enables the button — and the task
/// is then scheduled and launches an unowned `docker system prune -f`.
///
/// THE FIRST FIX ONLY MOVED THAT WINDOW. A bare `begin()` followed by `run()`
/// on the next statement leaves the timer free to fire BETWEEN them:
/// `abandon()` answers false ("already started"), the caller reads
/// `didStart == true` with `isRunning == false` because the start has not run
/// yet, terminates nothing, reports it stopped — and the work then begins,
/// unowned. So `begin` performs the work under the lock.
///
/// AND THE FIRST VERSION OF THIS SUITE DID NOT CATCH THAT. Every cell read
/// `ran` after `begin` returned, or after `group.wait()` — instants at which
/// the body has run under EITHER shape. The merge gate reopened the window
/// verbatim (`decided = true; unlock(); try body()`) and the whole 1666-cell
/// suite stayed green; the mutation recorded in commit 36dff04 (dispatching
/// the start asynchronously) is strictly STRONGER than the defect, so the
/// synchronous near-miss was invisible to it. That claim is corrected here.
///
/// The observation has to be taken INSIDE the window — at the instant
/// `abandon()` answers false, before anything joins — and two cells now do
/// that: `testAbandonNeverAnswersFalseBeforeTheWorkHasRun` forces the instant
/// to exist deterministically, and the contention cell samples it 400 times.
final class LaunchClaimTests: XCTestCase {

    func testAbandonBeforeBeginStopsTheWorkAndSaysItNeverStarted() {
        let claim = LaunchClaim()
        var ran = false
        XCTAssertTrue(claim.abandon(), "the timer arrived first, so it wins")
        XCTAssertFalse(
            claim.begin({ ran = true }),
            "a task scheduled after the timeout must NOT start the work"
        )
        XCTAssertFalse(ran, "the body must not run once abandoned")
        XCTAssertFalse(
            claim.didStart,
            "nothing started, so the timeout branch has nothing to terminate "
                + "and must not claim it stopped anything"
        )
    }

    /// THE WINDOW ITSELF, observed at the only instant that can see it.
    ///
    /// `abandon()` answering false is a claim about the PAST — the work has
    /// already run — and it is only falsifiable while `begin` is still in
    /// flight. This cell manufactures that instant: the timer thread is
    /// released from inside the body, so it calls `abandon()` at a moment
    /// when the work provably has not finished, and it reads the witness
    /// immediately, before any join can paper over the answer.
    ///
    /// MUTATION (the near-miss the gate reopened): rewrite `begin` as
    /// `lock(); if decided { unlock(); return false }; decided = true;
    /// unlock(); try body(); lock(); started = true; unlock()`. Measured
    /// RED 12/12 — `abandon()` returns false with `ran` still false — against
    /// GREEN 12/12 unmutated, because there `abandon()` blocks on the claim's
    /// lock until the body has run. Before this cell existed the whole
    /// 1666-cell suite passed under that mutation.
    func testAbandonNeverAnswersFalseBeforeTheWorkHasRun() {
        let claim = LaunchClaim()
        let round = Round()
        let inBody = DispatchSemaphore(value: 0)
        let observed = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            inBody.wait()
            let stopped = claim.abandon()
            // THE OBSERVATION. Not after a join, not after `begin` returns:
            // here, where a false answer is still a checkable assertion.
            round.ranWhenAbandonAnswered = round.ran
            round.stopped = stopped
            observed.signal()
        }

        XCTAssertTrue(claim.begin({
            inBody.signal()
            // Time for the timer thread to actually reach `abandon()`. Under
            // the shipped shape it blocks on the claim's lock and this
            // changes nothing about the outcome; under the reopened window it
            // returns immediately, which is precisely the observation. The
            // assertion is on the ordering, never on the delay.
            Thread.sleep(forTimeInterval: 0.05)
            round.ran = true
        }))

        XCTAssertEqual(
            observed.wait(timeout: .now() + 5), .success,
            "the timer thread never returned from abandon()"
        )
        XCTAssertFalse(
            round.stopped, "the work had begun, so abandon must lose"
        )
        XCTAssertEqual(
            round.ranWhenAbandonAnswered, true,
            "abandon answered false — 'already started' — while the work had "
                + "NOT run. The timeout branch now reports that it stopped "
                + "something, terminates nothing, and the prune runs unowned."
        )
    }

    /// The SEQUENTIAL contract only: `begin` performs, it does not schedule.
    ///
    /// Renamed off its old name (`...MeansTheWorkHasAlreadyRun`), which
    /// overclaimed: reading `ran` after `begin` has returned cannot see the
    /// window, because by then the body has run under either shape. The
    /// window claim belongs to the two cells that observe inside it.
    func testBeginPerformsTheWorkRatherThanSchedulingIt() {
        let claim = LaunchClaim()
        var ran = false
        XCTAssertTrue(claim.begin({ ran = true }))
        XCTAssertTrue(ran, "begin performs the work; it does not schedule it")
        XCTAssertFalse(
            claim.abandon(),
            "the work is already running: the timer must be told so"
        )
        XCTAssertTrue(claim.didStart)
    }

    func testBeginIsNeverTrueTwiceAndRunsTheBodyOnce() {
        let claim = LaunchClaim()
        var runs = 0
        XCTAssertTrue(claim.begin({ runs += 1 }))
        XCTAssertFalse(claim.begin({ runs += 1 }))
        XCTAssertEqual(runs, 1, "one-shot: no second launch")
    }

    /// A throwing start spends the attempt but leaves nothing to terminate.
    ///
    /// This cell carries its own claim, not the window's: it reds when
    /// `started = true` moves ahead of `body()`, and stays green under the
    /// near-miss above. Recorded so a future round does not read it as
    /// window coverage.
    func testAThrowingStartIsSpentButNeverCountsAsStarted() {
        struct Boom: Error {}
        let claim = LaunchClaim()
        XCTAssertThrowsError(try claim.begin({ throw Boom() }))
        XCTAssertFalse(
            claim.didStart,
            "the start threw, so there is no child to terminate"
        )
        XCTAssertFalse(
            claim.begin({}),
            "the attempt is spent — a claim is not retried"
        )
    }

    /// REAL CONTENTION, with the ordering MEASURED and the invariant read
    /// INSIDE the window rather than after the join.
    ///
    /// Two corrections live here. The first version ran 500 GCD pairs and
    /// asserted only "exactly one side wins" — which it always did, because
    /// the blocks never actually raced: instrumenting it showed
    /// beginWins=500, abandonWins=0. Racing on a barrier makes both
    /// orderings occur, and the counters below fail the cell if one stops
    /// happening. The second: even then it read `ran.flag` after
    /// `group.wait()`, so it could not see a false `abandon()` that preceded
    /// the body. It now reads the witness in the abandon thread, at the
    /// instant of the answer.
    ///
    /// MUTATION: the same reopened window. Measured RED 12/12 against GREEN
    /// 12/12 unmutated — but only once the body took spawn-like time. With a
    /// body that returns in nanoseconds the same cell caught the mutation in
    /// 1 run of 20, because the window it samples was only as wide as one
    /// unlock-to-next-statement gap. A sampler is only as good as the window
    /// it samples; the deterministic cell above does not depend on that.
    func testUnderRealContentionAWinningBeginHasAlwaysAlreadyRun() {
        var beginWins = 0
        var abandonWins = 0
        for _ in 0..<400 {
            let claim = LaunchClaim()
            let round = Round()
            let started = DispatchSemaphore(value: 0)
            let gate = DispatchSemaphore(value: 0)
            let group = DispatchGroup()
            DispatchQueue.global().async(group: group) {
                started.signal(); gate.wait()
                round.begun = claim.begin({
                    // The real body is a fork/exec, not a bool assignment.
                    // A start that takes measurable time is what makes the
                    // window reachable in production; a body that returns in
                    // nanoseconds samples it almost never.
                    Thread.sleep(forTimeInterval: 0.0002)
                    round.ran = true
                })
            }
            DispatchQueue.global().async(group: group) {
                started.signal(); gate.wait()
                let stopped = claim.abandon()
                // Read before anything joins: a false answer asserts the work
                // has run, and this is the only moment that can check it.
                if !stopped { round.ranWhenAbandonAnswered = round.ran }
                round.stopped = stopped
            }
            started.wait(); started.wait()
            gate.signal(); gate.signal()
            group.wait()

            XCTAssertNotEqual(
                round.begun, round.stopped,
                "exactly one side may win: both true is work started after "
                    + "being reported stopped; both false is work neither run "
                    + "nor accounted for"
            )
            if round.begun {
                beginWins += 1
                XCTAssertEqual(
                    round.ranWhenAbandonAnswered, true,
                    "abandon answered 'already started' at an instant when "
                        + "the work had not run"
                )
                XCTAssertTrue(
                    round.ran,
                    "a winning begin must have RUN the work before returning"
                )
                XCTAssertTrue(claim.didStart)
            } else {
                abandonWins += 1
                XCTAssertNil(
                    round.ranWhenAbandonAnswered,
                    "abandon won, so it never answered false"
                )
                XCTAssertFalse(round.ran, "an abandoned claim runs nothing")
                XCTAssertFalse(claim.didStart)
            }
        }
        // The measurement the first version lacked: if one ordering never
        // occurs, this cell is not testing contention and should say so.
        XCTAssertGreaterThan(
            beginWins, 0,
            "no begin-first ordering occurred in 400 rounds — nothing sampled "
                + "the window this cell exists to watch"
        )
        XCTAssertGreaterThan(
            abandonWins, 0,
            "no abandon-first ordering occurred in 400 rounds — the queued-"
                + "task case this type exists for was never exercised, so "
                + "this cell proves nothing about it"
        )
    }

    /// One round's shared state. A class, not `var` captures, because the
    /// witness is written on one thread and read on another; the claim's own
    /// lock is what orders those accesses in the shipped shape, and a cell
    /// that could not observe across threads could not observe the window.
    private final class Round: @unchecked Sendable {
        var ran = false
        var begun = false
        var stopped = false
        var ranWhenAbandonAnswered: Bool?
    }
}
