// InterventionRegistry.swift
// Shared registry of known interventions, extracted from CLIHandler for reuse
// by the daemon's autopilot engine and the CLI.

import Foundation

/// Central registry of known intervention names and their factories.
///
/// Keys use hyphenated CLI names (e.g., "pressure-trigger"). Internal intervention
/// names use underscores (e.g., "pressure_trigger"). Both forms are accepted
/// via normalization.
///
/// ## Autopilot actions
///
/// Only Tier 1 (safe) interventions are eligible for autopilot execution:
/// `pressure-trigger` and `reduce-transparency`. Tier 2/3 interventions are
/// rejected at config load time.
public enum InterventionRegistry {

    /// Intervention names that require --target-pid and --target-name.
    public static let signalInterventionNames: Set<String> = [
        "sigterm-cascade", "sigstop-freeze",
    ]

    /// Intervention names that accept --target-pid (but not --target-name).
    public static let pidAcceptingNames: Set<String> = [
        "jetsam-limit", "jetsam-hwm",
    ]

    /// Full registry: maps canonical hyphenated names to intervention factories.
    /// Factories accept optional (targetPID, targetName).
    public static let registry: [String: (pid_t?, String?) -> any Intervention] = [
        // Tier 1 (safe)
        "pressure-trigger": { _, _ in PressureTrigger() },
        "reduce-transparency": { _, _ in ReduceTransparency() },
        // Tier 2 (confirm) -- canonical names + epic naming aliases
        "jetsam-limit": { pid, _ in JetsamHWM(targetPID: pid) },
        "jetsam-hwm": { pid, _ in JetsamHWM(targetPID: pid) },
        "flush-windowserver": { _, _ in WindowServerFlush() },
        "windowserver-flush": { _, _ in WindowServerFlush() },
        "compressor-tuning": { _, _ in CompressorTuning() },
        "delete-snapshot": { _, _ in SnapshotCleanup() },
        "snapshot-cleanup": { _, _ in SnapshotCleanup() },
        // Tier 3 (destructive)
        "sigterm-cascade": { pid, name in
            SIGTERMCascade(targetPID: pid ?? 0, targetName: name ?? "")
        },
        "sigstop-freeze": { pid, name in
            SIGSTOPFreeze(targetPID: pid ?? 0, targetName: name ?? "")
        },
        "sleep-image-delete": { _, _ in SleepImageDelete() },
    ]

    /// Actions eligible for autopilot execution (Tier 1 only).
    /// Config validation rejects any action not in this set.
    public static let autopilotActions: Set<String> = [
        "pressure-trigger",
        "reduce-transparency",
    ]

    /// Normalize an intervention name: replace underscores with hyphens.
    public static func canonicalize(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: "-")
    }
}
