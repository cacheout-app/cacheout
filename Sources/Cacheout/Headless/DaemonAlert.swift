// DaemonAlert.swift
// Shared alert schema for the headless daemon.

import Foundation

/// Alert codes emitted by the daemon's alert system.
///
/// Two layers produce alerts:
/// - **AlertEvaluator**: sample-derived alerts (PRESSURE_WARN, PRESSURE_CRITICAL, SWAP_HIGH, COMPRESSOR_DEGRADED)
/// - **DaemonMode**: daemon-owned alerts (HELPER_UNAVAILABLE, DAEMON_RESTART)
public enum DaemonAlertCode: String, Codable, Sendable {
    // Sample-derived (AlertEvaluator)
    case pressureWarn = "PRESSURE_WARN"
    case pressureCritical = "PRESSURE_CRITICAL"
    case swapHigh = "SWAP_HIGH"
    case compressorDegraded = "COMPRESSOR_DEGRADED"

    // Daemon-owned (DaemonMode)
    case helperUnavailable = "HELPER_UNAVAILABLE"
    case daemonRestart = "DAEMON_RESTART"
}

/// Alert severity levels.
public enum DaemonAlertSeverity: String, Codable, Sendable {
    case warning
    case emergency
}

/// A single daemon alert with snake_case JSON encoding.
///
/// Snapshot-derived alerts populate `snapshotAgeMs` and `pressureTier`.
/// Non-snapshot alerts (HELPER_UNAVAILABLE, DAEMON_RESTART) set both to `nil`.
public struct DaemonAlert: Codable, Sendable {
    /// The alert code identifying this alert type.
    public let code: DaemonAlertCode

    /// Severity level of this alert.
    public let severity: DaemonAlertSeverity

    /// Human-readable description of the alert condition.
    public let message: String

    /// Age of the snapshot that triggered this alert, in milliseconds.
    /// Nil for non-snapshot alerts.
    public let snapshotAgeMs: Int?

    /// Pressure tier at the time of the snapshot.
    /// Nil for non-snapshot alerts.
    public let pressureTier: String?

    /// When this alert was generated.
    public let timestamp: Date

    public init(
        code: DaemonAlertCode,
        severity: DaemonAlertSeverity,
        message: String,
        snapshotAgeMs: Int? = nil,
        pressureTier: String? = nil,
        timestamp: Date = Date()
    ) {
        self.code = code
        self.severity = severity
        self.message = message
        self.snapshotAgeMs = snapshotAgeMs
        self.pressureTier = pressureTier
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey {
        case code
        case severity
        case message
        case snapshotAgeMs = "snapshot_age_ms"
        case pressureTier = "pressure_tier"
        case timestamp
    }

    /// Custom encoding to ensure nullable fields (`snapshot_age_ms`, `pressure_tier`)
    /// are always present as `null` rather than omitted, providing a stable JSON shape.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(severity, forKey: .severity)
        try container.encode(message, forKey: .message)
        try container.encode(snapshotAgeMs, forKey: .snapshotAgeMs)
        try container.encode(pressureTier, forKey: .pressureTier)
        try container.encode(timestamp, forKey: .timestamp)
    }
}
