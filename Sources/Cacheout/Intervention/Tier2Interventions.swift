// Tier2Interventions.swift
// Tier 2 (confirm required) interventions: JetsamHWM, WindowServerFlush,
// CompressorTuning, and SnapshotCleanup.

import Foundation
import CacheoutShared
import AppKit
import CoreGraphics
import Darwin

// MARK: - XPC Helpers (shared with Tier1)

/// Default XPC call timeout in seconds.
/// Kept low enough that even 3 serial calls fit within the 25s intervention budget.
private let xpcTimeoutSeconds: UInt64 = 8

/// Result of an XPC call: either a value or an error message.
private enum XPCResult<T> {
    case value(T)
    case failed(String)
}

/// Thread-safe once-box for resuming a continuation exactly once.
/// Uses an unfair lock for minimal overhead in the XPC callback path.
private final class OnceResumer<T>: @unchecked Sendable {
    private var resumed = false
    private let lock = os_unfair_lock_t.allocate(capacity: 1)
    private let continuation: CheckedContinuation<XPCResult<T>, Never>

    init(_ continuation: CheckedContinuation<XPCResult<T>, Never>) {
        self.continuation = continuation
        lock.initialize(to: os_unfair_lock())
    }

    deinit { lock.deallocate() }

    func resume(with result: XPCResult<T>) {
        os_unfair_lock_lock(lock)
        let shouldResume = !resumed
        if shouldResume { resumed = true }
        os_unfair_lock_unlock(lock)
        if shouldResume {
            continuation.resume(returning: result)
        }
    }
}

/// Thread-safe once-box for resuming a throwing continuation exactly once.
private final class ThrowingOnceResumer<T>: @unchecked Sendable {
    private var resumed = false
    private let lock = os_unfair_lock_t.allocate(capacity: 1)
    private let continuation: CheckedContinuation<T, any Error>

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = continuation
        lock.initialize(to: os_unfair_lock())
    }

    deinit { lock.deallocate() }

    func resume(with result: Result<T, any Error>) {
        os_unfair_lock_lock(lock)
        let shouldResume = !resumed
        if shouldResume { resumed = true }
        os_unfair_lock_unlock(lock)
        if shouldResume {
            continuation.resume(with: result)
        }
    }
}

/// Thread-safe atomic boolean flag for signaling timeout between closures.
private final class AtomicFlag: @unchecked Sendable {
    private var _value = false
    private let lock = os_unfair_lock_t.allocate(capacity: 1)

    init() { lock.initialize(to: os_unfair_lock()) }
    deinit { lock.deallocate() }

    var value: Bool {
        os_unfair_lock_lock(lock)
        let v = _value
        os_unfair_lock_unlock(lock)
        return v
    }

    func set() {
        os_unfair_lock_lock(lock)
        _value = true
        os_unfair_lock_unlock(lock)
    }
}

/// Perform an XPC call with a timeout, handling both the XPC error handler
/// and the reply callback. Returns the result or an error message.
private func xpcCall<T>(
    connection: NSXPCConnection,
    timeout: UInt64 = xpcTimeoutSeconds,
    body: @escaping (@escaping (T) -> Void, MemoryHelperProtocol) -> Void
) async -> XPCResult<T> {
    await withCheckedContinuation { (continuation: CheckedContinuation<XPCResult<T>, Never>) in
        let resumer = OnceResumer(continuation)

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            resumer.resume(with: .failed("xpc_error: \(error.localizedDescription)"))
        } as! MemoryHelperProtocol

        // Timeout
        Task {
            try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
            resumer.resume(with: .failed("xpc_timeout"))
        }

        body({ result in
            resumer.resume(with: .value(result))
        }, proxy)
    }
}

// MARK: - Jetsam High-Water Mark

/// Adjusts jetsam high-water marks for memory-heavy processes to trigger earlier
/// jetsam kills, reclaiming 500 MB - 2 GB.
///
/// Tier 2 (confirm): process may be killed if it exceeds the lowered limit.
///
/// Candidate selection:
/// 1. Fetch process list (memory) and jetsam priority list (priority data) via XPC
/// 2. Join on PID to get both memory footprint and jetsam priority
/// 3. Filter: jetsamPriority >= 0
/// 4. Denylist: foreground apps, system daemons (priority > JETSAM_PRIORITY_DEFAULT=10)
/// 5. Limit formula: max(currentFootprint * 0.75, 50 MB)
/// 6. Select top N by physFootprint (default 3)
public final class JetsamHWM: Intervention {
    public let name = "jetsam_hwm"
    public let tier: InterventionTier = .confirm

    /// Maximum number of processes to target.
    private let maxTargets: Int

    /// Optional explicit target PID (CLI override). Still denylist-checked.
    private let targetPID: pid_t?

    /// Jetsam priority threshold for system daemons (above this = denylist).
    private static let systemDaemonPriorityThreshold: Int32 = 10

    /// Minimum jetsam limit in MB.
    private static let minimumLimitMB: Int32 = 50

    /// Hardcoded critical process names that must never be targeted.
    private static let criticalProcesses: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow",
        "opendirectoryd", "securityd", "trustd", "diskarbitrationd",
        "coreaudiod", "hidd", "logd", "powerd", "configd",
        "UserEventAgent", "mds", "mds_stores", "fseventsd"
    ]

    public init(maxTargets: Int = 3, targetPID: pid_t? = nil) {
        self.maxTargets = maxTargets
        self.targetPID = targetPID
    }

    public func isApplicable(snapshot: MemorySnapshot) -> Bool {
        true
    }

    /// End-to-end budget for the entire intervention, in seconds.
    /// Must fit within the protocol's 30s subprocess timeout with margin.
    private static let totalBudgetSeconds: Double = 22.0

    public func execute(via executor: InterventionExecutor) async -> ExecutionResult {
        guard executor.confirmed || executor.dryRun else {
            return ExecutionResult(outcome: .error(message: "confirmation_required"))
        }

        guard let connection = executor.xpcConnection else {
            return ExecutionResult(outcome: .error(message: "xpc_not_available"))
        }

        let deadline = CFAbsoluteTimeGetCurrent() + Self.totalBudgetSeconds

        // Step 1: Fetch process list (always executes, even in dry-run).
        let processResult = await xpcCall(connection: connection) { (reply: @escaping (Data) -> Void, proxy) in
            proxy.getProcessList(reply: reply)
        }

        let processes: [ProcessEntryDTO]
        switch processResult {
        case .value(let data):
            guard !data.isEmpty else {
                return ExecutionResult(outcome: .error(message: "process_list_empty"))
            }
            do {
                processes = try JSONDecoder().decode([ProcessEntryDTO].self, from: data)
            } catch {
                return ExecutionResult(outcome: .error(message: "process_list_decode_failed"))
            }
        case .failed(let error):
            return ExecutionResult(outcome: .error(message: error))
        }

        // Budget check before second discovery call.
        guard CFAbsoluteTimeGetCurrent() + Double(xpcTimeoutSeconds) < deadline else {
            return ExecutionResult(outcome: .error(message: "budget_exhausted_after_process_list"))
        }

        // Step 2: Fetch jetsam priority list (always executes, even in dry-run).
        let priorityResult = await xpcCall(connection: connection) { (reply: @escaping (Data) -> Void, proxy) in
            proxy.getJetsamPriorityList(reply: reply)
        }

        let priorities: [JetsamPriorityEntryDTO]
        switch priorityResult {
        case .value(let data):
            // Empty Data() from the helper signals a kernel/XPC failure, not "no entries".
            guard !data.isEmpty else {
                return ExecutionResult(outcome: .error(message: "priority_list_fetch_failed"))
            }
            do {
                priorities = try JSONDecoder().decode([JetsamPriorityEntryDTO].self, from: data)
            } catch {
                return ExecutionResult(outcome: .error(message: "priority_list_decode_failed"))
            }
        case .failed(let error):
            return ExecutionResult(outcome: .error(message: error))
        }

        // Step 3: Build priority lookup by PID (keep first entry per PID to avoid trap on duplicates).
        var priorityByPID: [pid_t: JetsamPriorityEntryDTO] = [:]
        for entry in priorities {
            if priorityByPID[entry.pid] == nil {
                priorityByPID[entry.pid] = entry
            }
        }

        // Step 4: Get foreground (active) app PIDs for denylist.
        // Only exclude truly active/frontmost apps, not all GUI apps.
        // ⚡ Bolt: Use .lazy for Set initialization
        // Impact: Avoids intermediate array allocations during filter/map chain,
        // reducing memory overhead and improving CPU cache locality.
        let foregroundPIDs = await MainActor.run {
            Set(NSWorkspace.shared.runningApplications.lazy
                .filter { $0.isActive }
                .map { $0.processIdentifier })
        }

        // Step 5: Select candidates.
        struct JetsamCandidate {
            let pid: pid_t
            let name: String
            let physFootprint: UInt64
            let jetsamPriority: Int32
            let proposedLimitMB: Int32
        }

        var candidates: [JetsamCandidate] = []

        for proc in processes {
            // Join with priority data.
            guard let priority = priorityByPID[proc.pid] else { continue }

            // Filter: priority >= 0
            guard priority.priority >= 0 else { continue }

            // Denylist: foreground apps
            guard !foregroundPIDs.contains(proc.pid) else { continue }

            // Denylist: system daemons (priority > threshold)
            guard priority.priority <= Self.systemDaemonPriorityThreshold else { continue }

            // Denylist: critical processes
            guard !Self.criticalProcesses.contains(proc.name) else { continue }

            // Denylist: known AI agent processes
            guard !AgentDetector.isAgent(proc) else { continue }

            // If explicit target PID, only consider that PID.
            if let targetPID, proc.pid != targetPID { continue }

            // Compute limit: max(footprint * 0.75, 50 MB)
            let footprintMB = Int32(proc.physFootprint / (1024 * 1024))
            let computedLimit = Int32(Double(footprintMB) * 0.75)
            var proposedLimit = max(computedLimit, Self.minimumLimitMB)

            // If the process already has a positive limit that is lower than
            // our proposed limit, skip it — we would raise the HWM, which is
            // the opposite of the intervention's intent.
            if priority.limit > 0 && priority.limit <= proposedLimit {
                continue
            }
            // If the process has a positive limit higher than proposed, clamp
            // to at most the existing limit so we only lower, never raise.
            if priority.limit > 0 {
                proposedLimit = min(proposedLimit, priority.limit)
            }

            candidates.append(JetsamCandidate(
                pid: proc.pid,
                name: proc.name,
                physFootprint: proc.physFootprint,
                jetsamPriority: priority.priority,
                proposedLimitMB: proposedLimit
            ))
        }

        // Sort by physFootprint descending, take top N.
        candidates.sort { $0.physFootprint > $1.physFootprint }
        let selected = Array(candidates.prefix(maxTargets))

        // Build metadata using proper JSON encoding.
        struct TargetInfo: Codable {
            let pid: pid_t
            let name: String
            let footprint_mb: UInt64
            let limit_mb: Int32
        }

        var meta: [String: String] = [:]
        let targetInfos = selected.map {
            TargetInfo(pid: $0.pid, name: $0.name,
                       footprint_mb: $0.physFootprint / (1024 * 1024),
                       limit_mb: $0.proposedLimitMB)
        }
        if let jsonData = try? JSONEncoder().encode(targetInfos),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            meta["targets"] = jsonStr
        }
        meta["candidate_count"] = String(candidates.count)

        if selected.isEmpty {
            return ExecutionResult(outcome: .skipped(reason: "no_eligible_targets"), metadata: meta)
        }

        // Dry-run: report candidates but do NOT set limits.
        if executor.dryRun {
            let estimateMB = selected.reduce(0) { sum, c in
                sum + Int(Double(c.physFootprint / (1024 * 1024)) * 0.25)
            }
            meta["estimate_mb"] = String(estimateMB)
            return ExecutionResult(outcome: .success(reclaimedMB: nil), metadata: meta)
        }

        // Step 6: Apply jetsam limits with budget checking.
        var applied = 0
        var errors: [String] = []
        var budgetExhausted = false

        for candidate in selected {
            // Check remaining budget before issuing another XPC call.
            let timeLeft = deadline - CFAbsoluteTimeGetCurrent()
            if timeLeft < Double(xpcTimeoutSeconds) {
                budgetExhausted = true
                break
            }

            let setResult = await xpcCall(connection: connection) {
                (reply: @escaping ((Bool, String?)) -> Void, proxy) in
                proxy.setJetsamLimit(pid: candidate.pid, limitMB: candidate.proposedLimitMB) { success, errorMsg in
                    reply((success, errorMsg))
                }
            }

            switch setResult {
            case .value(let (success, errorMsg)):
                if success {
                    applied += 1
                } else {
                    errors.append("\(candidate.pid):\(errorMsg ?? "unknown")")
                }
            case .failed(let error):
                errors.append("\(candidate.pid):\(error)")
            }
        }

        if !errors.isEmpty {
            meta["errors"] = errors.joined(separator: "; ")
        }
        meta["applied_count"] = String(applied)
        if budgetExhausted {
            meta["budget_exhausted"] = "true"
        }

        if applied == 0 && !budgetExhausted {
            return ExecutionResult(outcome: .error(message: "all_set_jetsam_failed"), metadata: meta)
        }

        return ExecutionResult(outcome: .success(reclaimedMB: nil), metadata: meta)
    }
}

// MARK: - WindowServer Cache Flush

/// Flushes WindowServer caches by toggling the display mode in the app process.
///
/// Tier 2 (confirm): screen flickers briefly during the toggle.
///
/// Runs app-side (requires GUI/Aqua session). Skipped if headless.
/// The helper's `flushWindowServerCaches()` stub is NOT used.
public final class WindowServerFlush: Intervention {
    public let name = "windowserver_flush"
    public let tier: InterventionTier = .confirm

    public init() {}

    public func isApplicable(snapshot: MemorySnapshot) -> Bool {
        true
    }

    public func execute(via executor: InterventionExecutor) async -> ExecutionResult {
        guard executor.confirmed || executor.dryRun else {
            return ExecutionResult(outcome: .error(message: "confirmation_required"))
        }

        // Headless detection: skip if no display available.
        let displayID = CGMainDisplayID()
        guard displayID != kCGNullDirectDisplay else {
            return ExecutionResult(
                outcome: .skipped(reason: "no_display"),
                metadata: ["reason": "headless_environment"]
            )
        }

        // Dry-run: report estimate, do NOT toggle.
        if executor.dryRun {
            return ExecutionResult(
                outcome: .success(reclaimedMB: nil),
                metadata: ["estimate_mb": "200-600", "display_id": String(displayID)]
            )
        }

        // Toggle display mode to flush WindowServer caches.
        // Save current mode, switch to a different mode, then switch back.
        guard let currentMode = CGDisplayCopyDisplayMode(displayID) else {
            return ExecutionResult(outcome: .error(message: "cannot_read_display_mode"))
        }

        // Get all available modes and find a different one to toggle to.
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode],
              modes.count > 1 else {
            return ExecutionResult(outcome: .error(message: "insufficient_display_modes"))
        }

        // Find a mode different from current (prefer same resolution, different refresh if possible).
        let currentWidth = currentMode.width
        let currentHeight = currentMode.height
        let altMode = modes.first { mode in
            mode.width == currentWidth && mode.height == currentHeight &&
            mode.refreshRate != currentMode.refreshRate
        } ?? modes.first { $0.width != currentWidth || $0.height != currentHeight }

        guard let toggleMode = altMode else {
            return ExecutionResult(outcome: .error(message: "no_alternate_display_mode"))
        }

        // Perform the toggle: switch away, then switch back.
        var config: CGDisplayConfigRef?
        var err = CGBeginDisplayConfiguration(&config)
        guard err == .success, let cfg = config else {
            return ExecutionResult(outcome: .error(message: "display_config_begin_failed"))
        }

        err = CGConfigureDisplayWithDisplayMode(cfg, displayID, toggleMode, nil)
        guard err == .success else {
            CGCancelDisplayConfiguration(cfg)
            return ExecutionResult(outcome: .error(message: "display_config_set_failed"))
        }

        err = CGCompleteDisplayConfiguration(cfg, .forSession)
        guard err == .success else {
            return ExecutionResult(outcome: .error(message: "display_config_complete_failed"))
        }

        // Brief pause to let WindowServer process the mode change.
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms

        // Switch back to original mode.
        var restoreConfig: CGDisplayConfigRef?
        err = CGBeginDisplayConfiguration(&restoreConfig)
        guard err == .success, let restoreCfg = restoreConfig else {
            return ExecutionResult(
                outcome: .error(message: "display_restore_begin_failed"),
                metadata: ["warning": "display_left_in_alternate_mode"]
            )
        }

        err = CGConfigureDisplayWithDisplayMode(restoreCfg, displayID, currentMode, nil)
        guard err == .success else {
            CGCancelDisplayConfiguration(restoreCfg)
            return ExecutionResult(
                outcome: .error(message: "display_restore_set_failed"),
                metadata: ["warning": "display_left_in_alternate_mode"]
            )
        }

        err = CGCompleteDisplayConfiguration(restoreCfg, .forSession)
        guard err == .success else {
            return ExecutionResult(
                outcome: .error(message: "display_restore_complete_failed"),
                metadata: ["warning": "display_may_be_in_alternate_mode"]
            )
        }

        return ExecutionResult(
            outcome: .success(reclaimedMB: nil),
            metadata: ["estimate_mb": "200-600"]
        )
    }
}

// MARK: - Compressor Tuning

/// Tunes the VM compressor for memory-constrained machines (<= 8 GB RAM).
///
/// Tier 2 (confirm): changes system-level VM behavior.
///
/// Uses XPC for `setSysctlValue(...)` which is journaled via SysctlJournal.
/// Only applicable on machines with <= 8 GB physical memory (checked locally).
public final class CompressorTuning: Intervention {
    public let name = "compressor_tuning"
    public let tier: InterventionTier = .confirm

    /// The sysctl to tune.
    private static let sysctlName = "vm.compressor_mode"

    /// The value to set (mode 4 = frozen compressed, aggressive reclaim).
    private static let targetValue: Int32 = 4

    /// 8 GB in bytes.
    private static let memoryThreshold: UInt64 = 8_589_934_592

    public init() {}

    public func isApplicable(snapshot: MemorySnapshot) -> Bool {
        ProcessInfo.processInfo.physicalMemory <= Self.memoryThreshold
    }

    public func execute(via executor: InterventionExecutor) async -> ExecutionResult {
        guard executor.confirmed || executor.dryRun else {
            return ExecutionResult(outcome: .error(message: "confirmation_required"))
        }

        // Gate: only on <= 8 GB machines (local check).
        guard ProcessInfo.processInfo.physicalMemory <= Self.memoryThreshold else {
            return ExecutionResult(
                outcome: .skipped(reason: "machine_above_8gb"),
                metadata: ["physical_memory_gb": String(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))]
            )
        }

        // Read current value first (always executes, even in dry-run).
        // We read locally since sysctl reads don't require root.
        var currentValue: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let readRC = sysctlbyname(Self.sysctlName, &currentValue, &size, nil, 0)

        var meta: [String: String] = [:]

        if readRC == 0 {
            meta["current_value"] = String(currentValue)
        } else {
            meta["current_value"] = "read_failed"
        }

        meta["target_value"] = String(Self.targetValue)

        // Already at target?
        if readRC == 0 && currentValue == Self.targetValue {
            return ExecutionResult(outcome: .skipped(reason: "already_at_target"), metadata: meta)
        }

        // Dry-run: report what would change (no XPC needed).
        if executor.dryRun {
            return ExecutionResult(outcome: .success(reclaimedMB: nil), metadata: meta)
        }

        // XPC required only for the actual write.
        guard let connection = executor.xpcConnection else {
            return ExecutionResult(outcome: .error(message: "xpc_not_available"), metadata: meta)
        }

        // Write via XPC (helper journals the change).
        let writeResult = await xpcCall(connection: connection) {
            (reply: @escaping ((Bool, String?)) -> Void, proxy) in
            proxy.setSysctlValue(name: Self.sysctlName, value: Self.targetValue) { success, errorMsg in
                reply((success, errorMsg))
            }
        }

        switch writeResult {
        case .value(let (success, errorMsg)):
            if success {
                return ExecutionResult(outcome: .success(reclaimedMB: nil), metadata: meta)
            } else {
                return ExecutionResult(outcome: .error(message: errorMsg ?? "sysctl_write_failed"), metadata: meta)
            }
        case .failed(let error):
            return ExecutionResult(outcome: .error(message: error), metadata: meta)
        }
    }
}

// MARK: - Snapshot Cleanup

/// Cleans up local APFS Time Machine snapshots to reclaim disk space.
///
/// Tier 2 (confirm): removes local snapshots, potentially 20-60 GB.
///
/// Runs app-side via `tmutil` (no XPC needed).
/// Listing always executes (even in dry-run). Deletion suppressed in dry-run.
///
/// Bounded to at most `maxDeletionsPerRun` snapshots per invocation to stay
/// within the protocol's 30-second subprocess timeout. Callers that need to
/// delete more snapshots should re-invoke the intervention.
public final class SnapshotCleanup: Intervention {
    public let name = "snapshot_cleanup"
    public let tier: InterventionTier = .confirm

    /// Maximum snapshots to delete in a single run.
    /// Each tmutil deletelocalsnapshots call can take several seconds;
    /// capping at 5 keeps the total well under the 30s protocol timeout.
    private static let maxDeletionsPerRun = 5

    public init() {}

    public func isApplicable(snapshot: MemorySnapshot) -> Bool {
        true
    }

    /// End-to-end budget for the entire intervention, in seconds.
    /// Leaves 5s margin under the protocol's 30s subprocess timeout.
    private static let totalBudgetSeconds: Double = 25.0

    /// Per-subprocess timeout for listing snapshots.
    private static let listTimeoutSeconds: Double = 8.0

    /// Per-subprocess timeout for deleting a single snapshot.
    private static let deleteTimeoutSeconds: Double = 5.0

    public func execute(via executor: InterventionExecutor) async -> ExecutionResult {
        guard executor.confirmed || executor.dryRun else {
            return ExecutionResult(outcome: .error(message: "confirmation_required"))
        }

        let deadline = CFAbsoluteTimeGetCurrent() + Self.totalBudgetSeconds

        // Step 1: List local snapshots (always executes, even in dry-run).
        let snapshots: [String]
        do {
            snapshots = try await listLocalSnapshots()
        } catch {
            return ExecutionResult(outcome: .error(message: "tmutil_list_failed: \(error.localizedDescription)"))
        }

        var meta: [String: String] = [:]
        // Cap stored snapshot IDs to avoid bloating JSON output.
        let cappedSnapshots = Array(snapshots.prefix(50))
        meta["snapshots"] = cappedSnapshots.joined(separator: ",")
        meta["snapshot_count"] = String(snapshots.count)

        if snapshots.isEmpty {
            return ExecutionResult(outcome: .skipped(reason: "no_local_snapshots"), metadata: meta)
        }

        // Dry-run: report snapshots but do NOT delete.
        if executor.dryRun {
            meta["estimate_mb"] = "20000-60000"
            return ExecutionResult(outcome: .success(reclaimedMB: nil), metadata: meta)
        }

        // Step 2: Delete snapshots with bounded batch and end-to-end deadline.
        let batch = Array(snapshots.prefix(Self.maxDeletionsPerRun))
        var deleted = 0
        var budgetExhausted = false
        var errors: [String] = []

        for snapshot in batch {
            // Check remaining budget before starting another subprocess.
            let timeLeft = deadline - CFAbsoluteTimeGetCurrent()
            if timeLeft < Self.deleteTimeoutSeconds {
                budgetExhausted = true
                break
            }

            do {
                try await deleteLocalSnapshot(date: snapshot)
                deleted += 1
            } catch {
                errors.append("\(snapshot): \(error.localizedDescription)")
            }
        }

        // remaining_count = all snapshots still on disk (not successfully deleted).
        let stillOnDisk = snapshots.count - deleted
        meta["deleted_count"] = String(deleted)
        if stillOnDisk > 0 {
            meta["remaining_count"] = String(stillOnDisk)
        }
        if !errors.isEmpty {
            meta["failed_count"] = String(errors.count)
            meta["errors"] = errors.joined(separator: "; ")
        }
        if budgetExhausted {
            meta["budget_exhausted"] = "true"
        }

        if deleted == 0 && !errors.isEmpty {
            return ExecutionResult(outcome: .error(message: "all_deletes_failed"), metadata: meta)
        }

        return ExecutionResult(outcome: .success(reclaimedMB: nil), metadata: meta)
    }

    // MARK: - tmutil helpers

    /// List local Time Machine snapshot dates.
    private func listLocalSnapshots() async throws -> [String] {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", "/"]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        // Set termination handler BEFORE run (pitfall).
        // Shared flag so terminationHandler maps post-timeout exits to .timeout.
        let timedOutFlag = AtomicFlag()

        return try await withCheckedThrowingContinuation { continuation in
            let resumer = ThrowingOnceResumer(continuation)

            process.terminationHandler = { proc in
                // If the timeout task already fired, map any exit to .timeout
                // to avoid reporting a misleading SIGTERM/SIGKILL status.
                if timedOutFlag.value {
                    resumer.resume(with: .failure(SnapshotError.timeout))
                    return
                }

                let data = stdoutHandle.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                // Check terminationStatus — non-zero indicates failure.
                if proc.terminationStatus != 0 {
                    let errData = stderrHandle.readDataToEndOfFile()
                    let errOutput = String(data: errData, encoding: .utf8) ?? "unknown"
                    resumer.resume(with: .failure(SnapshotError.listFailed(
                        status: proc.terminationStatus, stderr: errOutput)))
                    return
                }

                // tmutil output lines like "com.apple.TimeMachine.2024-01-15-123456.local"
                // Extract the date portion.
                let dates = output.components(separatedBy: .newlines)
                    .compactMap { line -> String? in
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        // Extract date from "com.apple.TimeMachine.YYYY-MM-DD-HHMMSS.local"
                        guard trimmed.hasPrefix("com.apple.TimeMachine.") else { return nil }
                        let stripped = trimmed
                            .replacingOccurrences(of: "com.apple.TimeMachine.", with: "")
                            .replacingOccurrences(of: ".local", with: "")
                        return stripped.isEmpty ? nil : stripped
                    }

                resumer.resume(with: .success(dates))
            }

            do {
                try process.run()
            } catch {
                resumer.resume(with: .failure(error))
            }

            // Timeout for listing; terminate and escalate to SIGKILL if needed.
            Task {
                try? await Task.sleep(nanoseconds: UInt64(SnapshotCleanup.listTimeoutSeconds * 1_000_000_000))
                guard process.isRunning else { return }
                timedOutFlag.set()
                process.terminate()
                // Wait 2s for graceful exit, then force-kill.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    // Wait for child to be reaped before resuming.
                    process.waitUntilExit()
                }
                resumer.resume(with: .failure(SnapshotError.timeout))
            }
        }
    }

    /// Delete a local Time Machine snapshot by date string.
    /// Uses a bounded timeout with proper child reaping: SIGTERM, wait 2s, SIGKILL.
    private func deleteLocalSnapshot(date: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["deletelocalsnapshots", date]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let timedOutFlag = AtomicFlag()

        return try await withCheckedThrowingContinuation { continuation in
            let resumer = ThrowingOnceResumer(continuation)

            process.terminationHandler = { proc in
                if timedOutFlag.value {
                    resumer.resume(with: .failure(SnapshotError.timeout))
                    return
                }
                if proc.terminationStatus == 0 {
                    resumer.resume(with: .success(()))
                } else {
                    resumer.resume(with: .failure(SnapshotError.deleteFailed(date: date, status: proc.terminationStatus)))
                }
            }

            do {
                try process.run()
            } catch {
                resumer.resume(with: .failure(error))
            }

            // Timeout with proper child reaping: SIGTERM → wait 2s → SIGKILL.
            Task {
                try? await Task.sleep(nanoseconds: UInt64(SnapshotCleanup.deleteTimeoutSeconds * 1_000_000_000))
                guard process.isRunning else { return }
                timedOutFlag.set()
                process.terminate()
                // Wait 2s for graceful exit, then force-kill to ensure the child is reaped.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    // Wait for child to be reaped before resuming.
                    process.waitUntilExit()
                }
                resumer.resume(with: .failure(SnapshotError.timeout))
            }
        }
    }
}

private enum SnapshotError: LocalizedError {
    case timeout
    case listFailed(status: Int32, stderr: String)
    case deleteFailed(date: String, status: Int32)

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "tmutil operation timed out"
        case .listFailed(let status, let stderr):
            return "tmutil listlocalsnapshots exited with status \(status): \(stderr)"
        case .deleteFailed(let date, let status):
            return "tmutil deletelocalsnapshots \(date) exited with status \(status)"
        }
    }
}
