import XCTest
@testable import Cacheout
@testable import CacheoutShared

// MARK: - Test Helpers

private func makeProcess(
    pid: Int32 = 1000,
    name: String,
    physFootprint: UInt64,
    leakIndicator: Double = 2.0,
    isRosetta: Bool = false
) -> ProcessEntryDTO {
    ProcessEntryDTO(
        pid: pid,
        name: name,
        physFootprint: physFootprint,
        lifetimeMaxFootprint: UInt64(Double(physFootprint) * leakIndicator),
        pageins: 0,
        jetsamPriority: -1,
        jetsamLimit: -1,
        isRosetta: isRosetta,
        leakIndicator: leakIndicator
    )
}

private func makeStats(
    compressionRatio: Double = 3.0,
    swapUsedBytes: UInt64 = 0,
    swapTotalBytes: UInt64 = 4_000_000_000
) -> SystemStatsDTO {
    SystemStatsDTO(
        timestamp: Date(),
        freePages: 100_000,
        activePages: 200_000,
        inactivePages: 50_000,
        wiredPages: 80_000,
        compressorPageCount: 30_000,
        compressedBytes: 1_000_000,
        compressorBytesUsed: 500_000,
        compressionRatio: compressionRatio,
        pageSize: 16384,
        purgeableCount: 100,
        externalPages: 200,
        internalPages: 300,
        compressions: 1000,
        decompressions: 500,
        pageins: 0,
        pageouts: 0,
        swapUsedBytes: swapUsedBytes,
        swapTotalBytes: swapTotalBytes,
        pressureLevel: 0,
        memoryTier: "moderate",
        totalPhysicalMemory: 16 * 1024 * 1024 * 1024
    )
}

// MARK: - AgentDetector Tests

final class AgentDetectorTests: XCTestCase {

    func testDetectsKnownAgents() {
        for name in ["ollama", "llama-server", "llama-cli", "mlx_lm.server", "claude"] {
            let proc = makeProcess(name: name, physFootprint: 1024)
            XCTAssertTrue(AgentDetector.isAgent(proc), "Should detect \(name) as agent")
        }
    }

    func testIgnoresNonAgents() {
        for name in ["Safari", "python3", "node", "Xcode"] {
            let proc = makeProcess(name: name, physFootprint: 1024)
            XCTAssertFalse(AgentDetector.isAgent(proc), "\(name) should not be detected as agent")
        }
    }

    func testAgentProcessesFilter() {
        let processes = [
            makeProcess(name: "ollama", physFootprint: 1024),
            makeProcess(name: "Safari", physFootprint: 2048),
            makeProcess(name: "claude", physFootprint: 512),
        ]
        let agents = AgentDetector.agentProcesses(from: processes)
        XCTAssertEqual(agents.count, 2)
        XCTAssertEqual(Set(agents.map(\.name)), Set(["ollama", "claude"]))
    }
}

// MARK: - RecommendationEngine Tests

final class RecommendationEngineTests: XCTestCase {

    // MARK: - exhaustion_imminent

    func testExhaustionImminentDaemonOnly() async {
        let stub = StubScanProvider()
        let engine = PredictiveEngine(scanProvider: stub)
        let base = Date()

        // Feed steep decline: -5 MB/sec from 500 MB
        for i in 0..<40 {
            await engine.recordAvailableMB(
                500.0 - Double(i) * 5.0,
                at: base.addingTimeInterval(Double(i))
            )
        }

        let result = await RecommendationEngine.generateRecommendations(
            mode: .daemon,
            predictiveEngine: engine,
            compressorTracker: nil,
            systemStats: makeStats()
        )

        let exhaustion = result.recommendations.filter { $0.type == .exhaustionImminent }
        XCTAssertEqual(exhaustion.count, 1)
        XCTAssertEqual(exhaustion.first?.confidence, .high)
        XCTAssertEqual(exhaustion.first?.source, "daemon")
    }

    func testExhaustionImminentOmittedInCLI() async {
        let stub = StubScanProvider()
        let engine = PredictiveEngine(scanProvider: stub)
        let base = Date()

        for i in 0..<40 {
            await engine.recordAvailableMB(
                500.0 - Double(i) * 5.0,
                at: base.addingTimeInterval(Double(i))
            )
        }

        let result = await RecommendationEngine.generateRecommendations(
            mode: .cli,
            predictiveEngine: engine,
            compressorTracker: nil,
            systemStats: makeStats()
        )

        let exhaustion = result.recommendations.filter { $0.type == .exhaustionImminent }
        XCTAssertTrue(exhaustion.isEmpty, "exhaustion_imminent should not be emitted in CLI mode")
    }

    // MARK: - compressor_degrading

    func testCompressorDegradingDaemonOnly() async {
        let stub = StubScanProvider()
        let engine = PredictiveEngine(scanProvider: stub)
        let tracker = CompressorTracker()

        // Feed declining compression ratio
        let base = Date()
        for i in 0..<60 {
            let stats = SystemStatsDTO(
                timestamp: base.addingTimeInterval(Double(i)),
                freePages: 100_000,
                activePages: 200_000,
                inactivePages: 50_000,
                wiredPages: 80_000,
                compressorPageCount: 30_000,
                compressedBytes: 1_000_000,
                compressorBytesUsed: 500_000,
                compressionRatio: 3.0 - Double(i) * 0.03,
                pageSize: 16384,
                purgeableCount: 100,
                externalPages: 200,
                internalPages: 300,
                compressions: 1000 + UInt64(i) * 100,
                decompressions: 500,
                pageins: 0,
                pageouts: 0,
                swapUsedBytes: 0,
                swapTotalBytes: 4_000_000_000,
                pressureLevel: 0,
                memoryTier: "moderate",
                totalPhysicalMemory: 16 * 1024 * 1024 * 1024
            )
            await tracker.record(stats)
        }

        let result = await RecommendationEngine.generateRecommendations(
            mode: .daemon,
            predictiveEngine: engine,
            compressorTracker: tracker,
            systemStats: makeStats()
        )

        let degrading = result.recommendations.filter { $0.type == .compressorDegrading }
        XCTAssertEqual(degrading.count, 1)
        XCTAssertEqual(degrading.first?.confidence, .high)
    }

    func testCompressorDegradingOmittedInCLI() async {
        let stub = StubScanProvider()
        let engine = PredictiveEngine(scanProvider: stub)
        let tracker = CompressorTracker()

        let result = await RecommendationEngine.generateRecommendations(
            mode: .cli,
            predictiveEngine: engine,
            compressorTracker: tracker,
            systemStats: makeStats()
        )

        let degrading = result.recommendations.filter { $0.type == .compressorDegrading }
        XCTAssertTrue(degrading.isEmpty, "compressor_degrading should not be emitted in CLI mode")
    }

    // MARK: - compressor_low_ratio

    func testCompressorLowRatioAllModes() async {
        let stub = StubScanProvider()
        let engine = PredictiveEngine(scanProvider: stub)

        let stats = makeStats(compressionRatio: 1.5)

        for mode: RecommendationSource in [.cli, .daemon] {
            let result = await RecommendationEngine.generateRecommendations(
                mode: mode,
                predictiveEngine: engine,
                compressorTracker: nil,
                systemStats: stats
            )

            let lowRatio = result.recommendations.filter { $0.type == .compressorLowRatio }
            XCTAssertEqual(lowRatio.count, 1, "compressor_low_ratio should be emitted in \(mode.rawValue) mode")
        }
    }

    func testCompressorNormalRatioNoRecommendation() async {
        let stub = StubScanProvider()
        let engine = PredictiveEngine(scanProvider: stub)

        let stats = makeStats(compressionRatio: 3.0)
        let result = await RecommendationEngine.generateRecommendations(
            mode: .daemon,
            predictiveEngine: engine,
            compressorTracker: nil,
            systemStats: stats
        )

        let lowRatio = result.recommendations.filter { $0.type == .compressorLowRatio }
        XCTAssertTrue(lowRatio.isEmpty)
    }

    // MARK: - high_growth_process

    func testHighGrowthProcess() async {
        let processes = [
            makeProcess(pid: 123, name: "leaky", physFootprint: 700 * 1024 * 1024, leakIndicator: 1.01),
        ]
        let stub = StubScanProvider(result: ProcessMemoryScanner.ScanResult(
            processes: processes, source: "stub", partial: false
        ))
        let engine = PredictiveEngine(scanProvider: stub)

        let result = await RecommendationEngine.generateRecommendations(
            mode: .daemon,
            predictiveEngine: engine,
            compressorTracker: nil,
            systemStats: makeStats()
        )

        let growth = result.recommendations.filter { $0.type == .highGrowthProcess }
        XCTAssertEqual(growth.count, 1)
        XCTAssertEqual(growth.first?.process, "leaky")
        XCTAssertEqual(growth.first?.pid, 123)
    }

    // MARK: - rosetta_detected

    func testRosettaDetected() async {
        let processes = [
            makeProcess(pid: 456, name: "rosetta-app", physFootprint: 300 * 1024 * 1024, isRosetta: true),
        ]
        let stub = StubScanProvider(result: ProcessMemoryScanner.ScanResult(
            processes: processes, source: "stub", partial: false
        ))
        let engine = PredictiveEngine(scanProvider: stub)

        let result = await RecommendationEngine.generateRecommendations(
            mode: .daemon,
            predictiveEngine: engine,
            compressorTracker: nil,
            systemStats: makeStats()
        )

        let rosetta = result.recommendations.filter { $0.type == .rosettaDetected }
        XCTAssertEqual(rosetta.count, 1)
        XCTAssertEqual(rosetta.first?.process, "rosetta-app")
    }

    func testRosettaSmallProcessIgnored() async {
        let processes = [
            makeProcess(name: "tiny-rosetta", physFootprint: 50 * 1024 * 1024, isRosetta: true),
        ]
        let stub = StubScanProvider(result: ProcessMemoryScanner.ScanResult(
            processes: processes, source: "stub", partial: false
        ))
        let engine = PredictiveEngine(scanProvider: stub)

        let result = await RecommendationEngine.generateRecommendations(
            mode: .daemon,
            predictiveEngine: engine,
            compressorTracker: nil,
            systemStats: makeStats()
        )

        let rosetta = result.recommendations.filter { $0.type == .rosettaDetected }
        XCTAssertTrue(rosetta.isEmpty, "Small Rosetta process should be ignored")
    }

    // MARK: - agent_memory_pressure

    func testAgentMemoryPressure() async {
        let processes = [
            makeProcess(pid: 789, name: "ollama", physFootprint: 2 * 1024 * 1024 * 1024),
        ]
        let stub = StubScanProvider(result: ProcessMemoryScanner.ScanResult(
            processes: processes, source: "stub", partial: false
        ))
        let engine = PredictiveEngine(scanProvider: stub)

        let result = await RecommendationEngine.generateRecommendations(
            mode: .daemon,
            predictiveEngine: engine,
            compressorTracker: nil,
            systemStats: makeStats()
        )

        let agent = result.recommendations.filter { $0.type == .agentMemoryPressure }
        XCTAssertEqual(agent.count, 1)
        XCTAssertEqual(agent.first?.process, "ollama")
    }

    func testAgentSmallFootprintIgnored() async {
        let processes = [
            makeProcess(name: "claude", physFootprint: 100 * 1024 * 1024),
        ]
        let stub = StubScanProvider(result: ProcessMemoryScanner.ScanResult(
            processes: processes, source: "stub", partial: false
        ))
        let engine = PredictiveEngine(scanProvider: stub)

        let result = await RecommendationEngine.generateRecommendations(
            mode: .daemon,
            predictiveEngine: engine,
            compressorTracker: nil,
            systemStats: makeStats()
        )

        let agent = result.recommendations.filter { $0.type == .agentMemoryPressure }
        XCTAssertTrue(agent.isEmpty, "Small agent should not trigger recommendation")
    }

    // MARK: - swap_pressure

    func testSwapPressure() async {
        let stub = StubScanProvider()
        let engine = PredictiveEngine(scanProvider: stub)

        // 60% swap usage
        let stats = makeStats(swapUsedBytes: 2_400_000_000, swapTotalBytes: 4_000_000_000)
        let result = await RecommendationEngine.generateRecommendations(
            mode: .daemon,
            predictiveEngine: engine,
            compressorTracker: nil,
            systemStats: stats
        )

        let swap = result.recommendations.filter { $0.type == .swapPressure }
        XCTAssertEqual(swap.count, 1)
    }

    func testSwapNormalNoRecommendation() async {
        let stub = StubScanProvider()
        let engine = PredictiveEngine(scanProvider: stub)

        // 10% swap usage
        let stats = makeStats(swapUsedBytes: 400_000_000, swapTotalBytes: 4_000_000_000)
        let result = await RecommendationEngine.generateRecommendations(
            mode: .daemon,
            predictiveEngine: engine,
            compressorTracker: nil,
            systemStats: stats
        )

        let swap = result.recommendations.filter { $0.type == .swapPressure }
        XCTAssertTrue(swap.isEmpty)
    }

    // MARK: - Partial Scan Propagation

    func testPartialScanLowConfidence() async {
        let processes = [
            makeProcess(pid: 123, name: "leaky", physFootprint: 700 * 1024 * 1024, leakIndicator: 1.01),
            makeProcess(pid: 456, name: "ollama", physFootprint: 600 * 1024 * 1024),
            makeProcess(pid: 789, name: "rosetta-big", physFootprint: 300 * 1024 * 1024, isRosetta: true),
        ]
        let stub = StubScanProvider(result: ProcessMemoryScanner.ScanResult(
            processes: processes, source: "proc_pid_rusage", partial: true
        ))
        let engine = PredictiveEngine(scanProvider: stub)

        let result = await RecommendationEngine.generateRecommendations(
            mode: .daemon,
            predictiveEngine: engine,
            compressorTracker: nil,
            systemStats: makeStats()
        )

        XCTAssertTrue(result.scanPartial, "scanPartial should be true when ScanResult.partial is true")

        // All process-based recommendations should have low confidence
        let processRecs = result.recommendations.filter {
            [.highGrowthProcess, .rosettaDetected, .agentMemoryPressure].contains($0.type)
        }
        XCTAssertFalse(processRecs.isEmpty)
        for rec in processRecs {
            XCTAssertEqual(rec.confidence, .low,
                "\(rec.type.rawValue) should have low confidence when scan is partial")
        }
    }

    func testNonPartialScanHighConfidence() async {
        let processes = [
            makeProcess(pid: 123, name: "leaky", physFootprint: 700 * 1024 * 1024, leakIndicator: 1.01),
        ]
        let stub = StubScanProvider(result: ProcessMemoryScanner.ScanResult(
            processes: processes, source: "privileged_helper", partial: false
        ))
        let engine = PredictiveEngine(scanProvider: stub)

        let result = await RecommendationEngine.generateRecommendations(
            mode: .daemon,
            predictiveEngine: engine,
            compressorTracker: nil,
            systemStats: makeStats()
        )

        XCTAssertFalse(result.scanPartial)

        let growth = result.recommendations.filter { $0.type == .highGrowthProcess }
        XCTAssertEqual(growth.first?.confidence, .high)
    }

    // MARK: - CLI Golden JSON Test

    func testCLIGoldenSnakeCaseFields() async {
        let processes = [
            makeProcess(pid: 100, name: "ollama", physFootprint: 2 * 1024 * 1024 * 1024),
        ]
        let stub = StubScanProvider(result: ProcessMemoryScanner.ScanResult(
            processes: processes, source: "stub", partial: false
        ))
        let engine = PredictiveEngine(scanProvider: stub)

        let stats = makeStats(compressionRatio: 1.5, swapUsedBytes: 2_400_000_000)
        let result = await RecommendationEngine.generateRecommendations(
            mode: .cli,
            predictiveEngine: engine,
            compressorTracker: nil,
            systemStats: stats
        )

        // Encode to JSON and verify snake_case field names
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try! encoder.encode(result.recommendations)
        let json = String(data: data, encoding: .utf8)!

        // Verify snake_case keys are present
        XCTAssertTrue(json.contains("\"impact_value\""), "Should have snake_case impact_value")
        XCTAssertTrue(json.contains("\"impact_unit\""), "Should have snake_case impact_unit")

        // Verify camelCase keys are absent
        XCTAssertFalse(json.contains("\"impactValue\""), "Should NOT have camelCase impactValue")
        XCTAssertFalse(json.contains("\"impactUnit\""), "Should NOT have camelCase impactUnit")

        // Verify expected recommendation types in CLI mode
        let types = result.recommendations.map(\.type)
        // Should include snapshot types
        XCTAssertTrue(types.contains(.agentMemoryPressure))
        XCTAssertTrue(types.contains(.compressorLowRatio))
        XCTAssertTrue(types.contains(.swapPressure))
        // Should NOT include trend types in CLI mode
        XCTAssertFalse(types.contains(.exhaustionImminent))
        XCTAssertFalse(types.contains(.compressorDegrading))
    }

    // MARK: - Tier2 Agent Exclusion

    func testAgentExcludedFromJetsamCandidates() {
        // Verify AgentDetector correctly identifies known agents — this is the
        // guard used by Tier2Interventions.swift to exclude agents from JetsamHWM
        // candidate selection. The full JetsamHWM path requires XPC + priority
        // data and cannot be unit-tested, but the guard predicate can.
        for agentName in AgentDetector.knownAgentNames {
            let proc = makeProcess(name: agentName, physFootprint: 1024 * 1024 * 1024)
            XCTAssertTrue(AgentDetector.isAgent(proc),
                "\(agentName) should be excluded from Tier2 JetsamHWM candidates")
        }

        // Non-agents should NOT be excluded
        for name in ["Safari", "Xcode", "Terminal", "node"] {
            let proc = makeProcess(name: name, physFootprint: 1024 * 1024 * 1024)
            XCTAssertFalse(AgentDetector.isAgent(proc),
                "\(name) should remain eligible for Tier2 JetsamHWM")
        }
    }
}

// MARK: - Socket Recommendations Command Test

final class StatusSocketRecommendationsTests: XCTestCase {

    private func makeShortTmpDir() throws -> URL {
        let suffix = String(UInt32.random(in: 10000...99999))
        let dir = URL(fileURLWithPath: "/tmp/co-\(suffix)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testRecommendationsCommandReturnsExpectedFormat() async throws {
        let tmpDir = try makeShortTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let socketPath = tmpDir.appendingPathComponent("status.sock").path
        let mockSource = MockRecommendationsDataSource()
        let socket = StatusSocket(socketPath: socketPath, dataSource: mockSource)
        try socket.start()
        defer { socket.stop() }

        let response = try sendSocketCommand("{\"cmd\":\"recommendations\"}\n", to: socketPath)
        let json = try JSONSerialization.jsonObject(with: response.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(json["ok"] as? Bool, true)

        let data = json["data"] as! [String: Any]
        XCTAssertNotNil(data["recommendations"])
        let meta = data["_meta"] as! [String: Any]
        XCTAssertNotNil(meta["count"])
        XCTAssertEqual(meta["source"] as? String, "daemon")
        XCTAssertNotNil(meta["scan_partial"])
    }

    func testRecommendationsCommandNotAvailable() async throws {
        let tmpDir = try makeShortTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let socketPath = tmpDir.appendingPathComponent("status.sock").path
        let mockSource = MockNilRecommendationsDataSource()
        let socket = StatusSocket(socketPath: socketPath, dataSource: mockSource)
        try socket.start()
        defer { socket.stop() }

        let response = try sendSocketCommand("{\"cmd\":\"recommendations\"}\n", to: socketPath)
        let json = try JSONSerialization.jsonObject(with: response.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(json["ok"] as? Bool, false)
    }
}

// MARK: - Test Helpers (socket)

private func sendSocketCommand(_ command: String, to path: String) throws -> String {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw NSError(domain: "socket", code: Int(errno)) }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let pathCString = path.utf8CString
    withUnsafeMutableBytes(of: &addr.sun_path) { pathPtr in
        pathCString.withUnsafeBufferPointer { cBuf in
            let copyLen = min(cBuf.count, pathPtr.count)
            for i in 0..<copyLen {
                pathPtr[i] = UInt8(bitPattern: cBuf[i])
            }
        }
    }

    let connectResult = withUnsafePointer(to: &addr) { addrPtr in
        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else { throw NSError(domain: "connect", code: Int(errno)) }

    let bytes = Array(command.utf8)
    _ = bytes.withUnsafeBufferPointer { buf in
        Darwin.write(fd, buf.baseAddress!, buf.count)
    }

    var readBuf = [UInt8](repeating: 0, count: 65536)
    let n = read(fd, &readBuf, readBuf.count)
    guard n > 0 else { throw NSError(domain: "read", code: Int(errno)) }

    return String(bytes: readBuf[0..<n], encoding: .utf8) ?? ""
}

// Mock that returns recommendations
private final class MockRecommendationsDataSource: StatusSocket.DataSource {
    func currentSnapshot() async -> DaemonSnapshot? { nil }
    func sampleHistory() async -> [DaemonSnapshot] { [] }
    func activeAlerts() async -> [DaemonAlert] { [] }
    func configStatus() async -> ConfigStatus { ConfigStatus() }
    func helperAvailable() async -> Bool { false }
    func recommendations() async -> RecommendationResult? {
        RecommendationResult(recommendations: [], scanPartial: false)
    }
}

// Mock that returns nil (engine not wired)
private final class MockNilRecommendationsDataSource: StatusSocket.DataSource {
    func currentSnapshot() async -> DaemonSnapshot? { nil }
    func sampleHistory() async -> [DaemonSnapshot] { [] }
    func activeAlerts() async -> [DaemonAlert] { [] }
    func configStatus() async -> ConfigStatus { ConfigStatus() }
    func helperAvailable() async -> Bool { false }
    func recommendations() async -> RecommendationResult? { nil }
}
