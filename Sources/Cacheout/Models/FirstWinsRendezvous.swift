/// # FirstWinsRendezvous — the bounded-await primitive
///
/// One-shot, first-writer-wins, lock-guarded: two settlers race — typically
/// a `ScanSessionClock` Dispatch timer body and a detached task, neither of
/// which may suspend — and whichever arrives first decides the outcome; the
/// loser's settle is a no-op. The caller resumes on its own executor, so a
/// MainActor caller needs no cooperative worker to observe the result.
///
/// Born as `BoundedDiskInfo`'s private `Rendezvous` (PR #460 codex r14,
/// V2-1 — the header refresh's bound) and extracted verbatim when
/// `ContainerSnapshot.captureBounded` (fn-4.19) and
/// `CacheoutViewModel.dockerPrune` (fn-4.20) needed the identical shape:
/// one spelling, so the three bounds cannot drift in their settle/wait
/// semantics.
///
/// The wait is a plain `withCheckedContinuation` (the spelling that ignores
/// the caller's cancellation) for the same reason `OneShotGate` uses it: the
/// timer ALWAYS settles, so an uncancellable wait cannot become an unbounded
/// one, and a cancellation-aware wait would collapse the budget to zero in a
/// cancelled caller.
///
/// ONE waiter per instance, by contract: every use in this repo creates the
/// rendezvous, arms the timer, launches the work, and awaits once.

import Foundation

final class FirstWinsRendezvous<Outcome: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var settled: Outcome?
    private var waiter: CheckedContinuation<Outcome, Never>?

    func settle(_ outcome: Outcome) {
        lock.lock()
        guard settled == nil else { lock.unlock(); return }
        settled = outcome
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: outcome)
    }

    func wait() async -> Outcome {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Outcome, Never>) in
            lock.lock()
            if let settled {
                lock.unlock()
                continuation.resume(returning: settled)
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }
}

/// ONE-SHOT AUTHORITY TO START SOMETHING DESTRUCTIVE (PR #461 codex r1, P1).
///
/// `FirstWinsRendezvous` decides which OUTCOME is reported. It cannot decide
/// whether the work ever STARTED, and for a destructive child those are
/// different questions: a detached task still queued when the off-pool timer
/// wins observes nothing, the timeout branch sees `process.isRunning == false`
/// and truthfully reports that nothing is running — and then the task is
/// scheduled and calls `run()`, launching an unowned `docker system prune -f`
/// after the operation was reported timed out, free to overlap a user retry.
///
/// The starvation this timer exists to survive is exactly the condition that
/// keeps the task queued, so the window is widest when it matters most.
///
/// Both sides claim through one lock, so the pair is decided once: whoever
/// arrives first wins and the loser is told. `begin()` false means DO NOT
/// START. `abandon()` false means it already started — the caller owns
/// stopping it.
final class LaunchClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var decided = false
    private var started = false

    /// Decide AND perform in one act: `body` runs while the lock is held, so
    /// `abandon()` cannot interleave between the decision and the start.
    ///
    /// A first version of this type offered a bare `begin()` and left the
    /// caller to start the work on the next statement. That MOVED the window
    /// rather than closing it: with the timer firing between the two,
    /// `abandon()` answered false ("already started"), the caller's timeout
    /// branch read `didStart == true` with `isRunning == false` — because the
    /// start had not run yet — terminated nothing, reported the work stopped,
    /// and the work then began, unowned. Deciding and starting must be the
    /// same act, so this type performs it.
    ///
    /// Returns `false` without running `body` if the work was already
    /// abandoned. A throwing `body` leaves the claim DECIDED but not started:
    /// the attempt is spent (never retried under the same claim) while
    /// `didStart` stays false, because nothing is running to terminate.
    @discardableResult
    func begin(_ body: () throws -> Void) rethrows -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !decided else { return false }
        decided = true
        try body()
        started = true
        return true
    }

    /// `true` if the work was stopped before it began. `false` means the
    /// decision was already taken — and because `begin` performs the work
    /// under this same lock, a false answer means the work has provably
    /// STARTED (or its start threw), never that it is about to.
    @discardableResult
    func abandon() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !decided else { return false }
        decided = true
        return true
    }

    /// Whether the work was actually started — for a caller deciding whether
    /// it has anything to terminate.
    var didStart: Bool {
        lock.lock(); defer { lock.unlock() }
        return started
    }
}
