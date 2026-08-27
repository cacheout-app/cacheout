/// # DiskInfo — Disk Space Information
///
/// A lightweight value type that reads the current volume's capacity and availability
/// using `URLResourceValues`. Provides formatted strings for display and a percentage
/// for progress bars and gauges.
///
/// ## Usage
///
/// ```swift
/// if let disk = DiskInfo.current() {
///     print("\(disk.formattedFree) available of \(disk.formattedTotal)")
///     print("Used: \(Int(disk.usedPercentage * 100))%")
/// }
/// ```
///
/// ## Notes
///
/// Uses `volumeAvailableCapacityForImportantUsage` instead of `volumeAvailableCapacity`
/// for a more accurate reading that accounts for purgeable space (same value shown in
/// Finder's "Get Info" and Disk Utility).

import Foundation

struct DiskInfo {
    let totalSpace: Int64
    let freeSpace: Int64
    let usedSpace: Int64

    var usedPercentage: Double {
        guard totalSpace > 0 else { return 0 }
        return Double(usedSpace) / Double(totalSpace)
    }

    var formattedTotal: String {
        ByteCountFormatter.sharedFile.string(fromByteCount: totalSpace)
    }

    var formattedFree: String {
        ByteCountFormatter.sharedFile.string(fromByteCount: freeSpace)
    }

    var formattedUsed: String {
        ByteCountFormatter.sharedFile.string(fromByteCount: usedSpace)
    }

    static func current() -> DiskInfo? {
        let url = URL(fileURLWithPath: "/")
        do {
            let values = try url.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ])
            let total = Int64(values.volumeTotalCapacity ?? 0)
            let free = values.volumeAvailableCapacityForImportantUsage ?? 0
            return DiskInfo(totalSpace: total, freeSpace: free, usedSpace: total - free)
        } catch {
            return nil
        }
    }
}

/// THE HEADER'S VOLUME FIGURES, UNDER A WALL-CLOCK BOUND (PR #460 codex r14,
/// V2-1).
///
/// ## The defect this exists for
///
/// `CacheoutViewModel.scan` used to fetch these figures as a bare
/// `await Task.detached { DiskInfo.current() }.value`, and that await sat in
/// the worst possible place: AFTER the "scan in progress" guard is raised
/// (`scanningScannerIDs`, `activeScanGeneration`) and BEFORE
/// `scanValidatedSession` creates the stream, the producer, the watchdog and
/// the grace timer. So it was covered by NO bound and could produce NO
/// `.scanDidNotFinish` — the twelfth strand mechanism on this branch, and the
/// second one (after `ContainerSnapshot.capture`) that sat in front of the
/// session bound rather than inside it. (The capture has since been bounded
/// on this type's own shape — `ContainerSnapshot.captureBounded`, fn-4.19 —
/// so neither pre-session wait survives unbounded.)
///
/// `Task.detached` with no stated priority runs on the Swift cooperative
/// pool, in the unspecified band, so it needs a free worker to START. MEASURED
/// on this machine with that band saturated by `activeProcessorCount + 2`
/// uncancellable holders and a 200 ms session bound: `scan()` returned at
/// 2.619 s, the in-progress guard was STILL RAISED when sampled at 1.2 s,
/// `malformedIssuesByScannerID` was empty both at 1.2 s and at the end, and
/// the session reported `hasScanned == true` — the "spinner that never stops,
/// no second scan, no cleanup" signature the bound exists to convert into a
/// report, presented as a healthy scan. Pinned to THIS call rather than
/// inferred: under identical saturation the one await took 2.648 s while a
/// COMPLETE bounded session (`scanValidatedSession` + the full `for await` +
/// `untilProducerFinishes()`) took 0.0065 s in the same cell. r13's own M-B3
/// cell had already measured it (1.83 s, all of it before the stream existed)
/// and recorded it only in a test comment.
///
/// ## What this does instead
///
/// The fetch still runs detached — `URL.resourceValues` on an unresponsive
/// volume blocks its thread and must not block the MainActor — but it now
/// RACES a Dispatch timer on `ScanSessionClock`, the same off-the-pool queue
/// the session bounds use and for the same reason: a `Task.sleep` deadline
/// cannot resume while the pool is the thing that is starved. Whichever
/// party arrives first settles the rendezvous; the caller resumes on its own
/// executor (the MainActor's is the main queue, which needs no cooperative
/// worker), and the loser is discarded.
///
/// ## What the product does when the bound fires
///
/// `.timedOut`, and both call sites LEAVE `diskInfo` EXACTLY AS IT WAS. The
/// scan proceeds immediately into `scanValidatedSession`, where the session
/// bound covers it. Nothing is invented and nothing is wiped: `diskInfo` is
/// `DiskInfo?` and every renderer already handles nil (`ContentView` omits
/// the usage bar, `MenuBarView` reads `?? 0`, the menu-bar glyph falls back
/// to "💾") because `DiskInfo.current()` has always been able to return nil.
/// A stale or absent free-space reading in the header is the whole cost; no
/// destructive path reads `diskInfo`.
///
/// CAN A RETRY DIFFER? YES — which is why leaving the figures alone and
/// carrying on is the right disposition rather than a strand in disguise
/// (contrast a fail-closed refusal on a DETERMINISTIC limit, which no re-scan
/// can ever clear). Both causes here are transient by nature: a saturated
/// cooperative band frees as its holders return, and an unresponsive volume
/// answers or is unmounted. The next scan — automatic or user-initiated —
/// fetches again from scratch, and no state records that this one timed out.
///
/// WHAT IS NOT CLOSED, stated rather than glossed: the losing fetch is
/// ABANDONED, not cancelled. `URL.resourceValues` takes no deadline, so a
/// thread parked on a hung volume stays parked until the volume answers,
/// exactly as `ScanSessionBounds` leaks a wedged producer task. The bound
/// converts a hang into a report; it cannot cure the hang.
enum BoundedDiskInfo {
    /// The race's result. `.fetched` carries whatever `DiskInfo.current()`
    /// returned, INCLUDING its own nil (an unreadable volume) — that is a
    /// completed fetch, not a timeout, and the two are kept apart so a cell
    /// cannot pass one while asserting the other.
    enum Outcome: Sendable {
        case fetched(DiskInfo?)
        case timedOut

        var didTimeOut: Bool {
            if case .timedOut = self { return true }
            return false
        }
    }

    /// Runs `fetch` detached and returns whichever arrives first: its value,
    /// or `.timedOut` at `budget`.
    ///
    /// The `fetch` parameter is a TEST SEAM ONLY — every production call site
    /// takes the default. It exists so a cell can block deterministically
    /// instead of relying on band saturation for its arithmetic.
    static func current(
        within budget: Duration,
        fetch: @escaping @Sendable () -> DiskInfo? = { DiskInfo.current() }
    ) async -> Outcome {
        let rendezvous = FirstWinsRendezvous<Outcome>()
        // OFF THE POOL, deliberately: see the type comment. A `Task.sleep`
        // here would need the very worker the fetch is waiting for.
        let timer = ScanSessionClock.schedule(after: budget) {
            rendezvous.settle(.timedOut)
        }
        // The band is left UNSPECIFIED on purpose — it is the band the
        // defect was measured in, so the cells that saturate it exercise the
        // production shape rather than a variant of it.
        Task.detached {
            rendezvous.settle(.fetched(fetch()))
        }
        let outcome = await rendezvous.wait()
        timer.cancel()
        return outcome
    }

    // The rendezvous itself is `FirstWinsRendezvous` — born here as a
    // private class, extracted when `ContainerSnapshot.captureBounded`
    // (fn-4.19) and `dockerPrune` (fn-4.20) needed the identical shape.
}
