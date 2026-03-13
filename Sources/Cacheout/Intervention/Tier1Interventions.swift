// Tier1Interventions.swift
// Tier 1 (safe/auto) interventions: PressureTrigger and ReduceTransparency.

import Foundation
import CacheoutShared

// MARK: - XPC Helpers

/// Default XPC call timeout in seconds.
private let xpcTimeoutSeconds: UInt64 = 15

/// Result of an XPC call: either a value or an error message.
private enum XPCResult<T> {
    case value(T)
    case failed(String)
}

/// Perform an XPC call with a timeout, handling both the XPC error handler
/// and the reply callback. Returns the result or an error message.
private func xpcCall<T>(
    connection: NSXPCConnection,
    timeout: UInt64 = xpcTimeoutSeconds,
    body: @escaping (@escaping (T) -> Void, MemoryHelperProtocol) -> Void
) async -> XPCResult<T> {
    await withCheckedContinuation { (continuation: CheckedContinuation<XPCResult<T>, Never>) in
        nonisolated(unsafe) var resumed = false
        let lock = NSLock()

        func resumeOnce(_ result: XPCResult<T>) {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: result)
        }

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            resumeOnce(.failed("xpc_error: \(error.localizedDescription)"))
        } as! MemoryHelperProtocol

        // Timeout
        Task {
            try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
            resumeOnce(.failed("xpc_timeout"))
        }

        body({ result in
            resumeOnce(.value(result))
        }, proxy)
    }
}

// MARK: - Pressure Trigger

/// Triggers a manual memory purge via the helper's `triggerPurge(level:)` sysctl write.
///
/// Tier 1 (safe): auto-eligible, no user confirmation needed.
/// Typical reclamation: 100-500 MB.
public final class PressureTrigger: Intervention {
    public let name = "pressure_trigger"
    public let tier: InterventionTier = .safe

    /// Purge level passed to `kern.memorypressure_manual_trigger`.
    private let level: Int32

    public init(level: Int32 = 1) {
        self.level = level
    }

    public func isApplicable(snapshot: MemorySnapshot) -> Bool {
        true
    }

    public func execute(via executor: InterventionExecutor) async -> ExecutionResult {
        // Dry-run returns an estimate locally — no XPC needed.
        if executor.dryRun {
            return ExecutionResult(
                outcome: .success(reclaimedMB: nil),
                metadata: ["estimate_mb": "100-500"]
            )
        }

        guard let connection = executor.xpcConnection else {
            return ExecutionResult(outcome: .error(message: "xpc_not_available"))
        }

        let result = await xpcCall(connection: connection) { (reply: @escaping (Bool) -> Void, proxy) in
            proxy.triggerPurge(level: self.level, reply: reply)
        }

        switch result {
        case .value(let success):
            let outcome: InterventionOutcome = success
                ? .success(reclaimedMB: nil)
                : .error(message: "trigger_purge_failed")
            return ExecutionResult(outcome: outcome)
        case .failed(let error):
            return ExecutionResult(outcome: .error(message: error))
        }
    }
}

// MARK: - Reduce Transparency

/// Enables the Reduce Transparency accessibility setting to reduce WindowServer memory.
///
/// Tier 1 (safe): auto-eligible, no user confirmation needed.
/// Typical reclamation: 200-800 MB.
///
/// Read-first logic:
/// 1. Calls `getReduceTransparencyState()` (always executes, even in dry-run)
/// 2. If read fails -> `.error(errorMessage)`
/// 3. If already enabled -> `.skipped("already_enabled")`
/// 4. If disabled -> proceeds with write (unless dry-run)
public final class ReduceTransparency: Intervention {
    public let name = "reduce_transparency"
    public let tier: InterventionTier = .safe

    public init() {}

    public func isApplicable(snapshot: MemorySnapshot) -> Bool {
        true
    }

    public func execute(via executor: InterventionExecutor) async -> ExecutionResult {
        // Read requires XPC even in dry-run (reads always execute).
        guard let connection = executor.xpcConnection else {
            return ExecutionResult(outcome: .error(message: "xpc_not_available"))
        }

        // Step 1: Read current state (always executes, even in dry-run).
        let readResult = await xpcCall(connection: connection) { (reply: @escaping ((Bool, Bool, String?)) -> Void, proxy) in
            proxy.getReduceTransparencyState { success, enabled, errorMessage in
                reply((success, enabled, errorMessage))
            }
        }

        let (success, enabled, errorMessage): (Bool, Bool, String?)
        switch readResult {
        case .value(let tuple):
            (success, enabled, errorMessage) = tuple
        case .failed(let error):
            return ExecutionResult(outcome: .error(message: error))
        }

        if !success {
            return ExecutionResult(outcome: .error(message: errorMessage ?? "unknown_read_error"))
        }

        var meta: [String: String] = ["prior_value": String(enabled)]

        if enabled {
            return ExecutionResult(outcome: .skipped(reason: "already_enabled"), metadata: meta)
        }

        // Step 2: Write (suppressed in dry-run).
        if executor.dryRun {
            meta["estimate_mb"] = "200-800"
            return ExecutionResult(outcome: .success(reclaimedMB: nil), metadata: meta)
        }

        let writeResult = await xpcCall(connection: connection) { (reply: @escaping (Bool) -> Void, proxy) in
            proxy.setReduceTransparency(true, reply: reply)
        }

        switch writeResult {
        case .value(let writeSuccess):
            let outcome: InterventionOutcome = writeSuccess
                ? .success(reclaimedMB: nil)
                : .error(message: "set_reduce_transparency_failed")
            return ExecutionResult(outcome: outcome, metadata: meta)
        case .failed(let error):
            return ExecutionResult(outcome: .error(message: error), metadata: meta)
        }
    }
}
