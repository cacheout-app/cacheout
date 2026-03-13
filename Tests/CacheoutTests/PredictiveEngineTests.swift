import XCTest
@testable import Cacheout
@testable import CacheoutShared

// MARK: - Stub Scan Provider

/// Deterministic scan provider for testing. Records call count and returns
/// a configurable result without touching live process state or XPC.
final class StubScanProvider: ProcessScanProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _scanCount = 0
    var scanResult: ProcessMemoryScanner.ScanResult

    var scanCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _scanCount
    }

    init(result: ProcessMemoryScanner.ScanResult = ProcessMemoryScanner.ScanResult(
        processes: [], source: "stub", partial: false
    )) {
        self.scanResult = result
    }

    func scan() async -> ProcessMemoryScanner.ScanResult {
        lock.lock()
        _scanCount += 1
        let result = scanResult
        lock.unlock()
        return result
    }
}

// MARK: - Tests

final class PredictiveEngineTests: XCTestCase {

    // MARK: - Time-to-Exhaustion: Nil Cases

    func testReturnsNilWithInsufficientSamples() async {
        let engine = PredictiveEngine(scanProvider: StubScanProvider())
        let base = Date()

        // Record only 10 samples (below the 30 minimum)
        for i in 0..<10 {
            await engine.recordAvailableMB(
                1000.0 - Double(i) * 50.0,
                at: base.addingTimeInterval(Double(i))
            )
        }

        let prediction = await engine.predictTimeToExhaustion()
        XCTAssertNil(prediction, "Should return nil with fewer than 30 samples")
    }

    func testReturnsNilWithPositiveSlope() async {
        let engine = PredictiveEngine(scanProvider: StubScanProvider())
        let base = Date()

        // Memory is increasing (positive slope) -- no exhaustion
        for i in 0..<40 {
            await engine.recordAvailableMB(
                500.0 + Double(i) * 10.0,
                at: base.addingTimeInterval(Double(i))
            )
        }

        let prediction = await engine.predictTimeToExhaustion()
        XCTAssertNil(prediction, "Should return nil when slope is positive (memory growing)")
    }

    func testReturnsNilWithFlatSlope() async {
        let engine = PredictiveEngine(scanProvider: StubScanProvider())
        let base = Date()

        // Memory is stable
        for i in 0..<40 {
            await engine.recordAvailableMB(
                2000.0,
                at: base.addingTimeInterval(Double(i))
            )
        }

        let prediction = await engine.predictTimeToExhaustion()
        XCTAssertNil(prediction, "Should return nil when slope is flat (stable memory)")
    }

    func testReturnsNilWithSlowConsumption() async {
        let engine = PredictiveEngine(scanProvider: StubScanProvider())
        let base = Date()

        // Very slow decline: -0.5 MB/sec (above -1.0 threshold)
        for i in 0..<40 {
            await engine.recordAvailableMB(
                5000.0 - Double(i) * 0.5,
                at: base.addingTimeInterval(Double(i))
            )
        }

        let prediction = await engine.predictTimeToExhaustion()
        XCTAssertNil(prediction, "Should return nil when slope is above -1.0 MB/sec threshold")
    }

    func testReturnsNilWhenEstimatedTimeExceedsMax() async {
        let engine = PredictiveEngine(scanProvider: StubScanProvider())
        let base = Date()

        // Decline at -2 MB/sec from 5000 MB = 2500 seconds (> 600s max)
        for i in 0..<40 {
            await engine.recordAvailableMB(
                5000.0 - Double(i) * 2.0,
                at: base.addingTimeInterval(Double(i))
            )
        }

        let prediction = await engine.predictTimeToExhaustion()
        XCTAssertNil(prediction, "Should return nil when estimated time exceeds 600 seconds")
    }

    // MARK: - Time-to-Exhaustion: Valid Predictions

    func testValidPredictionWithSteepDecline() async {
        let engine = PredictiveEngine(scanProvider: StubScanProvider())
        let base = Date()

        // Decline at -5 MB/sec from 500 MB = 100 seconds
        for i in 0..<40 {
            await engine.recordAvailableMB(
                500.0 - Double(i) * 5.0,
                at: base.addingTimeInterval(Double(i))
            )
        }

        let prediction = await engine.predictTimeToExhaustion()
        XCTAssertNotNil(prediction, "Should return a prediction with steep negative slope")

        // At t=39, available = 500 - 195 = 305 MB, slope = -5 MB/sec
        // Estimated = 305 / 5 = 61 seconds
        XCTAssertEqual(prediction!, 61.0, accuracy: 2.0,
            "Prediction should be approximately 61 seconds")
    }

    func testEdgeCaseSlopeExactlyMinusOne() async {
        let engine = PredictiveEngine(scanProvider: StubScanProvider())
        let base = Date()

        // Decline at exactly -1.0 MB/sec from 300 MB = 300 seconds
        // This should NOT trigger because slope must be < -1.0 (strictly)
        for i in 0..<40 {
            await engine.recordAvailableMB(
                300.0 - Double(i) * 1.0,
                at: base.addingTimeInterval(Double(i))
            )
        }

        let prediction = await engine.predictTimeToExhaustion()
        // slope = -1.0, threshold is < -1.0, so this should be nil
        XCTAssertNil(prediction, "Slope exactly -1.0 should not trigger (threshold is strictly < -1.0)")
    }

    func testPredictionWithExactly30Samples() async {
        let engine = PredictiveEngine(scanProvider: StubScanProvider())
        let base = Date()

        // Minimum samples with a steep decline
        for i in 0..<30 {
            await engine.recordAvailableMB(
                200.0 - Double(i) * 3.0,
                at: base.addingTimeInterval(Double(i))
            )
        }

        let prediction = await engine.predictTimeToExhaustion()
        XCTAssertNotNil(prediction, "Should work with exactly 30 samples")
    }

    // MARK: - Sliding Window Behavior

    func testSlidingWindowCapsAt60Samples() async {
        let engine = PredictiveEngine(scanProvider: StubScanProvider())
        let base = Date()

        // Record 80 samples -- window should hold only the last 60
        for i in 0..<80 {
            await engine.recordAvailableMB(
                1000.0 - Double(i) * 2.0,
                at: base.addingTimeInterval(Double(i))
            )
        }

        let count = await engine.sampleCount
        XCTAssertEqual(count, 60, "Sliding window should cap at 60 samples")
    }

    // MARK: - High-Growth Process Detection

    func testDetectsHighGrowthProcess() async {
        let engine = PredictiveEngine(scanProvider: StubScanProvider())

        let processes = [
            makeProcess(name: "leaky", physFootprint: 600 * 1024 * 1024, leakIndicator: 1.01),
            makeProcess(name: "normal", physFootprint: 800 * 1024 * 1024, leakIndicator: 2.0),
            makeProcess(name: "small-leak", physFootprint: 100 * 1024 * 1024, leakIndicator: 1.0),
        ]

        let results = await engine.detectHighGrowthProcesses(from: processes)
        XCTAssertEqual(results.count, 1, "Only one process meets both criteria")
        XCTAssertEqual(results.first?.name, "leaky")
    }

    func testExcludesProcessBelowFootprintThreshold() async {
        let engine = PredictiveEngine(scanProvider: StubScanProvider())

        let processes = [
            makeProcess(name: "small", physFootprint: 400 * 1024 * 1024, leakIndicator: 1.0),
        ]

        let results = await engine.detectHighGrowthProcesses(from: processes)
        XCTAssertTrue(results.isEmpty, "Process below 500MB should be excluded")
    }

    func testExcludesProcessWithHighLeakIndicator() async {
        let engine = PredictiveEngine(scanProvider: StubScanProvider())

        let processes = [
            makeProcess(name: "shrunk", physFootprint: 1024 * 1024 * 1024, leakIndicator: 1.5),
        ]

        let results = await engine.detectHighGrowthProcesses(from: processes)
        XCTAssertTrue(results.isEmpty, "Process with leakIndicator 1.5 should be excluded")
    }

    func testBoundaryLeakIndicator() async {
        let engine = PredictiveEngine(scanProvider: StubScanProvider())

        // leakIndicator exactly at 1.05 should be excluded (< 1.05 required)
        let processes = [
            makeProcess(name: "boundary", physFootprint: 600 * 1024 * 1024, leakIndicator: 1.05),
        ]

        let results = await engine.detectHighGrowthProcesses(from: processes)
        XCTAssertTrue(results.isEmpty, "leakIndicator exactly 1.05 should be excluded (strict < check)")
    }

    func testExcludesZeroLeakIndicator() async {
        let engine = PredictiveEngine(scanProvider: StubScanProvider())

        // leakIndicator 0 means no footprint data
        let processes = [
            makeProcess(name: "no-data", physFootprint: 600 * 1024 * 1024, leakIndicator: 0.0),
        ]

        let results = await engine.detectHighGrowthProcesses(from: processes)
        XCTAssertTrue(results.isEmpty, "Zero leakIndicator should be excluded")
    }

    func testDetectsMultipleHighGrowthProcesses() async {
        let engine = PredictiveEngine(scanProvider: StubScanProvider())

        let processes = [
            makeProcess(name: "grower1", physFootprint: 700 * 1024 * 1024, leakIndicator: 1.0),
            makeProcess(name: "grower2", physFootprint: 900 * 1024 * 1024, leakIndicator: 1.02),
            makeProcess(name: "normal", physFootprint: 700 * 1024 * 1024, leakIndicator: 1.5),
        ]

        let results = await engine.detectHighGrowthProcesses(from: processes)
        XCTAssertEqual(results.count, 2, "Both high-growth processes should be detected")
    }

    // MARK: - Process Scan Cache (Deterministic with Stub)

    func testCachePreservesFullScanResult() async {
        let engine = PredictiveEngine(scanProvider: StubScanProvider())

        let scanResult = ProcessMemoryScanner.ScanResult(
            processes: [makeProcess(name: "test", physFootprint: 100, leakIndicator: 1.0)],
            source: "proc_pid_rusage",
            partial: true
        )

        await engine.setCachedScanResult(scanResult)

        let cached = await engine.cachedScanResult
        XCTAssertNotNil(cached)
        XCTAssertTrue(cached!.partial, "Partial flag must be preserved in cache")
        XCTAssertEqual(cached!.source, "proc_pid_rusage")
        XCTAssertEqual(cached!.processes.count, 1)
    }

    func testCachePreservesNonPartialScanResult() async {
        let engine = PredictiveEngine(scanProvider: StubScanProvider())

        let scanResult = ProcessMemoryScanner.ScanResult(
            processes: [],
            source: "privileged_helper",
            partial: false
        )

        await engine.setCachedScanResult(scanResult)

        let cached = await engine.cachedScanResult
        XCTAssertNotNil(cached)
        XCTAssertFalse(cached!.partial, "Non-partial flag must be preserved")
        XCTAssertEqual(cached!.source, "privileged_helper")
    }

    func testFirstRequestTriggersScan() async {
        let stub = StubScanProvider(result: ProcessMemoryScanner.ScanResult(
            processes: [makeProcess(name: "stub-proc", physFootprint: 100, leakIndicator: 1.0)],
            source: "stub",
            partial: false
        ))
        let engine = PredictiveEngine(scanProvider: stub)

        // No scan yet
        XCTAssertEqual(stub.scanCount, 0, "No scan should have occurred yet")

        // First request triggers immediate scan
        let result = await engine.getOrRefreshScanResult()
        XCTAssertEqual(stub.scanCount, 1, "First request should trigger exactly one scan")
        XCTAssertEqual(result.source, "stub")
        XCTAssertEqual(result.processes.count, 1)
    }

    func testCacheUsedWhenFresh() async {
        let stub = StubScanProvider()
        let engine = PredictiveEngine(scanProvider: stub)

        // Set a fresh cached result (just now)
        let freshResult = ProcessMemoryScanner.ScanResult(
            processes: [makeProcess(name: "fresh", physFootprint: 100, leakIndicator: 1.0)],
            source: "test_source",
            partial: false
        )
        await engine.setCachedScanResult(freshResult)

        let result = await engine.getOrRefreshScanResult()
        XCTAssertEqual(result.source, "test_source",
            "Should return cached result when fresh (< 30 seconds)")
        XCTAssertEqual(stub.scanCount, 0, "Should not trigger a scan when cache is fresh")
    }

    func testCacheRefreshesAfter30Seconds() async {
        let stub = StubScanProvider(result: ProcessMemoryScanner.ScanResult(
            processes: [makeProcess(name: "refreshed", physFootprint: 200, leakIndicator: 1.0)],
            source: "refreshed_stub",
            partial: false
        ))
        let engine = PredictiveEngine(scanProvider: stub)

        // Set a stale cached result (31 seconds ago)
        let staleResult = ProcessMemoryScanner.ScanResult(
            processes: [makeProcess(name: "stale", physFootprint: 100, leakIndicator: 1.0)],
            source: "stale_source",
            partial: false
        )
        let staleTime = Date().addingTimeInterval(-31.0)
        await engine.setCachedScanResult(staleResult, at: staleTime)

        // getOrRefreshScanResult should trigger a new scan
        let result = await engine.getOrRefreshScanResult()
        XCTAssertEqual(stub.scanCount, 1, "Should trigger exactly one scan for stale cache")
        XCTAssertEqual(result.source, "refreshed_stub", "Should return fresh scan result")
        XCTAssertEqual(result.processes.first?.name, "refreshed")
    }

    func testConcurrentRefreshCoalesces() async {
        let stub = StubScanProvider(result: ProcessMemoryScanner.ScanResult(
            processes: [], source: "coalesced", partial: false
        ))
        let engine = PredictiveEngine(scanProvider: stub)

        // Launch multiple concurrent requests -- should coalesce into one scan
        await withTaskGroup(of: ProcessMemoryScanner.ScanResult.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    await engine.getOrRefreshScanResult()
                }
            }
            for await result in group {
                XCTAssertEqual(result.source, "coalesced")
            }
        }

        // All 5 concurrent callers should have shared at most a few scans
        // (actor serialization means some may see the cache after the first completes)
        XCTAssertLessThanOrEqual(stub.scanCount, 2,
            "Concurrent refresh should coalesce, not launch 5 separate scans")
    }

    // MARK: - Thread Safety (Actor Isolation)

    func testConcurrentAccess() async {
        let engine = PredictiveEngine(scanProvider: StubScanProvider())
        let base = Date()

        await withTaskGroup(of: Void.self) { group in
            // Writers
            for i in 0..<100 {
                group.addTask {
                    await engine.recordAvailableMB(
                        1000.0 - Double(i) * 5.0,
                        at: base.addingTimeInterval(Double(i))
                    )
                }
            }
            // Readers
            for _ in 0..<50 {
                group.addTask {
                    _ = await engine.predictTimeToExhaustion()
                    _ = await engine.detectHighGrowthProcesses(from: [])
                    _ = await engine.sampleCount
                }
            }
        }

        let count = await engine.sampleCount
        // Ring buffer caps at 60 but we fed 100 samples
        XCTAssertLessThanOrEqual(count, PredictiveEngine.maxSamples)
    }

    // MARK: - Helpers

    private func makeProcess(
        name: String,
        physFootprint: UInt64,
        leakIndicator: Double
    ) -> ProcessEntryDTO {
        ProcessEntryDTO(
            pid: 1000,
            name: name,
            physFootprint: physFootprint,
            lifetimeMaxFootprint: UInt64(Double(physFootprint) * leakIndicator),
            pageins: 0,
            jetsamPriority: -1,
            jetsamLimit: -1,
            isRosetta: false,
            leakIndicator: leakIndicator
        )
    }
}
