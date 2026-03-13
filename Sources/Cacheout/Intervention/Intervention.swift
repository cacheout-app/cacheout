// Intervention.swift
// Core protocol and types for the tiered intervention system.

import Foundation

// MARK: - Intervention Tier

/// Classification of interventions by safety level and required user interaction.
public enum InterventionTier: String, Codable, Sendable {
    /// Safe to execute automatically without user confirmation.
    case safe
    /// Requires user confirmation before execution.
    case confirm
    /// Destructive — requires explicit confirmation and a specified target.
    case destructive
}

// MARK: - Intervention Outcome

/// The result of executing a single intervention.
public enum InterventionOutcome: Sendable {
    /// Intervention succeeded. `reclaimedMB` is nil if reclamation is unmeasurable.
    case success(reclaimedMB: Int?)
    /// Intervention was skipped (e.g., already enabled, not applicable).
    case skipped(reason: String)
    /// Intervention failed with an error message.
    case error(message: String)
}

extension InterventionOutcome: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, reclaimedMB, reason, message
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .success(let reclaimedMB):
            try container.encode("success", forKey: .type)
            try container.encodeIfPresent(reclaimedMB, forKey: .reclaimedMB)
        case .skipped(let reason):
            try container.encode("skipped", forKey: .type)
            try container.encode(reason, forKey: .reason)
        case .error(let message):
            try container.encode("error", forKey: .type)
            try container.encode(message, forKey: .message)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "success":
            let reclaimedMB = try container.decodeIfPresent(Int.self, forKey: .reclaimedMB)
            self = .success(reclaimedMB: reclaimedMB)
        case "skipped":
            let reason = try container.decode(String.self, forKey: .reason)
            self = .skipped(reason: reason)
        case "error":
            let message = try container.decode(String.self, forKey: .message)
            self = .error(message: message)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container,
                                                    debugDescription: "Unknown outcome type: \(type)")
        }
    }
}

// MARK: - Execution Result

/// Immutable value pairing an intervention outcome with its metadata.
/// Returned from `execute` so each call carries its own result without shared mutable state.
public struct ExecutionResult: Sendable {
    /// The outcome of the intervention.
    public let outcome: InterventionOutcome

    /// Metadata produced during this execution (e.g., "prior_value", "estimate_mb").
    public let metadata: [String: String]

    public init(outcome: InterventionOutcome, metadata: [String: String] = [:]) {
        self.outcome = outcome
        self.metadata = metadata
    }
}

// MARK: - Intervention Protocol

/// A single intervention that can be evaluated and executed against the system.
public protocol Intervention {
    /// Human-readable name for this intervention (e.g., "pressure_trigger").
    var name: String { get }

    /// The safety tier of this intervention.
    var tier: InterventionTier { get }

    /// Check whether this intervention is applicable given the current memory state.
    func isApplicable(snapshot: MemorySnapshot) -> Bool

    /// Execute the intervention using the provided executor capabilities.
    /// Returns an immutable `ExecutionResult` containing both outcome and metadata.
    func execute(via executor: InterventionExecutor) async -> ExecutionResult
}
