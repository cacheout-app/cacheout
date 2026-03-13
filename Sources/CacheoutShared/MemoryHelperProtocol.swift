// MemoryHelperProtocol.swift
// XPC protocol for communication between Cacheout app and CacheoutHelper daemon.
// All methods use completion-handler signatures compatible with NSXPCConnection.

import Foundation

// MARK: - XPC Protocol

/// The XPC protocol exposed by the privileged CacheoutHelper daemon.
///
/// ## Reply patterns
///
/// **Data-bearing read endpoints** use `reply: @escaping (Data) -> Void` where the `Data`
/// payload contains UTF-8 JSON-encoded DTOs. An empty `Data()` signals an error.
///
/// **Control/intervention endpoints** use typed primitive replies
/// (`(Bool)`, `(Bool, String?)`, `(Bool, UInt64)`, `(UInt64)`, `(String)`)
/// for simple success/error signals.
///
/// ## Privilege requirements
///
/// All methods execute inside the privileged helper (root). The helper validates
/// the caller's code-signing identity before accepting the XPC connection.
///
/// Methods marked "requires root" need root-level kernel APIs (memorystatus_control,
/// sysctl writes, etc.). Methods marked "user-level readable" could theoretically
/// run unprivileged but are routed through the helper for consistency and to avoid
/// duplicating collection logic.
///
@objc public protocol MemoryHelperProtocol: NSObjectProtocol {

    // MARK: - Data-bearing read endpoints (reply: Data)
    // These return JSON-encoded DTOs. Empty Data() on error.

    /// Fetch current system memory statistics.
    /// - Decodes to: `SystemStatsDTO`
    /// - Privilege: user-level readable (vm_statistics64, sysctl reads)
    func getSystemStats(reply: @escaping (Data) -> Void)

    /// Fetch the list of all running processes with memory metrics.
    /// - Decodes to: `[ProcessEntryDTO]`
    /// - Privilege: requires root (proc_pid_rusage on arbitrary PIDs)
    func getProcessList(reply: @escaping (Data) -> Void)

    /// Fetch the kernel jetsam snapshot (recently killed or at-risk processes).
    /// - Decodes to: `[JetsamSnapshotEntryDTO]`
    /// - Privilege: requires root (memorystatus_control MEMORYSTATUS_CMD_GET_JETSAM_SNAPSHOT)
    func getJetsamSnapshot(reply: @escaping (Data) -> Void)

    /// Fetch the jetsam priority list (all processes with their jetsam priority/limit).
    /// - Decodes to: `[JetsamPriorityEntryDTO]`
    /// - Privilege: requires root (memorystatus_control MEMORYSTATUS_CMD_GET_PRIORITY_LIST)
    func getJetsamPriorityList(reply: @escaping (Data) -> Void)

    /// Fetch kernel zone health information for zones above 50% utilization.
    /// - Decodes to: `[ZoneHealthDTO]`
    /// - Privilege: requires root (host_zone_info)
    func getKernelZoneHealth(reply: @escaping (Data) -> Void)

    /// Fetch the list of Rosetta-translated (x86_64) processes.
    /// - Decodes to: `[ProcessEntryDTO]`
    /// - Privilege: requires root (proc_pidinfo on arbitrary PIDs)
    func getRosettaProcesses(reply: @escaping (Data) -> Void)

    // MARK: - Control/intervention endpoints (typed replies)

    /// Set the jetsam memory limit for a specific process.
    ///
    /// The helper auto-selects the kernel path based on memlimit-bug detection:
    /// - Normal path: `MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK` (< 128 GB or patched kernel)
    /// - Workaround path: `MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES` (128 GB+ with overflow bug)
    ///
    /// - Parameters:
    ///   - pid: Target process ID.
    ///   - limitMB: New jetsam high-water mark in megabytes.
    ///   - reply: `(success, errorMessage)`.
    /// - Privilege: requires root (memorystatus_control)
    func setJetsamLimit(pid: pid_t, limitMB: Int32,
                        reply: @escaping (Bool, String?) -> Void)

    /// Trigger a manual memory purge at the given level.
    /// - Parameters:
    ///   - level: Purge level passed to `kern.memorypressure_manual_trigger`.
    ///   - reply: `true` if the sysctl call succeeded.
    /// - Privilege: requires root (sysctl write)
    func triggerPurge(level: Int32, reply: @escaping (Bool) -> Void)

    /// Read the current Reduce Transparency setting for the console user.
    /// - Parameter reply: `(success, enabled, errorMessage)`.
    ///   - `(true, currentValue, nil)` — read succeeded.
    ///   - `(false, false, "no_console_user")` — no console user logged in.
    ///   - `(false, false, "defaults_read_failed: ...")` — defaults read error.
    /// - Privilege: requires root (reads console user's defaults domain)
    func getReduceTransparencyState(reply: @escaping (Bool, Bool, String?) -> Void)

    /// Enable or disable the Reduce Transparency accessibility setting.
    /// - Parameters:
    ///   - enabled: Whether to enable reduce transparency.
    ///   - reply: `true` if the defaults write succeeded.
    /// - Privilege: requires root (defaults write to console user domain)
    func setReduceTransparency(_ enabled: Bool, reply: @escaping (Bool) -> Void)

    /// Delete an APFS snapshot by UUID.
    /// - Parameters:
    ///   - uuid: The snapshot UUID (validated against UUID format).
    ///   - reply: `(success, outputOrError)`.
    /// - Privilege: requires root (diskutil apfs deleteSnapshot)
    func deleteAPFSSnapshot(uuid: String, reply: @escaping (Bool, String?) -> Void)

    /// Get the size of the sleep image file.
    /// - Parameter reply: `(success, exists, sizeBytes, errorMessage)`.
    ///   - `(true, true, size, nil)` — file exists with known size.
    ///   - `(true, false, 0, nil)` — file absent (normal on some configs).
    ///   - `(false, false, 0, "stat_failed: ...")` — stat error.
    /// - Privilege: requires root (`/private/var/vm/sleepimage` owned by root)
    func getSleepImageSize(reply: @escaping (Bool, Bool, UInt64, String?) -> Void)

    /// Delete the sleep image file to reclaim disk space.
    /// - Parameter reply: `(success, bytesReclaimed)`.
    /// - Privilege: requires root (file deletion in /private/var/vm/)
    func deleteSleepImage(reply: @escaping (Bool, UInt64) -> Void)

    /// Flush WindowServer caches by toggling display mode.
    /// - Parameter reply: Estimated bytes reclaimed from WindowServer footprint reduction.
    /// - Privilege: requires root (CGDisplay configuration)
    func flushWindowServerCaches(reply: @escaping (UInt64) -> Void)

    /// Set a kernel sysctl value (restricted to an allowlist).
    /// - Parameters:
    ///   - name: The sysctl name (must be in the helper's allowlist).
    ///   - value: The new Int32 value.
    ///   - reply: `(success, errorMessage)`.
    /// - Privilege: requires root (sysctl write)
    func setSysctlValue(name: String, value: Int32,
                        reply: @escaping (Bool, String?) -> Void)

    // MARK: - Diagnostic endpoints

    /// Detect the memlimit conversion bug via read-only kernel probe on 128 GB+ machines.
    /// Uses `MEMORYSTATUS_CMD_CONVERT_MEMLIMIT_MB` (no state mutation) to check
    /// whether the kernel's MB-to-bytes conversion overflows.
    /// Returns `true` if the kernel returns EINVAL (overflow confirmed) or if
    /// the probe cannot run on 128 GB+ hardware (conservative fallback).
    /// Returns `false` on < 128 GB machines (bug impossible) or if the probe
    /// succeeds (kernel patched).
    /// - Parameter reply: `true` if the bug is detected or conservatively assumed.
    /// - Privilege: requires root (memorystatus_control)
    func detectMemlimitBug(reply: @escaping (Bool) -> Void)

    /// Get the hardware-based memory tier classification.
    /// - Parameter reply: Tier string (e.g. "constrained", "moderate", "comfortable", "abundant", "extreme").
    /// - Privilege: user-level readable (hw.memsize sysctl)
    func getMemoryTier(reply: @escaping (String) -> Void)
}
