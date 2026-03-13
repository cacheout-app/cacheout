// ZoneHealthDTO.swift
// Data transfer object for kernel zone health information.
// Wire format: sizes in bytes.

import Foundation

/// Health status of a single kernel memory zone.
///
/// Returned by `getKernelZoneHealth` as part of a `[ZoneHealthDTO]` array.
/// Only zones exceeding 50% utilization are reported.
public struct ZoneHealthDTO: Codable, Sendable {

    /// Kernel zone name (e.g. "vm_map_entry", "ipc_port").
    public let name: String

    /// Current size of the zone in bytes.
    public let currentSizeBytes: UInt64

    /// Maximum configured size of the zone in bytes.
    public let maxSizeBytes: UInt64

    /// Utilization as a fraction (0.0 to 1.0).
    public let percentUsed: Double

    /// Severity classification: "ELEVATED" (>50%), "WARNING" (>85%), "CRITICAL" (>95%).
    public let severity: String

    // MARK: - Initializer

    public init(
        name: String,
        currentSizeBytes: UInt64,
        maxSizeBytes: UInt64,
        percentUsed: Double,
        severity: String
    ) {
        self.name = name
        self.currentSizeBytes = currentSizeBytes
        self.maxSizeBytes = maxSizeBytes
        self.percentUsed = percentUsed
        self.severity = severity
    }
}
