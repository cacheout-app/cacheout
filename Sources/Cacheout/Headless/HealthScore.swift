// HealthScore.swift
// Canonical health score formula for the headless daemon.

import Foundation

/// Computes a health score from system memory metrics.
///
/// The formula is deterministic and identical in both Swift (daemon/CLI) and
/// Python (MCP server). Score range is [0, 100]; -1 is the sentinel for "no data".
///
/// ## Formula
/// ```
/// base = 100
/// if pressure_tier == "critical": base -= 50
/// elif pressure_tier == "warn": base -= 25
/// swap_penalty = min(50, int(swap_used_percent / 2))
/// compressor_penalty = min(30, max(0, int((3.0 - compression_ratio) * 10)))
/// score = max(0, base - swap_penalty - compressor_penalty)
/// ```
public enum HealthScore {

    /// Sentinel value indicating no data is available to compute a score.
    public static let noData: Int = -1

    /// Compute health score from the given metrics.
    ///
    /// - Parameters:
    ///   - pressureTier: The current pressure tier string ("normal", "elevated", "warning", "critical").
    ///   - swapUsedPercent: Swap usage as a percentage (0-100).
    ///   - compressionRatio: Compressor compression ratio (logical/physical, >1 = effective).
    /// - Returns: An integer score in [0, 100].
    public static func compute(
        pressureTier: String,
        swapUsedPercent: Double,
        compressionRatio: Double
    ) -> Int {
        var base = 100
        if pressureTier == "critical" {
            base -= 50
        } else if pressureTier == "warning" || pressureTier == "warn" {
            base -= 25
        }

        let swapPenalty = min(50, Int(swapUsedPercent / 2))
        let compressorPenalty = min(30, max(0, Int((3.0 - compressionRatio) * 10)))

        return max(0, base - swapPenalty - compressorPenalty)
    }
}
