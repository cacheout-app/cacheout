// MemlimitWorkaround.swift
// 128GB memlimit bug detection and workaround logic.
//
// On machines with >= 128 GB physical RAM, the XNU kernel's internal conversion
// from MB to bytes can overflow a 32-bit intermediate, causing
// MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK to fail with EINVAL for large
// limit values. The workaround uses MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES
// which sets the limit via a struct-based path that avoids the overflow.
//
// This module lives in CacheoutHelperLib (not CacheoutHelper) so it can be
// tested from CacheoutHelperTests without importing the executable target.

import Darwin
import CKernelPrivate

// MARK: - MemorystatusControl Protocol

/// Injectable wrapper around the `memorystatus_control` syscall for test-time mocking.
public protocol MemorystatusControlProvider {
    /// Calls `memorystatus_control` with the given parameters.
    /// Returns the raw return value (0 on success, -1 on failure with errno set).
    func control(command: UInt32, pid: Int32, flags: UInt32,
                 buffer: UnsafeMutableRawPointer?, bufferSize: Int) -> Int32
}

/// Real implementation that calls the kernel `memorystatus_control` syscall.
public struct SystemMemorystatusProvider: MemorystatusControlProvider {
    public init() {}

    public func control(command: UInt32, pid: Int32, flags: UInt32,
                        buffer: UnsafeMutableRawPointer?, bufferSize: Int) -> Int32 {
        memorystatus_control(command, pid, flags, buffer, bufferSize)
    }
}

// MARK: - Bug Detection Protocol

/// Injectable bug detection for test-time control of which kernel path is exercised.
public protocol MemlimitBugDetector {
    /// Returns `true` if the 128GB memlimit conversion bug is present.
    func detectBug() -> Bool
}

// MARK: - System Info Protocol

/// Injectable system-info provider for testing the bug detector without live hardware.
public protocol SystemInfoProvider {
    /// Returns the physical RAM in bytes (mirrors `hw.memsize`).
    func physicalMemoryBytes() -> UInt64?

    /// Calls `memorystatus_control` for the probe. Isolated so tests can
    /// simulate kernel responses without touching real kernel state.
    func probeMemlimitConversion(limitMB: UInt32) -> (result: Int32, errno: Int32)
}

/// Real implementation backed by sysctl and the read-only
/// `MEMORYSTATUS_CMD_CONVERT_MEMLIMIT_MB` kernel command.
public struct RealSystemInfoProvider: SystemInfoProvider {
    public init() {}

    public func physicalMemoryBytes() -> UInt64? {
        var memsize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        let rc = sysctlbyname("hw.memsize", &memsize, &size, nil, 0)
        return rc == 0 ? memsize : nil
    }

    public func probeMemlimitConversion(limitMB: UInt32) -> (result: Int32, errno: Int32) {
        // MEMORYSTATUS_CMD_CONVERT_MEMLIMIT_MB is a read-only conversion check.
        // It asks the kernel to convert an MB value through the same code path
        // used by SET_JETSAM_HIGH_WATER_MARK without mutating any process state.
        // Returns 0 on success, -1 with EINVAL if the conversion overflows.
        let cmd = UInt32(MEMORYSTATUS_CMD_CONVERT_MEMLIMIT_MB)
        let result = memorystatus_control(cmd, 0, limitMB, nil, 0)
        return (result, result != 0 ? errno : 0)
    }
}

/// Default detector that probes actual kernel behavior on the current system.
///
/// Detection strategy:
/// 1. Check `hw.memsize` — if < 128 GB, the bug cannot occur (early exit).
/// 2. On 128 GB+ machines, call the read-only `MEMORYSTATUS_CMD_CONVERT_MEMLIMIT_MB`
///    to test whether the kernel's MB-to-bytes conversion overflows. This command
///    does not mutate any process's jetsam state.
///    - Returns 0 → conversion succeeds → kernel is patched → no bug.
///    - Returns EINVAL → overflow confirmed → bug present.
///    - Other errors → inconclusive → conservatively assume bug on 128 GB+.
///
/// All system calls are routed through `SystemInfoProvider` for test-time injection.
public struct KernelProbeBugDetector: MemlimitBugDetector {
    private let systemInfo: SystemInfoProvider

    public init(systemInfo: SystemInfoProvider = RealSystemInfoProvider()) {
        self.systemInfo = systemInfo
    }

    public func detectBug() -> Bool {
        // Step 1: RAM gate — bug only possible on 128 GB+ machines.
        guard let memsize = systemInfo.physicalMemoryBytes() else { return false }
        let gb = memsize / (1024 * 1024 * 1024)
        guard gb >= 128 else { return false }

        // Step 2: Read-only kernel probe with a test value.
        // Use a large-ish MB value (4096 = 4 GB) that would trigger the overflow
        // on affected kernels but is still a reasonable limit value.
        let probe = systemInfo.probeMemlimitConversion(limitMB: 4096)

        if probe.result == 0 {
            // Conversion succeeded — kernel does not have the overflow bug.
            return false
        } else if probe.errno == EINVAL {
            // EINVAL is the overflow signature — bug confirmed.
            return true
        } else {
            // Other errors — can't conclusively probe. Conservatively assume
            // the bug exists on 128 GB+ hardware.
            return true
        }
    }
}

// MARK: - Memlimit Workaround

/// Detects and works around the 128GB memlimit conversion bug.
///
/// The bug manifests when:
/// 1. Physical RAM >= 128 GB
/// 2. The kernel's MB-to-bytes conversion overflows a uint32_t intermediate
///
/// Detection uses a read-only kernel probe: on 128 GB+ machines, the default
/// detector calls `MEMORYSTATUS_CMD_CONVERT_MEMLIMIT_MB` to check whether the
/// kernel's conversion overflows. This does not mutate any process state. The
/// detector is injectable via `MemlimitBugDetector` for test-time control.
public struct MemlimitWorkaround {

    private let provider: MemorystatusControlProvider
    private let detector: MemlimitBugDetector

    public init(provider: MemorystatusControlProvider = SystemMemorystatusProvider(),
                detector: MemlimitBugDetector = KernelProbeBugDetector()) {
        self.provider = provider
        self.detector = detector
    }

    /// Detect whether the 128GB memlimit conversion bug is present.
    /// Delegates to the injected `MemlimitBugDetector`.
    public func detectBug() -> Bool {
        detector.detectBug()
    }

    /// Set a jetsam limit using the appropriate path based on bug detection.
    ///
    /// - Parameters:
    ///   - pid: Target process ID.
    ///   - limitMB: Desired jetsam high-water mark in megabytes.
    /// - Returns: A tuple of (success, errorMessage).
    public func setJetsamLimit(pid: pid_t, limitMB: Int32) -> (Bool, String?) {
        guard pid > 0 else { return (false, "invalid_pid") }
        guard limitMB > 0 else { return (false, "invalid_limit") }

        if detectBug() {
            return setViaProperties(pid: pid, limitMB: limitMB)
        } else {
            return setViaHWM(pid: pid, limitMB: limitMB)
        }
    }

    // MARK: - Standard Path (no bug)

    /// Set jetsam limit via MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK.
    /// This is the standard path used on machines with < 128 GB RAM.
    private func setViaHWM(pid: pid_t, limitMB: Int32) -> (Bool, String?) {
        let cmd = UInt32(MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK)
        let result = provider.control(
            command: cmd,
            pid: pid,
            flags: UInt32(bitPattern: limitMB),
            buffer: nil,
            bufferSize: 0
        )

        if result == 0 {
            return (true, nil)
        } else {
            let err = errno
            return (false, "memorystatus_control_hwm_failed: errno \(err)")
        }
    }

    // MARK: - Workaround Path (128GB bug)

    /// Set jetsam limit via MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES.
    /// This path passes the limit inside a memorystatus_priority_entry struct,
    /// avoiding the uint32_t overflow in the flags-based HWM path.
    private func setViaProperties(pid: pid_t, limitMB: Int32) -> (Bool, String?) {
        let cmd = UInt32(MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES)

        // Build the priority entry struct with the target limit.
        // We set priority to -1 (no change) and limit to the desired value.
        // The kernel respects the limit field in SET_PRIORITY_PROPERTIES.
        var entry = memorystatus_priority_entry_t()
        entry.pid = pid
        entry.priority = -1  // -1 means "do not change priority"
        entry.limit = limitMB
        entry.user_data = 0
        entry.state = 0

        let entrySize = MemoryLayout<memorystatus_priority_entry_t>.size
        let result = withUnsafeMutableBytes(of: &entry) { buffer in
            provider.control(
                command: cmd,
                pid: pid,
                flags: 0,
                buffer: buffer.baseAddress,
                bufferSize: entrySize
            )
        }

        if result == 0 {
            return (true, nil)
        } else {
            let err = errno
            return (false, "memorystatus_control_properties_failed: errno \(err)")
        }
    }
}
