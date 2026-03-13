// AlertEvaluator.swift
// Sample-derived alert evaluation for the headless daemon.

import CacheoutShared
import Foundation

/// Evaluates active alerts from sample history.
///
/// This evaluator produces alerts based on consecutive sample patterns.
/// It does NOT manage daemon-owned alerts like HELPER_UNAVAILABLE --
/// those are set/cleared by `DaemonMode` directly.
///
/// No cooldown logic here; that is the responsibility of `WebhookAlerter` (task .2).
///
/// ## Alert thresholds
///
/// | Code                 | Severity  | Trigger                                    |
/// |----------------------|-----------|--------------------------------------------|
/// | PRESSURE_WARN        | warning   | pressure >= warn, 30 consecutive samples   |
/// | PRESSURE_CRITICAL    | emergency | pressure = critical, 10 consecutive        |
/// | SWAP_HIGH            | warning   | swap% > 75%, 30 consecutive               |
/// | COMPRESSOR_DEGRADED  | warning   | ratio < 2.0 avg over 30 samples           |
public final class AlertEvaluator: Sendable {

    /// Number of consecutive samples required for non-critical alerts.
    private static let standardWindow = 30

    /// Number of consecutive samples required for critical pressure alert.
    private static let criticalWindow = 10

    /// Swap usage threshold as a percentage.
    private static let swapHighThresholdPercent: Double = 75.0

    /// Compression ratio below which the compressor is considered degraded.
    private static let compressorDegradedThreshold: Double = 2.0

    public init() {}

    /// Evaluate active alerts from the given sample history.
    ///
    /// The samples should be ordered oldest-first. Only the tail of the array
    /// (most recent samples) is examined for consecutive-sample conditions.
    ///
    /// - Parameters:
    ///   - samples: Ordered sample history (oldest first).
    ///   - currentSnapshot: The most recent daemon snapshot for age/tier info.
    /// - Returns: Array of currently active alerts (may be empty).
    public func evaluate(
        samples: [DaemonSnapshot],
        currentSnapshot: DaemonSnapshot?
    ) -> [DaemonAlert] {
        guard !samples.isEmpty else { return [] }

        var alerts: [DaemonAlert] = []
        let snapshotAgeMs = currentSnapshot?.ageMs
        let currentTierRaw = currentSnapshot.map { pressureTier(from: $0).rawValue }

        // PRESSURE_CRITICAL: 10 consecutive critical samples
        if checkConsecutiveTail(samples, count: Self.criticalWindow, predicate: { snapshot in
            pressureTier(from: snapshot) == .critical
        }) {
            alerts.append(DaemonAlert(
                code: .pressureCritical,
                severity: .emergency,
                message: "Memory pressure at critical level for \(Self.criticalWindow) consecutive samples",
                snapshotAgeMs: snapshotAgeMs,
                pressureTier: currentTierRaw
            ))
        }
        // PRESSURE_WARN: 30 consecutive warn+ samples (only if not already critical)
        else if checkConsecutiveTail(samples, count: Self.standardWindow, predicate: { snapshot in
            let tier = pressureTier(from: snapshot)
            return tier == .warning || tier == .critical
        }) {
            alerts.append(DaemonAlert(
                code: .pressureWarn,
                severity: .warning,
                message: "Memory pressure at warning level or above for \(Self.standardWindow) consecutive samples",
                snapshotAgeMs: snapshotAgeMs,
                pressureTier: currentTierRaw
            ))
        }

        // SWAP_HIGH: 30 consecutive samples with swap > 75%
        if checkConsecutiveTail(samples, count: Self.standardWindow, predicate: { snapshot in
            let swapPercent = swapUsedPercent(from: snapshot)
            return swapPercent > Self.swapHighThresholdPercent
        }) {
            alerts.append(DaemonAlert(
                code: .swapHigh,
                severity: .warning,
                message: "Swap usage above \(Int(Self.swapHighThresholdPercent))% for \(Self.standardWindow) consecutive samples",
                snapshotAgeMs: snapshotAgeMs,
                pressureTier: currentTierRaw
            ))
        }

        // COMPRESSOR_DEGRADED: average ratio < 2.0 over last 30 samples
        if samples.count >= Self.standardWindow {
            let tail = samples.suffix(Self.standardWindow)
            let avgRatio = tail.reduce(0.0) { $0 + $1.stats.compressionRatio } / Double(tail.count)
            if avgRatio < Self.compressorDegradedThreshold {
                alerts.append(DaemonAlert(
                    code: .compressorDegraded,
                    severity: .warning,
                    message: "Compressor ratio degraded (avg \(String(format: "%.2f", avgRatio)) over \(Self.standardWindow) samples)",
                    snapshotAgeMs: snapshotAgeMs,
                    pressureTier: currentTierRaw
                ))
            }
        }

        return alerts
    }

    // MARK: - Private Helpers

    /// Check whether the last `count` samples all satisfy the predicate.
    private func checkConsecutiveTail(
        _ samples: [DaemonSnapshot],
        count: Int,
        predicate: (DaemonSnapshot) -> Bool
    ) -> Bool {
        guard samples.count >= count else { return false }
        let tail = samples.suffix(count)
        return tail.allSatisfy(predicate)
    }

    /// Derive a PressureTier enum value from a daemon snapshot's stats.
    /// Using the enum directly avoids raw-string mismatches between "warn"/"warning".
    private func pressureTier(from snapshot: DaemonSnapshot) -> PressureTier {
        let stats = snapshot.stats
        let availableMB = Double(stats.freePages + stats.inactivePages) * Double(stats.pageSize) / 1048576.0
        return PressureTier.from(pressureLevel: stats.pressureLevel, availableMB: availableMB)
    }

    /// Compute swap usage percentage from a daemon snapshot.
    private func swapUsedPercent(from snapshot: DaemonSnapshot) -> Double {
        let stats = snapshot.stats
        guard stats.swapTotalBytes > 0 else { return 0.0 }
        return Double(stats.swapUsedBytes) / Double(stats.swapTotalBytes) * 100.0
    }
}
