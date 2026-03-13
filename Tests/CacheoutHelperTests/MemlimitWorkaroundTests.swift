import XCTest
import CKernelPrivate
@testable import CacheoutHelperLib

// MARK: - Mock MemorystatusControl Provider

final class MockMemorystatusProvider: MemorystatusControlProvider {
    /// Track all calls for assertions.
    var calls: [(command: UInt32, pid: Int32, flags: UInt32, buffer: Data?, bufferSize: Int)] = []

    /// Return value for the next call. Default: 0 (success).
    var returnValue: Int32 = 0

    /// If set, errno is set to this value when returnValue is -1.
    var errnoToSet: Int32 = 0

    func control(command: UInt32, pid: Int32, flags: UInt32,
                 buffer: UnsafeMutableRawPointer?, bufferSize: Int) -> Int32 {
        let bufferData: Data?
        if let buffer, bufferSize > 0 {
            bufferData = Data(bytes: buffer, count: bufferSize)
        } else {
            bufferData = nil
        }
        calls.append((command: command, pid: pid, flags: flags, buffer: bufferData, bufferSize: bufferSize))
        if returnValue != 0 {
            errno = errnoToSet
        }
        return returnValue
    }
}

// MARK: - Mock Bug Detector

struct ForcedBugDetector: MemlimitBugDetector {
    let bugPresent: Bool
    func detectBug() -> Bool { bugPresent }
}

// MARK: - Mock System Info Provider

struct MockSystemInfo: SystemInfoProvider {
    let ramBytes: UInt64?
    let probeResult: Int32
    let probeErrno: Int32

    func physicalMemoryBytes() -> UInt64? { ramBytes }

    func probeMemlimitConversion(limitMB: UInt32) -> (result: Int32, errno: Int32) {
        (probeResult, probeErrno)
    }
}

// MARK: - Tests

final class MemlimitWorkaroundTests: XCTestCase {

    // MARK: - setJetsamLimit input validation

    func testRejectsInvalidPID() {
        let mock = MockMemorystatusProvider()
        let workaround = MemlimitWorkaround(provider: mock, detector: ForcedBugDetector(bugPresent: false))

        let (success, error) = workaround.setJetsamLimit(pid: 0, limitMB: 100)
        XCTAssertFalse(success)
        XCTAssertEqual(error, "invalid_pid")
        XCTAssertTrue(mock.calls.isEmpty, "Should not call memorystatus_control for invalid PID")
    }

    func testRejectsNegativePID() {
        let mock = MockMemorystatusProvider()
        let workaround = MemlimitWorkaround(provider: mock, detector: ForcedBugDetector(bugPresent: false))

        let (success, error) = workaround.setJetsamLimit(pid: -1, limitMB: 100)
        XCTAssertFalse(success)
        XCTAssertEqual(error, "invalid_pid")
    }

    func testRejectsZeroLimit() {
        let mock = MockMemorystatusProvider()
        let workaround = MemlimitWorkaround(provider: mock, detector: ForcedBugDetector(bugPresent: false))

        let (success, error) = workaround.setJetsamLimit(pid: 1, limitMB: 0)
        XCTAssertFalse(success)
        XCTAssertEqual(error, "invalid_limit")
    }

    func testRejectsNegativeLimit() {
        let mock = MockMemorystatusProvider()
        let workaround = MemlimitWorkaround(provider: mock, detector: ForcedBugDetector(bugPresent: false))

        let (success, error) = workaround.setJetsamLimit(pid: 1, limitMB: -5)
        XCTAssertFalse(success)
        XCTAssertEqual(error, "invalid_limit")
    }

    // MARK: - HWM path (no bug)

    func testHWMPathUsedWhenNoBug() {
        let mock = MockMemorystatusProvider()
        let workaround = MemlimitWorkaround(provider: mock, detector: ForcedBugDetector(bugPresent: false))

        let (success, _) = workaround.setJetsamLimit(pid: 42, limitMB: 256)
        XCTAssertTrue(success)
        XCTAssertEqual(mock.calls.count, 1)

        let call = mock.calls[0]
        // MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK = 5
        XCTAssertEqual(call.command, 5)
        XCTAssertEqual(call.pid, 42)
        XCTAssertEqual(call.flags, 256)
        XCTAssertEqual(call.bufferSize, 0)
        XCTAssertNil(call.buffer, "HWM path should not pass a buffer")
    }

    func testHWMPathReportsFailure() {
        let mock = MockMemorystatusProvider()
        mock.returnValue = -1
        mock.errnoToSet = 22  // EINVAL
        let workaround = MemlimitWorkaround(provider: mock, detector: ForcedBugDetector(bugPresent: false))

        let (success, error) = workaround.setJetsamLimit(pid: 42, limitMB: 256)
        XCTAssertFalse(success)
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("hwm_failed"))
    }

    // MARK: - Properties path (128GB bug workaround)

    func testPropertiesPathUsedWhenBugDetected() {
        let mock = MockMemorystatusProvider()
        let workaround = MemlimitWorkaround(provider: mock, detector: ForcedBugDetector(bugPresent: true))

        let (success, _) = workaround.setJetsamLimit(pid: 99, limitMB: 512)
        XCTAssertTrue(success)
        XCTAssertEqual(mock.calls.count, 1)

        let call = mock.calls[0]
        // MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES = 2
        XCTAssertEqual(call.command, 2, "Should use SET_PRIORITY_PROPERTIES command")
        XCTAssertEqual(call.pid, 99)
        XCTAssertEqual(call.flags, 0, "Properties path should pass 0 flags")

        let entrySize = MemoryLayout<memorystatus_priority_entry_t>.size
        XCTAssertEqual(call.bufferSize, entrySize)

        guard let bufferData = call.buffer else {
            XCTFail("Properties path should pass a buffer")
            return
        }
        XCTAssertEqual(bufferData.count, entrySize)

        let entry = bufferData.withUnsafeBytes { $0.load(as: memorystatus_priority_entry_t.self) }
        XCTAssertEqual(entry.pid, 99, "Struct should contain target PID")
        XCTAssertEqual(entry.priority, -1, "Priority should be -1 (no change)")
        XCTAssertEqual(entry.limit, 512, "Struct should contain the requested limit in MB")
        XCTAssertEqual(entry.user_data, 0)
        XCTAssertEqual(entry.state, 0)
    }

    func testPropertiesPathReportsFailure() {
        let mock = MockMemorystatusProvider()
        mock.returnValue = -1
        mock.errnoToSet = 1  // EPERM
        let workaround = MemlimitWorkaround(provider: mock, detector: ForcedBugDetector(bugPresent: true))

        let (success, error) = workaround.setJetsamLimit(pid: 99, limitMB: 512)
        XCTAssertFalse(success)
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("properties_failed"))
    }

    // MARK: - Bug detection (KernelProbeBugDetector via MockSystemInfo)

    func testDetectBugReturnsFalseOnLessThan128GB() {
        // 64 GB machine — bug impossible regardless of kernel behavior.
        let sysInfo = MockSystemInfo(ramBytes: 64 * 1024 * 1024 * 1024, probeResult: 0, probeErrno: 0)
        let detector = KernelProbeBugDetector(systemInfo: sysInfo)
        XCTAssertFalse(detector.detectBug(), "Should return false on < 128 GB machine")
    }

    func testDetectBugReturnsFalseWhenSysctlFails() {
        // hw.memsize unavailable.
        let sysInfo = MockSystemInfo(ramBytes: nil, probeResult: 0, probeErrno: 0)
        let detector = KernelProbeBugDetector(systemInfo: sysInfo)
        XCTAssertFalse(detector.detectBug(), "Should return false when sysctl fails")
    }

    func testDetectBugReturnsFalseOnPatchedKernel128GB() {
        // 128 GB machine, probe succeeds (kernel is patched).
        let sysInfo = MockSystemInfo(ramBytes: 128 * 1024 * 1024 * 1024, probeResult: 0, probeErrno: 0)
        let detector = KernelProbeBugDetector(systemInfo: sysInfo)
        XCTAssertFalse(detector.detectBug(), "Should return false on 128 GB+ with patched kernel")
    }

    func testDetectBugReturnsTrueOnEINVAL() {
        // 128 GB machine, probe returns EINVAL (overflow confirmed).
        let sysInfo = MockSystemInfo(ramBytes: 128 * 1024 * 1024 * 1024, probeResult: -1, probeErrno: EINVAL)
        let detector = KernelProbeBugDetector(systemInfo: sysInfo)
        XCTAssertTrue(detector.detectBug(), "Should return true when kernel probe returns EINVAL")
    }

    func testDetectBugReturnsTrueOnInconclusiveError() {
        // 128 GB machine, probe returns EPERM (can't probe, conservative fallback).
        let sysInfo = MockSystemInfo(ramBytes: 128 * 1024 * 1024 * 1024, probeResult: -1, probeErrno: EPERM)
        let detector = KernelProbeBugDetector(systemInfo: sysInfo)
        XCTAssertTrue(detector.detectBug(), "Should conservatively return true on inconclusive error")
    }

    func testDetectBugReturnsFalseOnPatchedKernel192GB() {
        // 192 GB machine, probe succeeds.
        let sysInfo = MockSystemInfo(ramBytes: 192 * 1024 * 1024 * 1024, probeResult: 0, probeErrno: 0)
        let detector = KernelProbeBugDetector(systemInfo: sysInfo)
        XCTAssertFalse(detector.detectBug(), "Should return false on 192 GB+ with patched kernel")
    }

    // MARK: - Path routing with forced detector

    func testForcedBugDetectorDrivesBothPaths() {
        let mock = MockMemorystatusProvider()

        // Force no bug → HWM path
        let noBug = MemlimitWorkaround(provider: mock, detector: ForcedBugDetector(bugPresent: false))
        _ = noBug.setJetsamLimit(pid: 1, limitMB: 100)
        XCTAssertEqual(mock.calls.count, 1)
        XCTAssertEqual(mock.calls[0].command, 5, "No-bug path should use HWM command")

        mock.calls.removeAll()

        // Force bug → Properties path
        let hasBug = MemlimitWorkaround(provider: mock, detector: ForcedBugDetector(bugPresent: true))
        _ = hasBug.setJetsamLimit(pid: 1, limitMB: 100)
        XCTAssertEqual(mock.calls.count, 1)
        XCTAssertEqual(mock.calls[0].command, 2, "Bug path should use SET_PRIORITY_PROPERTIES command")
    }

    // MARK: - Struct layout

    func testPriorityEntryStructSize() {
        let entrySize = MemoryLayout<memorystatus_priority_entry_t>.size
        // XNU struct: pid(4) + priority(4) + user_data(8) + limit(4) + state(4) = 24
        XCTAssertEqual(entrySize, 24,
                       "memorystatus_priority_entry_t should be 24 bytes")
    }

    // MARK: - Valid PID passthrough

    func testValidPIDPassedThrough() {
        let mock = MockMemorystatusProvider()
        let workaround = MemlimitWorkaround(provider: mock, detector: ForcedBugDetector(bugPresent: false))

        let (success, _) = workaround.setJetsamLimit(pid: 1, limitMB: 512)
        XCTAssertTrue(success)
        XCTAssertEqual(mock.calls.count, 1)
    }
}
