// Tier3Interventions.swift
// Tier 3 (destructive) interventions: SIGTERMCascade, SIGSTOPFreeze, SleepImageDelete.

import Foundation
import CacheoutShared
import Darwin
import IOKit.ps
import os

// MARK: - XPC Helpers (shared pattern)

/// Default XPC call timeout in seconds.
private let xpcTimeoutSeconds: UInt64 = 15

/// Result of an XPC call: either a value or an error message.
private enum XPCResult<T> {
    case value(T)
    case failed(String)
}

/// Thread-safe once-box for resuming a continuation exactly once.
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

/// Perform an XPC call with a timeout. The timeout task is cancelled once
/// a reply arrives to avoid leaking background work.
private func xpcCall<T>(
    connection: NSXPCConnection,
    timeout: UInt64 = xpcTimeoutSeconds,
    body: @escaping (@escaping (T) -> Void, MemoryHelperProtocol) -> Void
) async -> XPCResult<T> {
    await withCheckedContinuation { (continuation: CheckedContinuation<XPCResult<T>, Never>) in
        let resumer = OnceResumer(continuation)

        // Timeout task handle — shared so both reply and error paths can cancel it.
        nonisolated(unsafe) var timeoutTask: Task<Void, Never>?

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            timeoutTask?.cancel()
            resumer.resume(with: .failed("xpc_error: \(error.localizedDescription)"))
        } as! MemoryHelperProtocol

        timeoutTask = Task {
            try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
            resumer.resume(with: .failed("xpc_timeout"))
        }

        body({ result in
            timeoutTask?.cancel()
            resumer.resume(with: .value(result))
        }, proxy)
    }
}

// MARK: - PID Validation

/// Strong identity for a process: full executable path + start time.
/// Used to detect PID reuse between initial validation and delayed signals.
private struct ProcessIdentity {
    let pid: pid_t
    let fullPath: String
    let name: String
    let startTimeSec: UInt64   // p_starttime.tv_sec from proc_bsdinfo
    let startTimeUSec: UInt64  // p_starttime.tv_usec from proc_bsdinfo
}

/// Get the process start time from BSD info. Returns nil on failure.
private func getProcessStartTime(_ pid: pid_t) -> (sec: UInt64, usec: UInt64)? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
    guard result == size else { return nil }
    let sec = info.pbi_start_tvsec
    let usec = info.pbi_start_tvusec
    // A zero start time means the kernel didn't populate the field — treat as unusable.
    guard sec != 0 else { return nil }
    return (sec, usec)
}

/// Capture the full identity of a process: path, name, and start time.
/// Returns nil if the process cannot be resolved or if start time is unavailable
/// (fail closed — we refuse to build an identity without a usable start token).
private func captureProcessIdentity(_ pid: pid_t) -> ProcessIdentity? {
    let bufferSize = Int(MAXPATHLEN)
    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    let pathLen = proc_pidpath(pid, buffer, UInt32(bufferSize))
    guard pathLen > 0 else { return nil }

    let fullPath = String(cString: buffer)
    let name = (fullPath as NSString).lastPathComponent

    // Fail closed: if we can't read a valid start time, reject the identity entirely.
    guard let startTime = getProcessStartTime(pid) else { return nil }

    return ProcessIdentity(pid: pid, fullPath: fullPath, name: name,
                           startTimeSec: startTime.sec, startTimeUSec: startTime.usec)
}

/// Validate a PID by resolving its path via proc_pidpath and comparing the
/// basename against the expected target name. Returns the full identity on success.
private func validatePID(_ pid: pid_t, expectedName: String) -> (valid: Bool, identity: ProcessIdentity?, error: String?) {
    guard let identity = captureProcessIdentity(pid) else {
        return (false, nil, "proc_pidpath_failed: pid \(pid) not found or inaccessible")
    }

    guard identity.name == expectedName else {
        return (false, identity, "pid_name_mismatch: expected \(expectedName), got \(identity.name)")
    }

    return (true, identity, nil)
}

/// Re-validate that a PID still refers to the same process by comparing
/// the full executable path and start time against a previously captured identity.
/// Fails closed: if either identity lacks a usable start time, returns false.
private func revalidateProcess(_ original: ProcessIdentity) -> Bool {
    guard let current = captureProcessIdentity(original.pid) else {
        return false  // Process gone or start time unreadable
    }
    // Both identities are guaranteed to have valid start times (captureProcessIdentity
    // rejects identities without usable start tokens). Compare full path + full timestamp.
    return current.fullPath == original.fullPath
        && current.startTimeSec == original.startTimeSec
        && current.startTimeUSec == original.startTimeUSec
}

// MARK: - SIGTERM Cascade

/// Sends SIGTERM to a target process, waits a configurable grace period,
/// then sends SIGKILL if still running.
///
/// Tier 3 (destructive): requires --confirm --target-pid N --target-name NAME.
/// PID validated via proc_pidpath before signaling.
/// Dry-run: resolves PID path (read), does NOT signal.
public final class SIGTERMCascade: Intervention {
    public let name = "sigterm_cascade"
    public let tier: InterventionTier = .destructive

    /// Target PID to signal.
    private let targetPID: pid_t

    /// Expected process name for PID validation.
    private let targetName: String

    /// Seconds to wait after SIGTERM before escalating to SIGKILL.
    private let graceSeconds: Double

    public init(targetPID: pid_t, targetName: String, graceSeconds: Double = 5.0) {
        self.targetPID = targetPID
        self.targetName = targetName
        self.graceSeconds = max(0, graceSeconds)
    }

    public func isApplicable(snapshot: MemorySnapshot) -> Bool {
        true
    }

    public func execute(via executor: InterventionExecutor) async -> ExecutionResult {
        // Reject targeting our own process — SIGTERM would kill the CLI
        // before it can emit structured JSON output.
        if targetPID == getpid() {
            return ExecutionResult(
                outcome: .error(message: "cannot_signal_self: targeting the CLI process is not allowed"),
                metadata: ["target_pid": String(targetPID)]
            )
        }

        // PID validation (always executes, even in dry-run).
        // Captures full identity (path + start time) for revalidation.
        let validation = validatePID(targetPID, expectedName: targetName)
        var meta: [String: String] = [
            "target_pid": String(targetPID),
            "target_name": targetName,
        ]

        if let identity = validation.identity {
            meta["resolved_name"] = identity.name
            meta["resolved_path"] = identity.fullPath
        }

        guard validation.valid, let identity = validation.identity else {
            return ExecutionResult(
                outcome: .error(message: validation.error ?? "pid_validation_failed"),
                metadata: meta
            )
        }

        // Dry-run: report validated PID, do NOT signal.
        if executor.dryRun {
            meta["action"] = "would_sigterm_then_sigkill"
            meta["grace_seconds"] = String(graceSeconds)
            return ExecutionResult(outcome: .success(reclaimedMB: nil), metadata: meta)
        }

        // Live execution requires confirmation.
        guard executor.confirmed else {
            return ExecutionResult(outcome: .error(message: "confirmation_required"))
        }

        // Send SIGTERM.
        let termResult = kill(targetPID, SIGTERM)
        if termResult != 0 {
            let err = errno
            return ExecutionResult(
                outcome: .error(message: "sigterm_failed: errno \(err)"),
                metadata: meta
            )
        }
        meta["sigterm_sent"] = "true"

        // Wait grace period, then check if still running.
        try? await Task.sleep(nanoseconds: UInt64(graceSeconds * 1_000_000_000))

        // Check if process still exists (kill with signal 0).
        let stillAlive = kill(targetPID, 0) == 0
        if stillAlive {
            // Strong revalidation: full path + start time to guard against PID reuse.
            if revalidateProcess(identity) {
                let killResult = kill(targetPID, SIGKILL)
                if killResult != 0 {
                    let err = errno
                    meta["sigkill_failed"] = "errno \(err)"
                    return ExecutionResult(
                        outcome: .error(message: "sigkill_failed: errno \(err)"),
                        metadata: meta
                    )
                } else {
                    meta["sigkill_sent"] = "true"
                }
            } else {
                meta["sigkill_skipped"] = "pid_reuse_detected"
                return ExecutionResult(
                    outcome: .error(message: "sigkill_skipped_pid_reuse"),
                    metadata: meta
                )
            }
        } else {
            meta["exited_after_sigterm"] = "true"
        }

        return ExecutionResult(outcome: .success(reclaimedMB: nil), metadata: meta)
    }
}

// MARK: - SIGSTOP Freeze

/// Process-level lock to prevent concurrent SIGSTOPFreeze executions.
/// Only one freeze may be active at a time because cleanup relies on
/// process-wide signal handling state.
private let _freezeLock = NSLock()
private nonisolated(unsafe) var _freezeActive = false

/// Freezes a target process with SIGSTOP and automatically resumes it with
/// SIGCONT after a configurable duration (max 120s, default 30s).
///
/// Tier 3 (destructive): requires --confirm --target-pid N --target-name NAME.
/// CLI blocks until SIGCONT is sent. Cleanup via DispatchSourceSignal ensures
/// SIGCONT is sent (with PID re-validation) if CLI receives SIGINT/SIGTERM.
/// Only one freeze may be active at a time (process-level exclusion).
/// Dry-run: resolves PID path, does NOT signal.
public final class SIGSTOPFreeze: Intervention {
    public let name = "sigstop_freeze"
    public let tier: InterventionTier = .destructive

    /// Target PID to freeze.
    private let targetPID: pid_t

    /// Expected process name for PID validation.
    private let targetName: String

    /// Duration in seconds to keep the process frozen (max 120s).
    private let freezeSeconds: Double

    /// Maximum allowed freeze duration.
    private static let maxFreezeSeconds: Double = 120.0

    /// Default freeze is 20s to leave margin for validation, signal setup,
    /// resume, and JSON emission within the 30s MCP subprocess contract.
    public init(targetPID: pid_t, targetName: String, freezeSeconds: Double = 20.0) {
        self.targetPID = targetPID
        self.targetName = targetName
        self.freezeSeconds = min(max(0, freezeSeconds), Self.maxFreezeSeconds)
    }

    public func isApplicable(snapshot: MemorySnapshot) -> Bool {
        true
    }

    /// Send SIGCONT to the target PID only after strong identity revalidation
    /// (full path + start time). Returns metadata about what happened.
    private func validatedResume(original: ProcessIdentity) -> (sent: Bool, meta: [String: String]) {
        var resumeMeta: [String: String] = [:]
        if revalidateProcess(original) {
            let contResult = kill(targetPID, SIGCONT)
            if contResult != 0 {
                let err = errno
                resumeMeta["sigcont_failed"] = "errno \(err)"
                return (false, resumeMeta)
            }
            resumeMeta["sigcont_sent"] = "true"
            return (true, resumeMeta)
        } else {
            resumeMeta["sigcont_skipped"] = "pid_reuse_detected"
            return (false, resumeMeta)
        }
    }

    public func execute(via executor: InterventionExecutor) async -> ExecutionResult {
        // Reject targeting our own process — SIGSTOP would freeze the CLI,
        // preventing the timer and cleanup handler from running SIGCONT.
        if targetPID == getpid() {
            return ExecutionResult(
                outcome: .error(message: "cannot_signal_self: targeting the CLI process is not allowed"),
                metadata: ["target_pid": String(targetPID)]
            )
        }

        // PID validation (always executes, even in dry-run).
        // Captures full identity (path + start time) for revalidation.
        let validation = validatePID(targetPID, expectedName: targetName)
        var meta: [String: String] = [
            "target_pid": String(targetPID),
            "target_name": targetName,
        ]

        if let identity = validation.identity {
            meta["resolved_name"] = identity.name
            meta["resolved_path"] = identity.fullPath
        }

        guard validation.valid, let identity = validation.identity else {
            return ExecutionResult(
                outcome: .error(message: validation.error ?? "pid_validation_failed"),
                metadata: meta
            )
        }

        // Dry-run: report validated PID, do NOT signal.
        if executor.dryRun {
            meta["action"] = "would_sigstop_then_sigcont"
            meta["freeze_seconds"] = String(freezeSeconds)
            return ExecutionResult(outcome: .success(reclaimedMB: nil), metadata: meta)
        }

        // Live execution requires confirmation.
        guard executor.confirmed else {
            return ExecutionResult(outcome: .error(message: "confirmation_required"))
        }

        // Enforce single-active-freeze at process scope.
        _freezeLock.lock()
        if _freezeActive {
            _freezeLock.unlock()
            return ExecutionResult(
                outcome: .error(message: "concurrent_freeze_rejected"),
                metadata: meta
            )
        }
        _freezeActive = true
        _freezeLock.unlock()

        // Set up DispatchSourceSignal handlers BEFORE sending SIGSTOP.
        // DispatchSourceSignal runs in a normal execution context so we can
        // revalidate process identity before SIGCONT — unlike C signal handlers.
        // Ignore default signal delivery so dispatch sources receive the signals.
        let previousSIGINT = signal(SIGINT, SIG_IGN)
        let previousSIGTERM = signal(SIGTERM, SIG_IGN)
        let previousSIGHUP = signal(SIGHUP, SIG_IGN)

        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        let sighupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .global())

        // Capture identity for the cleanup handler's strong revalidation.
        let capturedIdentity = identity

        let cleanupHandler: () -> Void = {
            // Strong revalidation (full path + start time) before resuming.
            if revalidateProcess(capturedIdentity) {
                kill(capturedIdentity.pid, SIGCONT)
            }
            // Release freeze lock before exiting.
            _freezeLock.lock()
            _freezeActive = false
            _freezeLock.unlock()
            _exit(1)
        }

        sigintSource.setEventHandler(handler: cleanupHandler)
        sigtermSource.setEventHandler(handler: cleanupHandler)
        sighupSource.setEventHandler(handler: cleanupHandler)
        sigintSource.resume()
        sigtermSource.resume()
        sighupSource.resume()

        // Send SIGSTOP.
        let stopResult = kill(targetPID, SIGSTOP)
        if stopResult != 0 {
            let err = errno
            // Tear down signal sources — SIGSTOP failed, no process to resume.
            sigintSource.cancel()
            sigtermSource.cancel()
            sighupSource.cancel()
            signal(SIGINT, previousSIGINT)
            signal(SIGTERM, previousSIGTERM)
            signal(SIGHUP, previousSIGHUP)
            _freezeLock.lock()
            _freezeActive = false
            _freezeLock.unlock()
            return ExecutionResult(
                outcome: .error(message: "sigstop_failed: errno \(err)"),
                metadata: meta
            )
        }
        meta["sigstop_sent"] = "true"

        // Block for freeze duration.
        try? await Task.sleep(nanoseconds: UInt64(freezeSeconds * 1_000_000_000))

        // Resume: strong revalidation (full path + start time) before SIGCONT.
        let (resumed, resumeMeta) = validatedResume(original: identity)
        meta.merge(resumeMeta) { _, new in new }

        // Tear down signal sources and restore previous handlers.
        sigintSource.cancel()
        sigtermSource.cancel()
        sighupSource.cancel()
        signal(SIGINT, previousSIGINT)
        signal(SIGTERM, previousSIGTERM)
        signal(SIGHUP, previousSIGHUP)

        // Release freeze lock.
        _freezeLock.lock()
        _freezeActive = false
        _freezeLock.unlock()

        meta["freeze_seconds"] = String(freezeSeconds)

        // If SIGCONT failed or was skipped, report as error -- the target
        // may still be frozen (unless PID was reused by a different process).
        if !resumed {
            if meta["sigcont_skipped"] != nil {
                return ExecutionResult(
                    outcome: .error(message: "sigcont_skipped_pid_reuse"),
                    metadata: meta
                )
            }
            return ExecutionResult(
                outcome: .error(message: "sigcont_failed"),
                metadata: meta
            )
        }

        return ExecutionResult(outcome: .success(reclaimedMB: nil), metadata: meta)
    }
}

// MARK: - Sleep Image Delete

/// Deletes the sleep image file (`/private/var/vm/sleepimage`) to reclaim
/// 2-16 GB of disk space. Desktop-only (laptops use hibernate).
///
/// Tier 3 (destructive): requires --confirm only (NOT --target-pid/--target-name).
/// Desktop-only gate: checks `IOPSCopyPowerSourcesInfo()` for battery.
/// Dry-run: calls `getSleepImageSize()` for real file info, does NOT delete.
public final class SleepImageDelete: Intervention {
    public let name = "sleep_image_delete"
    public let tier: InterventionTier = .destructive

    public init() {}

    public func isApplicable(snapshot: MemorySnapshot) -> Bool {
        true
    }

    /// Battery detection result: tri-state to fail closed on indeterminate reads.
    private enum BatteryStatus {
        case hasBattery
        case noBattery
        case unknown
    }

    /// Check if the machine has a battery (laptop detection).
    /// Returns `.unknown` if the power source API fails or returns ambiguous
    /// results, to fail closed on destructive operations.
    private func detectBattery() -> BatteryStatus {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return .unknown
        }
        guard let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [Any] else {
            return .unknown
        }
        // Empty source list means no power sources registered — this is normal
        // on battery-less desktops (Mac Mini, Mac Pro, Mac Studio).
        if sources.isEmpty {
            return .noBattery
        }
        var inspectedCount = 0
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(info, source as CFTypeRef)?.takeUnretainedValue() as? [String: Any] else {
                // Unreadable source description — fail closed.
                return .unknown
            }
            inspectedCount += 1
            if let type = desc[kIOPSTypeKey] as? String, type == kIOPSInternalBatteryType {
                return .hasBattery
            }
        }
        // Only return noBattery if we successfully inspected all sources.
        guard inspectedCount == sources.count else {
            return .unknown
        }
        return .noBattery
    }

    public func execute(via executor: InterventionExecutor) async -> ExecutionResult {
        // Desktop-only gate: reject on laptops and fail closed on unknown.
        switch detectBattery() {
        case .hasBattery:
            return ExecutionResult(
                outcome: .skipped(reason: "laptop_detected"),
                metadata: ["reason": "sleep_image_deletion_unsafe_on_laptops"]
            )
        case .unknown:
            return ExecutionResult(
                outcome: .error(message: "power_source_detection_failed"),
                metadata: ["reason": "cannot_determine_battery_status_failing_closed"]
            )
        case .noBattery:
            break // Desktop confirmed, proceed.
        }

        // XPC required for both read and write.
        guard let connection = executor.xpcConnection else {
            return ExecutionResult(outcome: .error(message: "xpc_not_available"))
        }

        // Read size (always executes, even in dry-run).
        let sizeResult = await xpcCall(connection: connection) {
            (reply: @escaping ((Bool, Bool, UInt64, String?)) -> Void, proxy) in
            proxy.getSleepImageSize { success, exists, sizeBytes, errorMessage in
                reply((success, exists, sizeBytes, errorMessage))
            }
        }

        let (success, exists, sizeBytes, errorMessage): (Bool, Bool, UInt64, String?)
        switch sizeResult {
        case .value(let tuple):
            (success, exists, sizeBytes, errorMessage) = tuple
        case .failed(let error):
            return ExecutionResult(outcome: .error(message: error))
        }

        if !success {
            return ExecutionResult(
                outcome: .error(message: "sleep_image_stat_failed: \(errorMessage ?? "unknown")")
            )
        }

        if !exists {
            return ExecutionResult(outcome: .skipped(reason: "file_absent"))
        }

        var meta: [String: String] = [
            "file_size_bytes": String(sizeBytes),
            "file_size_mb": String(sizeBytes / (1024 * 1024)),
        ]

        // Dry-run: report file info, do NOT delete.
        if executor.dryRun {
            return ExecutionResult(outcome: .success(reclaimedMB: nil), metadata: meta)
        }

        // Live execution requires confirmation.
        guard executor.confirmed else {
            return ExecutionResult(outcome: .error(message: "confirmation_required"))
        }

        // Live: delete via XPC.
        let deleteResult = await xpcCall(connection: connection) {
            (reply: @escaping ((Bool, UInt64)) -> Void, proxy) in
            proxy.deleteSleepImage { success, bytesReclaimed in
                reply((success, bytesReclaimed))
            }
        }

        switch deleteResult {
        case .value(let (deleteSuccess, bytesReclaimed)):
            if deleteSuccess {
                meta["bytes_reclaimed"] = String(bytesReclaimed)
                let reclaimedMB = Int(bytesReclaimed / (1024 * 1024))
                return ExecutionResult(
                    outcome: .success(reclaimedMB: reclaimedMB),
                    metadata: meta
                )
            } else {
                return ExecutionResult(
                    outcome: .error(message: "delete_sleep_image_failed"),
                    metadata: meta
                )
            }
        case .failed(let error):
            return ExecutionResult(outcome: .error(message: error), metadata: meta)
        }
    }
}
