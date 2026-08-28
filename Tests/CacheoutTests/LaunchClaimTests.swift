import XCTest
@testable import Cacheout

/// `LaunchClaim` — deciding and starting destructive work as ONE act
/// (PR #461 codex r1, corrected by the merge gate).
///
/// The defect: `FirstWinsRendezvous` decides which OUTCOME is reported, not
/// whether the work STARTED. A detached task still queued when the off-pool
/// timer wins observes nothing; the timeout branch sees `isRunning == false`,
/// reports truthfully that nothing runs, re-enables the button — and the task
/// is then scheduled and launches an unowned `docker system prune -f`.
///
/// THE FIRST FIX ONLY MOVED THAT WINDOW, and this suite is written to catch
/// exactly that. A bare `begin()` followed by `run()` on the next statement
/// leaves the timer free to fire BETWEEN them: `abandon()` answers false
/// ("already started"), the caller reads `didStart == true` with
/// `isRunning == false` because the start has not run yet, terminates
/// nothing, reports it stopped — and the work then begins, unowned. So
/// `begin` performs the work under the lock, and the cells below assert the
/// property that makes that matter: **after `abandon()` answers false, the
/// work has provably run.**
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

    /// THE WINDOW THE FIRST FIX LEFT OPEN. `abandon()` returning false must
    /// mean the work has ALREADY RUN — not that it is about to. If the claim
    /// merely marked a decision and let the caller start afterwards, this
    /// observation would be false exactly when it matters.
    func testAbandonAnsweringFalseMeansTheWorkHasAlreadyRun() {
        let claim = LaunchClaim()
        var ran = false
        XCTAssertTrue(claim.begin({ ran = true }))
        XCTAssertTrue(ran, "begin performs the work; it does not schedule it")
        XCTAssertFalse(
            claim.abandon(),
            "the work is already running: the timer must be told so"
        )
        XCTAssertTrue(
            ran,
            "when abandon answers false the work has PROVABLY run — the whole "
                + "point of performing under the claim"
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

    /// REAL CONTENTION, with the ordering MEASURED rather than assumed.
    ///
    /// The first version of this cell ran 500 GCD pairs and asserted only
    /// "exactly one side wins" — which it always did, because the two blocks
    /// never actually raced: instrumenting it showed beginWins=500,
    /// abandonWins=0, so 500 iterations exercised ONE ordering and the cell
    /// stayed green under its own mutation. Racing on a barrier makes both
    /// orderings occur, and the assertion is now the invariant that matters:
    /// whichever side wins, a `begin` that returned true must have RUN.
    func testUnderRealContentionAWinningBeginHasAlwaysAlreadyRun() {
        var beginWins = 0
        var abandonWins = 0
        for _ in 0..<400 {
            let claim = LaunchClaim()
            let ran = Ran()
            let started = DispatchSemaphore(value: 0)
            let gate = DispatchSemaphore(value: 0)
            var begun = false
            var stopped = false
            let group = DispatchGroup()
            DispatchQueue.global().async(group: group) {
                started.signal(); gate.wait()
                begun = claim.begin({ ran.flag = true })
            }
            DispatchQueue.global().async(group: group) {
                started.signal(); gate.wait()
                stopped = claim.abandon()
            }
            started.wait(); started.wait()
            gate.signal(); gate.signal()
            group.wait()

            XCTAssertNotEqual(
                begun, stopped,
                "exactly one side may win: both true is work started after "
                    + "being reported stopped; both false is work neither run "
                    + "nor accounted for"
            )
            if begun {
                beginWins += 1
                XCTAssertTrue(
                    ran.flag,
                    "a winning begin must have RUN the work before returning"
                )
                XCTAssertTrue(claim.didStart)
            } else {
                abandonWins += 1
                XCTAssertFalse(ran.flag, "an abandoned claim runs nothing")
                XCTAssertFalse(claim.didStart)
            }
        }
        // The measurement the first version lacked: if one ordering never
        // occurs, this cell is not testing contention and should say so.
        XCTAssertGreaterThan(
            beginWins, 0, "no begin-first ordering occurred in 400 rounds"
        )
        XCTAssertGreaterThan(
            abandonWins, 0,
            "no abandon-first ordering occurred in 400 rounds — the queued-"
                + "task case this type exists for was never exercised, so "
                + "this cell proves nothing about it"
        )
    }

    private final class Ran: @unchecked Sendable { var flag = false }
}
