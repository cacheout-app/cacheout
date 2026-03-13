// InterventionEngine.swift
// Orchestrator that runs interventions with before/after memory snapshots and timing.

import Foundation

/// Orchestrator for running interventions with before/after memory snapshots and timing.
///
/// The engine captures snapshots and measures duration. It does NOT enforce tier
/// gates -- that responsibility belongs to each intervention's `execute(via:)` and
/// the CLI layer. The engine:
/// 1. Captures an optional before snapshot
/// 2. Runs the intervention via `execute(via:)`
/// 3. Captures an optional after snapshot
/// 4. Assembles an `InterventionResult` with timing and metadata
///
/// Snapshot capture failures are recorded in metadata but do not abort the intervention.
public struct InterventionEngine {

    /// Run a single intervention, capturing before/after snapshots and timing.
    ///
    /// - Parameters:
    ///   - intervention: The intervention to execute.
    ///   - executor: The executor providing capabilities (XPC, dry-run, confirmed).
    /// - Returns: A complete `InterventionResult` with snapshots, timing, and metadata.
    public static func run(
        intervention: any Intervention,
        via executor: InterventionExecutor
    ) async -> InterventionResult {
        var snapshotMeta: [String: String] = [:]

        // Step 1: Before snapshot (optional — failure recorded in metadata).
        let before: MemorySnapshot?
        do {
            before = try MemorySnapshot.capture()
        } catch {
            before = nil
            snapshotMeta["snapshot_error"] = "before_capture_failed"
        }

        // Step 2: Execute intervention with timing (monotonic clock).
        let startTime = ProcessInfo.processInfo.systemUptime
        let executionResult = await intervention.execute(via: executor)
        let duration = ProcessInfo.processInfo.systemUptime - startTime

        // Step 3: After snapshot (optional — failure recorded in metadata).
        let after: MemorySnapshot?
        do {
            after = try MemorySnapshot.capture()
        } catch {
            after = nil
            let existing = snapshotMeta["snapshot_error"]
            if let existing {
                snapshotMeta["snapshot_error"] = existing + "; after_capture_failed"
            } else {
                snapshotMeta["snapshot_error"] = "after_capture_failed"
            }
        }

        // Step 4: Merge execution metadata with snapshot metadata.
        let mergedMeta = executionResult.metadata.merging(snapshotMeta) { exec, _ in exec }

        return InterventionResult(
            name: intervention.name,
            outcome: executionResult.outcome,
            before: before,
            after: after,
            duration: duration,
            metadata: mergedMeta
        )
    }

    /// Select applicable interventions for a given tier from the provided list.
    ///
    /// - Parameters:
    ///   - tier: The tier to filter by.
    ///   - snapshot: The current memory state to check applicability against.
    ///   - interventions: The full list of available interventions.
    /// - Returns: Interventions matching the tier that are applicable.
    public static func selectInterventions(
        tier: InterventionTier,
        snapshot: MemorySnapshot,
        from interventions: [any Intervention]
    ) -> [any Intervention] {
        interventions.filter { $0.tier == tier && $0.isApplicable(snapshot: snapshot) }
    }

    /// Run multiple interventions in sequence, collecting results.
    ///
    /// Mixed-transport interventions (some XPC, some local) work naturally since
    /// each intervention picks its transport from the executor's capabilities.
    ///
    /// - Parameters:
    ///   - interventions: The interventions to execute.
    ///   - executor: The executor providing capabilities.
    /// - Returns: An array of results, one per intervention.
    public static func runAll(
        interventions: [any Intervention],
        via executor: InterventionExecutor
    ) async -> [InterventionResult] {
        var results: [InterventionResult] = []
        for intervention in interventions {
            let result = await run(intervention: intervention, via: executor)
            results.append(result)
        }
        return results
    }
}
