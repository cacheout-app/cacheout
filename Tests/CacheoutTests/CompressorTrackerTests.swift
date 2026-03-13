import XCTest
@testable import Cacheout
@testable import CacheoutShared

final class CompressorTrackerTests: XCTestCase {

    // MARK: - Helpers

    /// Create a SystemStatsDTO with specific compressor fields; others use defaults.
    private func makeStats(
        timestamp: Date = Date(),
        compressions: UInt64 = 0,
        decompressions: UInt64 = 0,
        compressionRatio: Double = 2.0,
        compressedBytes: UInt64 = 1000,
        compressorBytesUsed: UInt64 = 500
    ) -> SystemStatsDTO {
        SystemStatsDTO(
            timestamp: timestamp,
            freePages: 1000,
            activePages: 2000,
            inactivePages: 500,
            wiredPages: 800,
            compressorPageCount: 300,
            compressedBytes: compressedBytes,
            compressorBytesUsed: compressorBytesUsed,
            compressionRatio: compressionRatio,
            pageSize: 16384,
            purgeableCount: 100,
            externalPages: 200,
            internalPages: 300,
            compressions: compressions,
            decompressions: decompressions,
            pageins: 0,
            pageouts: 0,
            swapUsedBytes: 0,
            swapTotalBytes: 0,
            pressureLevel: 0,
            memoryTier: "moderate",
            totalPhysicalMemory: 16 * 1024 * 1024 * 1024
        )
    }

    // MARK: - Ring Buffer Tests

    func testRecordsUpToMaxSamples() async {
        let tracker = CompressorTracker()
        let base = Date()

        // Record 310 samples — buffer should cap at 300.
        for i in 0..<310 {
            let stats = makeStats(
                timestamp: base.addingTimeInterval(Double(i)),
                compressions: UInt64(i * 100),
                decompressions: UInt64(i * 50)
            )
            await tracker.record(stats)
        }

        let count = await tracker.sampleCount
        XCTAssertEqual(count, 300, "Ring buffer should hold at most 300 samples")
    }

    func testSingleSampleNoRates() async {
        let tracker = CompressorTracker()
        await tracker.record(makeStats(compressions: 100, decompressions: 50))

        let compRate = await tracker.compressionRate()
        let decompRate = await tracker.decompressionRate()
        XCTAssertNil(compRate, "Need at least 2 samples for rate")
        XCTAssertNil(decompRate, "Need at least 2 samples for rate")
    }

    // MARK: - Rate Tests

    func testCompressionRateFromDeltas() async {
        let tracker = CompressorTracker()
        let base = Date()

        await tracker.record(makeStats(
            timestamp: base,
            compressions: 1000,
            decompressions: 500
        ))
        await tracker.record(makeStats(
            timestamp: base.addingTimeInterval(1.0),
            compressions: 1200,
            decompressions: 600
        ))

        let compRate = await tracker.compressionRate()
        let decompRate = await tracker.decompressionRate()
        XCTAssertNotNil(compRate)
        XCTAssertNotNil(decompRate)
        XCTAssertEqual(compRate!, 200.0, accuracy: 0.01, "200 compressions over 1 second")
        XCTAssertEqual(decompRate!, 100.0, accuracy: 0.01, "100 decompressions over 1 second")
    }

    func testRateWithZeroTimeDelta() async {
        let tracker = CompressorTracker()
        let t = Date()

        await tracker.record(makeStats(timestamp: t, compressions: 100))
        await tracker.record(makeStats(timestamp: t, compressions: 200))

        let rate = await tracker.compressionRate()
        XCTAssertNil(rate, "Zero time delta should return nil")
    }

    // MARK: - Ratio Trend Tests

    func testTrendStableWithInsufficientData() async {
        let tracker = CompressorTracker()
        await tracker.record(makeStats())
        let trend = await tracker.compressionRatioTrend()
        XCTAssertEqual(trend, .stable)
    }

    func testTrendImprovingWithIncreasingRatio() async {
        let tracker = CompressorTracker()
        let base = Date()

        // Simulate increasing compression ratio over 60 samples.
        for i in 0..<60 {
            let ratio = 1.5 + Double(i) * 0.02 // 1.5 → 2.68
            await tracker.record(makeStats(
                timestamp: base.addingTimeInterval(Double(i)),
                compressions: UInt64(i * 100 + 100),
                decompressions: UInt64(i * 50),
                compressionRatio: ratio
            ))
        }

        let trend = await tracker.compressionRatioTrend()
        if case .improving(let slope) = trend {
            XCTAssertGreaterThan(slope, 0)
        } else {
            XCTFail("Expected improving trend, got \(trend)")
        }
    }

    func testTrendDecliningWithDecreasingRatio() async {
        let tracker = CompressorTracker()
        let base = Date()

        // Simulate decreasing compression ratio.
        for i in 0..<60 {
            let ratio = 3.0 - Double(i) * 0.02 // 3.0 → 1.82
            await tracker.record(makeStats(
                timestamp: base.addingTimeInterval(Double(i)),
                compressions: UInt64(i * 100 + 100),
                decompressions: UInt64(i * 50),
                compressionRatio: ratio
            ))
        }

        let trend = await tracker.compressionRatioTrend()
        if case .declining(let slope) = trend {
            XCTAssertLessThan(slope, 0)
        } else {
            XCTFail("Expected declining trend, got \(trend)")
        }
    }

    func testTrendStableWhenCompressionDeltaNearZero() async {
        let tracker = CompressorTracker()
        let base = Date()

        // Compressions barely change — ratio is meaningless.
        for i in 0..<60 {
            await tracker.record(makeStats(
                timestamp: base.addingTimeInterval(Double(i)),
                compressions: 100, // static
                decompressions: 50,
                compressionRatio: Double(i) * 0.1 // would show a trend, but compressions ~0 delta
            ))
        }

        let trend = await tracker.compressionRatioTrend()
        XCTAssertEqual(trend, .stable,
            "Near-zero compression delta should report stable regardless of ratio changes")
    }

    // MARK: - Thrashing Detection Tests

    func testNoThrashingWithNormalRates() async {
        let tracker = CompressorTracker()
        let base = Date()

        // Normal operation: decomp rate ~ comp rate.
        for i in 0..<60 {
            await tracker.record(makeStats(
                timestamp: base.addingTimeInterval(Double(i)),
                compressions: UInt64(i * 200),
                decompressions: UInt64(i * 200) // 1:1 ratio
            ))
        }

        let thrashing = await tracker.isThrashing()
        XCTAssertFalse(thrashing)
    }

    func testThrashingDetectedWhenSustained() async {
        let tracker = CompressorTracker()
        let base = Date()

        // Sustained thrashing: decomp rate = 3× comp rate, both above threshold.
        for i in 0..<60 {
            await tracker.record(makeStats(
                timestamp: base.addingTimeInterval(Double(i)),
                compressions: UInt64(i * 200),   // 200/sec
                decompressions: UInt64(i * 800)  // 800/sec (4× comp rate)
            ))
        }

        let thrashing = await tracker.isThrashing()
        XCTAssertTrue(thrashing, "Should detect thrashing when decomp >> comp for >30s")
    }

    func testNoThrashingWhenBelowAbsoluteMinimum() async {
        let tracker = CompressorTracker()
        let base = Date()

        // Both rates near zero — ratio is high but absolute values are low.
        for i in 0..<60 {
            await tracker.record(makeStats(
                timestamp: base.addingTimeInterval(Double(i)),
                compressions: UInt64(i * 2),    // 2/sec
                decompressions: UInt64(i * 10)  // 10/sec (5× but only 10/sec)
            ))
        }

        let thrashing = await tracker.isThrashing()
        XCTAssertFalse(thrashing,
            "Should not detect thrashing when decompression rate below absolute minimum")
    }

    func testNoThrashingWhenNotSustained() async {
        let tracker = CompressorTracker()
        let base = Date()

        // Thrashing for 20s, then normal for 10s, then thrashing for 20s.
        // No continuous 30s window.
        for i in 0..<50 {
            let decomps: UInt64
            if i < 20 {
                // Thrashing phase 1: decomp = 4× comp.
                decomps = UInt64(i * 800)
            } else if i < 30 {
                // Normal phase: decomp = comp.
                decomps = UInt64(20 * 800 + (i - 20) * 200)
            } else {
                // Thrashing phase 2: decomp = 4× comp again.
                decomps = UInt64(20 * 800 + 10 * 200 + (i - 30) * 800)
            }
            await tracker.record(makeStats(
                timestamp: base.addingTimeInterval(Double(i)),
                compressions: UInt64(i * 200),
                decompressions: decomps
            ))
        }

        let thrashing = await tracker.isThrashing()
        XCTAssertFalse(thrashing,
            "Interrupted thrashing (no continuous 30s window) should not be detected")
    }

    // MARK: - Thread Safety (Actor Isolation)

    func testConcurrentAccess() async {
        let tracker = CompressorTracker()
        let base = Date()

        // Concurrent writes and reads should not crash.
        await withTaskGroup(of: Void.self) { group in
            // Writers
            for i in 0..<100 {
                group.addTask {
                    await tracker.record(self.makeStats(
                        timestamp: base.addingTimeInterval(Double(i)),
                        compressions: UInt64(i * 100),
                        decompressions: UInt64(i * 50),
                        compressionRatio: 2.0
                    ))
                }
            }
            // Readers
            for _ in 0..<50 {
                group.addTask {
                    _ = await tracker.compressionRate()
                    _ = await tracker.decompressionRate()
                    _ = await tracker.compressionRatioTrend()
                    _ = await tracker.isThrashing()
                }
            }
        }

        let count = await tracker.sampleCount
        XCTAssertEqual(count, 100)
    }
}
