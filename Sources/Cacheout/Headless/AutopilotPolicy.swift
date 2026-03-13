// AutopilotPolicy.swift
// Autopilot policy engine for the headless daemon.
//
// Evaluates rules from autopilot.json against daemon snapshots and executes
// Tier 1 interventions via InterventionEngine.

import CacheoutShared
import Foundation
import os

/// Autopilot policy engine that evaluates configured rules against daemon snapshots
/// and triggers Tier 1 interventions when conditions are met.
///
/// ## Evaluation model
/// Each rule specifies a `condition` (pressure tier, consecutive samples, optional
/// compression ratio window) and an `action` (T1 intervention name). When the
/// condition is satisfied, the action is executed via `InterventionEngine.run()`.
///
/// ## Safeguards
/// - Only Tier 1 actions are allowed (validated at config load).
/// - 5-minute cooldown per action after execution.
/// - Consecutive sample counting resets on condition change.
/// - XPC connection is held for the daemon lifetime; failures degrade gracefully.
///
/// ## Thread safety
/// This is an actor — all state access is serialized.
public actor AutopilotPolicy {

    // MARK: - Types

    /// A parsed autopilot rule ready for evaluation.
    public struct Rule: Sendable {
        /// The pressure tier that triggers this rule.
        let pressureTier: PressureTier
        /// Number of consecutive samples at or above the tier before firing.
        let consecutiveSamples: Int
        /// Optional: fire only when compression ratio average over window is below this.
        let compressionRatioBelow: Double?
        /// Window size for compression ratio averaging.
        let compressionRatioWindow: Int
        /// The canonical action name (e.g., "pressure-trigger").
        let action: String
    }

    /// Parsed and validated autopilot configuration.
    public struct Config: Sendable {
        let enabled: Bool
        let rules: [Rule]

        static let empty = Config(enabled: false, rules: [])
    }

    // MARK: - Constants

    /// Cooldown period after executing an action, per action name.
    private static let actionCooldownSeconds: TimeInterval = 300 // 5 minutes

    // MARK: - State

    private let logger = Logger(subsystem: "com.cacheout", category: "AutopilotPolicy")

    /// Current parsed config.
    private var config: Config = .empty

    /// Per-rule consecutive sample counter. Reset when condition becomes false.
    private var consecutiveCounts: [Int: Int] = [:]

    /// Per-action last execution timestamp (monotonic uptime).
    private var lastActionTime: [String: TimeInterval] = [:]

    /// XPC connection held for daemon lifetime.
    private var xpcConnection: NSXPCConnection?

    // MARK: - Init

    public init() {}

    // MARK: - Configuration

    /// Apply a new validated config. Resets per-rule counters.
    public func applyConfig(_ config: Config) {
        self.config = config
        consecutiveCounts = [:]
        logger.info("AutopilotPolicy config applied: enabled=\(config.enabled), \(config.rules.count) rules")
    }

    /// Parse an autopilot config from validated JSON data.
    ///
    /// Call only after `AutopilotConfigValidator.validate(data:)` returns no errors.
    /// Returns nil if parsing fails unexpectedly.
    public static func parseConfig(from data: Data) -> Config? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let enabled = json["enabled"] as? Bool ?? false
        let rulesJson = json["rules"] as? [[String: Any]] ?? []

        var rules: [Rule] = []
        for ruleJson in rulesJson {
            guard let action = ruleJson["action"] as? String,
                  let condition = ruleJson["condition"] as? [String: Any],
                  let tierStr = condition["pressure_tier"] as? String,
                  let tier = PressureTier.fromConfigValue(tierStr) else {
                continue
            }

            let consecutive = condition["consecutive_samples"] as? Int ?? 60
            let ratioBelow = condition["compression_ratio_below"] as? Double
            let ratioWindow = condition["compression_ratio_window"] as? Int ?? 10

            rules.append(Rule(
                pressureTier: tier,
                consecutiveSamples: consecutive,
                compressionRatioBelow: ratioBelow,
                compressionRatioWindow: ratioWindow,
                action: InterventionRegistry.canonicalize(action)
            ))
        }

        return Config(enabled: enabled, rules: rules)
    }

    // MARK: - Evaluation

    /// Evaluate all rules against the current sample history and execute triggered actions.
    ///
    /// Called from `DaemonMode.onSnapshot`. Results are logged locally only;
    /// they are NOT delivered via webhooks (that is WebhookAlerter's job for alerts).
    ///
    /// - Parameters:
    ///   - samples: Ordered sample history (oldest first).
    ///   - currentSnapshot: The most recent snapshot.
    public func evaluate(samples: [DaemonSnapshot], currentSnapshot: DaemonSnapshot) async {
        guard config.enabled else { return }

        let now = ProcessInfo.processInfo.systemUptime

        for (ruleIdx, rule) in config.rules.enumerated() {
            let conditionMet = checkCondition(
                rule: rule,
                samples: samples,
                currentSnapshot: currentSnapshot
            )

            if conditionMet {
                let count = (consecutiveCounts[ruleIdx] ?? 0) + 1
                consecutiveCounts[ruleIdx] = count

                if count >= rule.consecutiveSamples {
                    // Check cooldown
                    if let lastTime = lastActionTime[rule.action],
                       now - lastTime < Self.actionCooldownSeconds {
                        continue
                    }

                    // Execute the action
                    await executeAction(rule.action)
                    lastActionTime[rule.action] = ProcessInfo.processInfo.systemUptime
                    consecutiveCounts[ruleIdx] = 0
                }
            } else {
                consecutiveCounts[ruleIdx] = 0
            }
        }
    }

    // MARK: - Public Accessors

    /// Whether the current config has autopilot enabled.
    public var isEnabled: Bool {
        config.enabled
    }

    // MARK: - XPC Management

    /// Set the XPC connection for intervention execution.
    /// Called on startup and each config reload when helper availability changes.
    public func setXPCConnection(_ connection: NSXPCConnection?) {
        // Invalidate the old connection before replacing
        if let old = xpcConnection, old !== connection {
            old.invalidate()
        }
        self.xpcConnection = connection
    }

    /// Invalidate and release the XPC connection (e.g., during shutdown).
    public func invalidateXPC() {
        xpcConnection?.invalidate()
        xpcConnection = nil
    }

    // MARK: - Private

    /// Check whether a rule's condition is met for the current sample.
    private func checkCondition(
        rule: Rule,
        samples: [DaemonSnapshot],
        currentSnapshot: DaemonSnapshot
    ) -> Bool {
        // Check pressure tier
        let currentTier = currentPressureTier(from: currentSnapshot)
        guard currentTier.meetsOrExceeds(rule.pressureTier) else {
            return false
        }

        // Check optional compression ratio window.
        // Require the full configured window before evaluating to prevent
        // premature matching during startup with insufficient samples.
        if let ratioThreshold = rule.compressionRatioBelow {
            guard samples.count >= rule.compressionRatioWindow else { return false }
            let tail = samples.suffix(rule.compressionRatioWindow)
            let avgRatio = tail.reduce(0.0) { $0 + $1.stats.compressionRatio } / Double(tail.count)
            if avgRatio >= ratioThreshold {
                return false
            }
        }

        return true
    }

    /// Derive pressure tier from snapshot stats.
    private func currentPressureTier(from snapshot: DaemonSnapshot) -> PressureTier {
        let stats = snapshot.stats
        let availableMB = Double(stats.freePages + stats.inactivePages) * Double(stats.pageSize) / 1048576.0
        return PressureTier.from(pressureLevel: stats.pressureLevel, availableMB: availableMB)
    }

    /// Execute a T1 intervention by action name, logging the result.
    private func executeAction(_ actionName: String) async {
        guard let factory = InterventionRegistry.registry[actionName] else {
            logger.error("AutopilotPolicy: unknown action '\(actionName, privacy: .public)'")
            return
        }

        let intervention = factory(nil, nil)
        let executor = InterventionExecutor(
            xpcConnection: xpcConnection,
            dryRun: false,
            confirmed: true
        )

        let result = await InterventionEngine.run(intervention: intervention, via: executor)

        switch result.outcome {
        case .success(let reclaimedMB):
            let mbStr = reclaimedMB.map { "\($0)MB" } ?? "unknown"
            logger.info("AutopilotPolicy executed '\(actionName, privacy: .public)': success (reclaimed: \(mbStr, privacy: .public))")
        case .skipped(let reason):
            logger.info("AutopilotPolicy executed '\(actionName, privacy: .public)': skipped (\(reason, privacy: .public))")
        case .error(let message):
            logger.warning("AutopilotPolicy executed '\(actionName, privacy: .public)': error (\(message, privacy: .public))")
        }
    }
}

// MARK: - PressureTier Comparison

extension PressureTier {
    /// Ordering for comparison: normal < elevated < warning < critical.
    fileprivate var order: Int {
        switch self {
        case .normal: return 0
        case .elevated: return 1
        case .warning: return 2
        case .critical: return 3
        }
    }

    /// Whether this tier meets or exceeds the given tier.
    fileprivate func meetsOrExceeds(_ other: PressureTier) -> Bool {
        self.order >= other.order
    }
}
