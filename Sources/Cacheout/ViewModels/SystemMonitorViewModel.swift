/// # SystemMonitorViewModel — System Health Dashboard Data Source
///
/// Provides live system memory stats and top processes for the SwiftUI
/// System Health dashboard tab. Subscribes to:
///
/// 1. `MemoryMonitor.subscribe()` for 1Hz memory stats (throttled to 2Hz for UI)
/// 2. `ProcessMemoryScanner.scan(topN:)` every 5 seconds for top processes
///
/// Cancels both subscriptions on deinit or when `stopMonitoring()` is called.

import CacheoutShared
import Foundation

@MainActor
final class SystemMonitorViewModel: ObservableObject {

    // MARK: - Published State

    @Published var latestStats: SystemStatsDTO?
    @Published var topProcesses: [ProcessEntryDTO] = []
    @Published var processSource: String = "proc_pid_rusage"
    @Published var processPartial: Bool = false
    @Published var compressionTrend: CompressorTracker.RatioTrend = .stable
    @Published var isThrashing: Bool = false

    // MARK: - Private

    private let monitor = MemoryMonitor()
    private let scanner = ProcessMemoryScanner()
    private let compressorTracker = CompressorTracker()

    private var statsTask: Task<Void, Never>?
    private var processTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    /// Generation counter to prevent stale cleanup from tearing down a new session.
    private var generation: UInt64 = 0

    private let processCount = 10
    private let processRefreshInterval: Duration = .seconds(5)

    // MARK: - Lifecycle

    func startMonitoring() {
        // Cancel any existing monitoring tasks
        statsTask?.cancel()
        processTask?.cancel()

        // If a previous cleanup is still running, await it so teardown
        // completes fully before starting a new session. Canceling it would
        // skip stop()/stopConsuming() and leak polling tasks.
        let previousCleanup = cleanupTask
        cleanupTask = nil

        // Start memory stats subscription
        statsTask = Task {
            // Wait for prior teardown to finish before starting fresh.
            // Generation is NOT bumped until after this completes so the
            // old cleanup's generation checks remain valid throughout.
            await previousCleanup?.value

            // Re-check cancellation after every suspension point: a new
            // stopMonitoring() may have fired while we were awaiting.
            guard !Task.isCancelled else { return }

            // Now safe to advance generation for this new session.
            self.generation &+= 1
            let sessionGen = self.generation

            await monitor.start()
            guard !Task.isCancelled, self.generation == sessionGen else { return }

            // Subscribe to compressor tracker
            let trackerStream = await monitor.subscribe()
            guard !Task.isCancelled, self.generation == sessionGen else { return }
            await compressorTracker.startConsuming(from: trackerStream)
            guard !Task.isCancelled, self.generation == sessionGen else { return }

            // Subscribe for UI updates (throttled via AsyncStream bufferingNewest)
            let uiStream = await monitor.subscribe()
            guard !Task.isCancelled, self.generation == sessionGen else { return }

            var lastUpdate = ContinuousClock.now
            let minInterval: Duration = .milliseconds(500) // 2Hz throttle

            var iterator = uiStream.makeAsyncIterator()
            while !Task.isCancelled, self.generation == sessionGen {
                guard let stats = await iterator.next() else { break }
                guard !Task.isCancelled, self.generation == sessionGen else { break }
                let now = ContinuousClock.now
                if now - lastUpdate >= minInterval {
                    self.latestStats = stats
                    self.compressionTrend = await compressorTracker.compressionRatioTrend()
                    self.isThrashing = await compressorTracker.isThrashing()
                    lastUpdate = now
                }
            }
        }

        // Start process scanning loop
        processTask = Task {
            while !Task.isCancelled {
                let result = await scanner.scan(topN: processCount)
                guard !Task.isCancelled else { break }
                self.topProcesses = result.processes
                self.processSource = result.source
                self.processPartial = result.partial
                try? await Task.sleep(for: processRefreshInterval)
            }
        }
    }

    func stopMonitoring() {
        statsTask?.cancel()
        statsTask = nil
        processTask?.cancel()
        processTask = nil

        let capturedGen = generation
        // Capture strong references to the resources that must be stopped.
        // This ensures teardown completes even if the view model is released
        // while cleanup is in flight.
        let capturedTracker = compressorTracker
        let capturedMonitor = monitor
        cleanupTask = Task { [weak self] in
            // Helper: check if this cleanup is still the current session.
            // If self is nil (deallocated), this is a final-shutdown path
            // and teardown MUST proceed unconditionally.
            func isCurrentOrFinal() async -> Bool {
                await MainActor.run {
                    guard let self else { return true } // nil self = final shutdown, proceed
                    return self.generation == capturedGen
                }
            }

            guard await isCurrentOrFinal() else { return }
            await capturedTracker.stopConsuming()
            guard await isCurrentOrFinal() else { return }
            await capturedMonitor.stop()
            await MainActor.run {
                if self?.generation == capturedGen {
                    self?.cleanupTask = nil
                }
            }
        }
    }

    deinit {
        statsTask?.cancel()
        processTask?.cancel()
        // Do NOT cancel cleanupTask — stopMonitoring() captures strong
        // references to monitor and compressorTracker so teardown completes
        // even after the view model is released. Cancelling would skip
        // stop()/stopConsuming() and leak polling tasks.
    }

    // MARK: - Computed Properties

    var pressureTier: PressureTier {
        guard let stats = latestStats else { return .normal }
        let availableMB = Double(stats.freePages + stats.inactivePages) * Double(stats.pageSize) / 1048576.0
        return PressureTier.from(pressureLevel: stats.pressureLevel, availableMB: availableMB)
    }

    var totalPhysicalMB: Double {
        guard let stats = latestStats else { return 0 }
        return Double(stats.totalPhysicalMemory) / 1048576.0
    }

    var activeMB: Double {
        guard let stats = latestStats else { return 0 }
        return Double(stats.activePages) * Double(stats.pageSize) / 1048576.0
    }

    var wiredMB: Double {
        guard let stats = latestStats else { return 0 }
        return Double(stats.wiredPages) * Double(stats.pageSize) / 1048576.0
    }

    var compressedMB: Double {
        guard let stats = latestStats else { return 0 }
        return Double(stats.compressorBytesUsed) / 1048576.0
    }

    var freeMB: Double {
        guard let stats = latestStats else { return 0 }
        return Double(stats.freePages) * Double(stats.pageSize) / 1048576.0
    }

    var inactiveMB: Double {
        guard let stats = latestStats else { return 0 }
        return Double(stats.inactivePages) * Double(stats.pageSize) / 1048576.0
    }

    var swapUsedMB: Double {
        guard let stats = latestStats else { return 0 }
        return Double(stats.swapUsedBytes) / 1048576.0
    }

    var compressionRatio: Double {
        latestStats?.compressionRatio ?? 0.0
    }

    var trendArrow: String {
        switch compressionTrend {
        case .improving: return "↑"
        case .declining: return "↓"
        case .stable: return "→"
        }
    }
}
