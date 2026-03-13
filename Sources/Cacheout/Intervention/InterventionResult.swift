// InterventionResult.swift
// Codable result assembled by the InterventionEngine after running an intervention.

import Foundation

/// Complete result of an intervention execution, including optional before/after
/// memory snapshots, timing, and metadata.
public struct InterventionResult: Codable, Sendable {
    /// The intervention name (e.g., "pressure_trigger").
    public let name: String

    /// The outcome of the intervention.
    public let outcome: InterventionOutcome

    /// Memory snapshot captured before the intervention. Nil if capture failed.
    public let before: MemorySnapshot?

    /// Memory snapshot captured after the intervention. Nil if capture failed.
    public let after: MemorySnapshot?

    /// Wall-clock duration of the intervention execution in seconds.
    public let duration: TimeInterval

    /// Additional metadata produced by the intervention (e.g., "prior_value", "estimate").
    public let metadata: [String: String]

    public init(
        name: String,
        outcome: InterventionOutcome,
        before: MemorySnapshot?,
        after: MemorySnapshot?,
        duration: TimeInterval,
        metadata: [String: String]
    ) {
        self.name = name
        self.outcome = outcome
        self.before = before
        self.after = after
        self.duration = duration
        self.metadata = metadata
    }
}
