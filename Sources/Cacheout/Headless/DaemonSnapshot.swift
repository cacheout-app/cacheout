// DaemonSnapshot.swift
// Snapshot model for the headless daemon's sampling loop.

import CacheoutShared
import Foundation

/// A timestamped wrapper around `SystemStatsDTO` used by the daemon's sampling loop.
///
/// Provides a computed `ageMs` property for staleness checks and alert generation.
public struct DaemonSnapshot: Sendable {
    /// The system stats captured at this point in time.
    public let stats: SystemStatsDTO

    /// When this snapshot was captured (wall-clock reference for age computation).
    public let timestamp: Date

    /// Age of this snapshot in milliseconds relative to the current time.
    public var ageMs: Int {
        Int(Date().timeIntervalSince(timestamp) * 1000)
    }

    public init(stats: SystemStatsDTO, timestamp: Date = Date()) {
        self.stats = stats
        self.timestamp = timestamp
    }
}
