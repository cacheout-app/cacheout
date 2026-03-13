/// # CompressorTracker — Compressor Trend Detection
///
/// An actor that records compressor metrics from `SystemStatsDTO` snapshots
/// into a fixed-size ring buffer and derives:
///
/// - **Compression rate** (compressions/sec)
/// - **Decompression rate** (decompressions/sec)
/// - **Compression ratio trend** (linear regression slope)
/// - **Thrashing detection** (sustained high decompression vs compression)
///
/// ## Usage
///
/// ```swift
/// let tracker = CompressorTracker()
/// let stream = await memoryMonitor.subscribe()
/// await tracker.startConsuming(from: stream)
/// ```

import CacheoutShared
import Foundation
import os

actor CompressorTracker {

    // MARK: - Types

    /// A single recorded sample derived from a `SystemStatsDTO`.
    struct Sample: Sendable {
        let timestamp: Date
        let compressions: UInt64
        let decompressions: UInt64
        let compressionRatio: Double
    }

    /// Trend direction for the compression ratio.
    enum RatioTrend: Sendable, Equatable {
        /// Ratio is improving (slope > 0): compressor is becoming more effective.
        case improving(slope: Double)
        /// Ratio is declining (slope < 0): workload becoming less compressible.
        case declining(slope: Double)
        /// Ratio is stable or insufficient data to determine trend.
        case stable
    }

    // MARK: - Configuration

    /// Maximum number of samples in the ring buffer (5 min at 1Hz).
    static let maxSamples = 300

    /// Minimum sustained duration (seconds) of high decompression before
    /// declaring thrashing.
    static let thrashingDurationThreshold: TimeInterval = 30.0

    /// Decompression rate must exceed compression rate by this factor
    /// for thrashing detection.
    static let thrashingRatioThreshold: Double = 2.0

    /// Minimum decompression rate (ops/sec) to avoid false positives
    /// when both rates are near zero.
    static let thrashingAbsoluteMinimum: Double = 100.0

    // MARK: - State

    private var buffer: [Sample?]
    private var writeIndex: Int = 0
    private var count: Int = 0
    private var consumeTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "com.cacheout", category: "CompressorTracker")

    // MARK: - Init

    init() {
        self.buffer = Array(repeating: nil, count: Self.maxSamples)
    }

    // MARK: - Public API

    /// Begin consuming snapshots from a `MemoryMonitor` stats stream.
    /// Cancels any previous consumption task.
    func startConsuming(from stream: AsyncStream<SystemStatsDTO>) {
        consumeTask?.cancel()
        consumeTask = Task { [weak self] in
            for await stats in stream {
                guard !Task.isCancelled else { break }
                await self?.record(stats)
            }
        }
    }

    /// Stop consuming snapshots.
    func stopConsuming() {
        consumeTask?.cancel()
        consumeTask = nil
    }

    /// Record a single snapshot.
    func record(_ stats: SystemStatsDTO) {
        let sample = Sample(
            timestamp: stats.timestamp,
            compressions: stats.compressions,
            decompressions: stats.decompressions,
            compressionRatio: stats.compressionRatio
        )
        buffer[writeIndex] = sample
        writeIndex = (writeIndex + 1) % Self.maxSamples
        if count < Self.maxSamples {
            count += 1
        }
    }

    /// Current number of recorded samples.
    var sampleCount: Int { count }

    /// Compression rate in operations per second, computed from the delta
    /// between the two most recent samples. Returns `nil` if fewer than
    /// 2 samples are available.
    func compressionRate() -> Double? {
        guard let (older, newer) = lastTwoSamples() else { return nil }
        let dt = newer.timestamp.timeIntervalSince(older.timestamp)
        guard dt > 0 else { return nil }
        let delta = Self.safeDelta(newer.compressions, older.compressions)
        return Double(delta) / dt
    }

    /// Decompression rate in operations per second, computed from the delta
    /// between the two most recent samples. Returns `nil` if fewer than
    /// 2 samples are available.
    func decompressionRate() -> Double? {
        guard let (older, newer) = lastTwoSamples() else { return nil }
        let dt = newer.timestamp.timeIntervalSince(older.timestamp)
        guard dt > 0 else { return nil }
        let delta = Self.safeDelta(newer.decompressions, older.decompressions)
        return Double(delta) / dt
    }

    /// Linear trend of the compression ratio over all buffered samples.
    ///
    /// - Returns: `.improving(slope:)` if slope > 0.001,
    ///            `.declining(slope:)` if slope < -0.001,
    ///            `.stable` otherwise or if insufficient data.
    func compressionRatioTrend() -> RatioTrend {
        let samples = orderedSamples()
        guard samples.count >= 2 else { return .stable }

        // Check if compression deltas are near zero across the window.
        // If so, the ratio is meaningless — report stable.
        let first = samples.first!
        let last = samples.last!
        let totalCompressionDelta = Self.safeDelta(last.compressions, first.compressions)
        if totalCompressionDelta < 10 {
            return .stable
        }

        // Linear regression: y = compression ratio, x = time offset in seconds.
        let t0 = samples[0].timestamp
        let n = Double(samples.count)
        var sumX: Double = 0
        var sumY: Double = 0
        var sumXY: Double = 0
        var sumX2: Double = 0

        for sample in samples {
            let x = sample.timestamp.timeIntervalSince(t0)
            let y = sample.compressionRatio
            sumX += x
            sumY += y
            sumXY += x * y
            sumX2 += x * x
        }

        let denominator = n * sumX2 - sumX * sumX
        guard abs(denominator) > 1e-12 else { return .stable }

        let slope = (n * sumXY - sumX * sumY) / denominator

        if slope > 0.001 {
            return .improving(slope: slope)
        } else if slope < -0.001 {
            return .declining(slope: slope)
        } else {
            return .stable
        }
    }

    /// Whether the compressor is currently thrashing: sustained high
    /// decompression rate exceeding compression rate.
    ///
    /// Thrashing is detected when the decompression rate exceeds
    /// `thrashingRatioThreshold × compression rate` for at least
    /// `thrashingDurationThreshold` seconds, AND the decompression rate
    /// exceeds `thrashingAbsoluteMinimum` to avoid false positives.
    func isThrashing() -> Bool {
        let samples = orderedSamples()
        guard samples.count >= 2 else { return false }

        // Walk backwards from the most recent sample, checking consecutive
        // pairs. We need sustained thrashing for the threshold duration.
        var thrashingStart: Date?

        for i in 1..<samples.count {
            let older = samples[i - 1]
            let newer = samples[i]
            let dt = newer.timestamp.timeIntervalSince(older.timestamp)
            guard dt > 0 else { continue }

            let compDelta = Self.safeDelta(newer.compressions, older.compressions)
            let decompDelta = Self.safeDelta(newer.decompressions, older.decompressions)
            let decompRate = Double(decompDelta) / dt
            let compRate = Double(compDelta) / dt

            let pairThrashing = decompRate > Self.thrashingAbsoluteMinimum
                && decompRate > Self.thrashingRatioThreshold * compRate

            if pairThrashing {
                if thrashingStart == nil {
                    thrashingStart = older.timestamp
                }
            } else {
                // Break in thrashing — reset.
                thrashingStart = nil
            }
        }

        guard let start = thrashingStart else { return false }
        let lastSample = samples.last!
        let duration = lastSample.timestamp.timeIntervalSince(start)
        return duration >= Self.thrashingDurationThreshold
    }

    // MARK: - Private Helpers

    /// Returns samples in chronological order (oldest first).
    private func orderedSamples() -> [Sample] {
        guard count > 0 else { return [] }
        var result: [Sample] = []
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

    /// Returns the two most recent samples as (older, newer), or `nil`
    /// if fewer than 2 samples exist.
    private func lastTwoSamples() -> (Sample, Sample)? {
        guard count >= 2 else { return nil }
        let newerIdx = (writeIndex - 1 + Self.maxSamples) % Self.maxSamples
        let olderIdx = (writeIndex - 2 + Self.maxSamples) % Self.maxSamples
        guard let newer = buffer[newerIdx], let older = buffer[olderIdx] else {
            return nil
        }
        return (older, newer)
    }

    /// Safe subtraction for cumulative counters that may wrap.
    /// If newer < older (wrap), returns newer (assumes single wrap from 0).
    private static func safeDelta(_ newer: UInt64, _ older: UInt64) -> UInt64 {
        if newer >= older {
            return newer - older
        }
        // Counter wrapped — treat as if it reset to 0 and counted up.
        return newer
    }
}
