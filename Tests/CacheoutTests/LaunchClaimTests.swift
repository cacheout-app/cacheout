import XCTest
@testable import Cacheout

/// `LaunchClaim` — the one-shot authority that keeps a losing task from
/// starting destructive work after its outcome was already reported
/// (PR #461 codex r1, P1).
///
/// The defect it exists for: `FirstWinsRendezvous` decides which OUTCOME is
/// reported, not whether the work STARTED. A detached task still queued when
/// the off-pool timer wins observes nothing; the timeout branch sees
/// `isRunning == false`, truthfully reports that nothing runs, re-enables the
/// button — and the task is then scheduled and launches an unowned
/// `docker system prune -f`, free to overlap the retry the user was just
/// invited to make. The starvation the timer exists to survive is exactly what
/// keeps the task queued, so the window is widest when it matters most.
final class LaunchClaimTests: XCTestCase {

    func testAbandonBeforeBeginStopsTheLaunchAndSaysItNeverStarted() {
        let claim = LaunchClaim()
        XCTAssertTrue(claim.abandon(), "the timer arrived first, so it wins")
        XCTAssertFalse(
            claim.begin(),
            "a task scheduled after the timeout must NOT start the work — "
                + "this is the unowned destructive launch the type prevents"
        )
        XCTAssertFalse(
            claim.didStart,
            "nothing started, so the timeout branch has nothing to terminate"
        )
    }

    func testBeginBeforeAbandonKeepsTheWorkAndTellsTheTimerItIsRunning() {
        let claim = LaunchClaim()
        XCTAssertTrue(claim.begin(), "the task got there first")
        XCTAssertFalse(
            claim.abandon(),
            "the work is already running: the timer must be told so, or it "
                + "would report a stop it did not perform"
        )
        XCTAssertTrue(claim.didStart, "the caller owns terminating it")
    }

    func testBeginIsNeverTrueTwice() {
        let claim = LaunchClaim()
        XCTAssertTrue(claim.begin())
        XCTAssertFalse(claim.begin(), "one-shot: no second launch")
    }

    /// THE RACE ITSELF, not a sequenced imitation: many pairs contend at
    /// once and EXACTLY ONE side of each pair may win. A `begin` and an
    /// `abandon` both returning true would be two decisions about one
    /// destructive act.
    func testUnderContentionExactlyOneSideOfEachPairWins() {
        for _ in 0..<500 {
            let claim = LaunchClaim()
            let started = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
            let stopped = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
            defer { started.deallocate(); stopped.deallocate() }
            started.pointee = false
            stopped.pointee = false
            let group = DispatchGroup()
            DispatchQueue.global().async(group: group) {
                started.pointee = claim.begin()
            }
            DispatchQueue.global().async(group: group) {
                stopped.pointee = claim.abandon()
            }
            group.wait()
            XCTAssertNotEqual(
                started.pointee, stopped.pointee,
                "exactly one may win: both true means a prune launched after "
                    + "being reported stopped; both false means it was "
                    + "neither run nor accounted for"
            )
            XCTAssertEqual(
                claim.didStart, started.pointee,
                "didStart must agree with the winner"
            )
        }
    }
}
