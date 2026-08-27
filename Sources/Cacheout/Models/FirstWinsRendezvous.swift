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
