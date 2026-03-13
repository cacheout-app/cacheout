/// # PredictiveEngine -- Time-to-Exhaustion Predictor + Growth Detection
///
/// An actor that maintains a 60-sample sliding window of `(timestamp, availableMB)`
/// tuples fed from `MemoryMonitor` snapshots at 1Hz, and provides:
///
/// - **Time-to-exhaustion prediction** via linear regression of availableMB over time
/// - **High-growth process detection** using `leakIndicator` proximity to 1.0
/// - **Process scan caching** with 30-second refresh cadence, preserving full `ScanResult`
///
/// ## Usage
///
/// ```swift
/// let engine = PredictiveEngine()
/// // Feed from MemoryMonitor ticks:
/// engine.recordAvailableMB(mb, at: timestamp)
/// // Query predictions:
/// let tte = engine.predictTimeToExhaustion()
/// let growers = await engine.detectHighGrowthProcesses()
/// ```

import CacheoutShared
import Foundation
import os

/// Abstraction for process scanning, enabling test injection.
///
/// The default implementation delegates to `ProcessMemoryScanner.scan()`.
/// Tests can inject a stub that returns deterministic results without
/// touching live process state or XPC.
protocol ProcessScanProvider: Sendable {
    func scan() async -> ProcessMemoryScanner.ScanResult
}

/// Default scan provider that delegates to the real `ProcessMemoryScanner`.
struct RealProcessScanProvider: ProcessScanProvider {
    private let scanner: ProcessMemoryScanner

    init(scanner: ProcessMemoryScanner = ProcessMemoryScanner()) {
        self.scanner = scanner
    }

    func scan() async -> ProcessMemoryScanner.ScanResult {
        await scanner.scan()
    }
}

actor PredictiveEngine {

    // MARK: - Types

    /// A single recorded sample of available memory.
    struct AvailableMBSample: Sendable {
        let timestamp: Date
        let availableMB: Double
    }

    // MARK: - Configuration

    /// Maximum number of samples in the sliding window (60 seconds at 1Hz).
    static let maxSamples = 60

    /// Minimum number of samples required before predictions are valid.
    static let minSamplesForPrediction = 30

    /// Minimum slope magnitude (MB/sec) to consider as consumption trend.
    /// Only negative slopes steeper than this trigger predictions.
    static let slopeThreshold: Double = -1.0

    /// Maximum predicted time (seconds) to emit. Predictions beyond this
    /// are considered too far out to be actionable.
    static let maxPredictionSeconds: TimeInterval = 600.0

    /// Minimum physical footprint (bytes) for high-growth detection.
    static let highGrowthMinFootprint: UInt64 = 500 * 1024 * 1024  // 500 MB

    /// Maximum leakIndicator for high-growth detection.
    /// Values < 1.05 mean the process is within 5% of its lifetime peak.
    static let highGrowthMaxLeakIndicator: Double = 1.05

    /// Process scan cache staleness threshold in seconds.
    static let scanCacheMaxAge: TimeInterval = 30.0

    // MARK: - State

    private var buffer: [AvailableMBSample?]
    private var writeIndex: Int = 0
    private var count: Int = 0

    /// Cached process scan result. Preserves full ScanResult including
    /// `partial` and `source` flags for downstream confidence decisions.
    private(set) var cachedScanResult: ProcessMemoryScanner.ScanResult?

    /// When the last process scan was performed.
    private(set) var lastScanTime: Date?

    /// The scan provider used for process scans (injectable for testing).
    private let scanProvider: ProcessScanProvider

    /// In-flight refresh task. Concurrent callers await the same task
    /// instead of launching duplicate scans. Cleared after the scan
    /// completes and the cache is updated.
    private var inflightScanTask: Task<ProcessMemoryScanner.ScanResult, Never>?

    private let logger = Logger(subsystem: "com.cacheout", category: "PredictiveEngine")

    // MARK: - Init

    init(scanProvider: ProcessScanProvider = RealProcessScanProvider()) {
        self.buffer = Array(repeating: nil, count: Self.maxSamples)
        self.scanProvider = scanProvider
    }

    /// Convenience initializer that wraps a `ProcessMemoryScanner` in the default provider.
    init(scanner: ProcessMemoryScanner) {
        self.buffer = Array(repeating: nil, count: Self.maxSamples)
        self.scanProvider = RealProcessScanProvider(scanner: scanner)
    }

    // MARK: - Available MB Recording

    /// Record a single availableMB measurement.
    ///
    /// Called from DaemonMode on each MemoryMonitor tick (1Hz).
    /// The value is computed as `(freePages + inactivePages) * pageSize / 1048576`.
    func recordAvailableMB(_ mb: Double, at timestamp: Date = Date()) {
        let sample = AvailableMBSample(timestamp: timestamp, availableMB: mb)
        buffer[writeIndex] = sample
        writeIndex = (writeIndex + 1) % Self.maxSamples
        if count < Self.maxSamples {
            count += 1
        }
    }

    /// Current number of recorded samples.
    var sampleCount: Int { count }

    // MARK: - Time-to-Exhaustion Prediction

    /// Predict the time until available memory reaches zero, in seconds.
    ///
    /// Uses linear regression of availableMB over time to compute slope (MB/sec).
    /// Returns a prediction only when:
    /// - At least `minSamplesForPrediction` samples are available
    /// - Slope is < `slopeThreshold` (memory is being consumed)
    /// - Predicted time is < `maxPredictionSeconds` (actionable window)
    ///
    /// - Returns: Estimated seconds until exhaustion, or `nil` if conditions not met.
    func predictTimeToExhaustion() -> TimeInterval? {
        let samples = orderedSamples()
        guard samples.count >= Self.minSamplesForPrediction else { return nil }

        // Linear regression: y = availableMB, x = time offset in seconds
        let t0 = samples[0].timestamp
        let n = Double(samples.count)
        var sumX: Double = 0
        var sumY: Double = 0
        var sumXY: Double = 0
        var sumX2: Double = 0

        for sample in samples {
            let x = sample.timestamp.timeIntervalSince(t0)
            let y = sample.availableMB
            sumX += x
            sumY += y
            sumXY += x * y
            sumX2 += x * x
        }

        let denominator = n * sumX2 - sumX * sumX
        guard abs(denominator) > 1e-12 else { return nil }

        let slope = (n * sumXY - sumX * sumY) / denominator

        // Only predict when memory is being consumed faster than threshold
        guard slope < Self.slopeThreshold else { return nil }

        // Current available MB (most recent sample)
        let currentMB = samples.last!.availableMB
        guard currentMB > 0 else { return nil }

        let estimatedSeconds = currentMB / abs(slope)

        // Only emit if within actionable window
        guard estimatedSeconds < Self.maxPredictionSeconds else { return nil }

        return estimatedSeconds
    }

    // MARK: - High-Growth Process Detection

    /// Detect processes that have grown to and remain at their lifetime peak.
    ///
    /// Filters for processes where:
    /// - `leakIndicator < 1.05` (within 5% of lifetime peak)
    /// - `physFootprint > 500MB` (significant memory consumer)
    ///
    /// This is NOT leak detection -- it identifies processes with sustained growth
    /// that are currently at or near their maximum footprint.
    ///
    /// - Parameter processes: Process entries to evaluate.
    /// - Returns: Processes matching high-growth criteria.
    func detectHighGrowthProcesses(from processes: [ProcessEntryDTO]) -> [ProcessEntryDTO] {
        processes.filter { entry in
            entry.leakIndicator < Self.highGrowthMaxLeakIndicator
                && entry.leakIndicator > 0  // Exclude zero (no footprint data)
                && entry.physFootprint > Self.highGrowthMinFootprint
        }
    }

    // MARK: - Process Scan Cache

    /// Get the cached process scan result, refreshing if stale or empty.
    ///
    /// On first request after startup, triggers an immediate scan (no waiting
    /// for the next 30-second tick). Subsequent requests use the cache if
    /// it is less than 30 seconds old.
    ///
    /// Concurrent callers coalesce into a single scan: the first caller
    /// launches the scan task, subsequent callers await the same task.
    ///
    /// - Returns: The cached or freshly scanned `ScanResult`.
    func getOrRefreshScanResult() async -> ProcessMemoryScanner.ScanResult {
        // Return fresh cache if available
        if let cached = cachedScanResult,
           let scanTime = lastScanTime,
           Date().timeIntervalSince(scanTime) < Self.scanCacheMaxAge {
            return cached
        }

        // If another caller is already refreshing, coalesce by awaiting
        // the same in-flight task.
        if let existing = inflightScanTask {
            return await existing.value
        }

        // Launch a new scan task and store it for coalescing
        let provider = scanProvider
        let task = Task<ProcessMemoryScanner.ScanResult, Never> {
            await provider.scan()
        }
        inflightScanTask = task

        let result = await task.value

        // Update cache and clear in-flight task
        cachedScanResult = result
        lastScanTime = Date()
        inflightScanTask = nil

        return result
    }

    /// Update the cached scan result directly (for testing or external scan injection).
    func setCachedScanResult(_ result: ProcessMemoryScanner.ScanResult, at time: Date = Date()) {
        cachedScanResult = result
        lastScanTime = time
    }

    // MARK: - Private Helpers

    /// Returns samples in chronological order (oldest first).
    private func orderedSamples() -> [AvailableMBSample] {
        guard count > 0 else { return [] }
        var result: [AvailableMBSample] = []
        result.reserveCapacity(count)

        let start = count < Self.maxSamples ? 0 : writeIndex
        for i in 0..<count {
            let idx = (start + i) % Self.maxSamples
            if let sample = buffer[idx] {
                result.append(sample)
            }
        }
        return result
    }
}
