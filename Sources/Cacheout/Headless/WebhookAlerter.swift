// WebhookAlerter.swift
// Webhook alerting with per-code coalescing and cooldown for the headless daemon.

import Foundation
import os

/// Delivers daemon alerts to a configured webhook endpoint with per-alert-code
/// coalescing and cooldown.
///
/// ## Coalescing model
/// - Max 1 in-flight delivery chain per alert code.
/// - While a delivery is in-flight for a code, new alerts with the same code are dropped.
/// - Failed delivery clears the in-flight flag (allowing retry on next evaluation).
///
/// ## Cooldown
/// - 5-minute post-delivery cooldown per alert code.
/// - After a successful delivery, no new delivery for that code starts until cooldown expires.
///
/// ## Backoff (normal delivery)
/// - Retries: up to 5 attempts with exponential backoff 1s -> 2s -> 4s -> 8s -> 16s (capped at 60s).
/// - PII: no personally identifiable information in webhook payloads.
///
/// ## Urgent delivery (`deliverUrgent`)
/// - 1 attempt, 3-second timeout, 5-second total budget.
/// - Used for DAEMON_RESTART alerts.
///
/// ## Shutdown
/// - 3-second maximum for in-flight delivery completion.
///
/// ## Thread safety
/// This is an actor — all state access is serialized.
public actor WebhookAlerter {

    // MARK: - Types

    /// Webhook configuration parsed from autopilot.json.
    public struct WebhookConfig: Sendable {
        public let url: URL
        public let format: String
        public let timeoutSeconds: Int

        public init(url: URL, format: String = "generic", timeoutSeconds: Int = 10) {
            self.url = url
            self.format = format
            self.timeoutSeconds = timeoutSeconds
        }
    }

    /// Tracks per-code delivery state.
    private struct CodeState {
        var inFlight: Bool = false
        var lastDeliveredAt: TimeInterval? = nil
    }

    // MARK: - Constants

    /// Post-delivery cooldown per alert code.
    private static let cooldownSeconds: TimeInterval = 300 // 5 minutes

    /// Max retry attempts for normal delivery.
    private static let maxRetries = 5

    /// Initial backoff delay for retries.
    private static let initialBackoffSeconds: TimeInterval = 1.0

    /// Maximum backoff delay.
    private static let maxBackoffSeconds: TimeInterval = 60.0

    /// Urgent delivery timeout per attempt.
    private static let urgentTimeoutSeconds: TimeInterval = 3.0

    /// Urgent delivery total budget.
    private static let urgentBudgetSeconds: TimeInterval = 5.0

    /// Shutdown flush budget.
    private static let shutdownBudgetSeconds: TimeInterval = 3.0

    // MARK: - State

    private let logger = Logger(subsystem: "com.cacheout", category: "WebhookAlerter")

    /// Current webhook config. Nil if no webhook is configured.
    private var webhookConfig: WebhookConfig?

    /// Per-code delivery state.
    private var codeStates: [DaemonAlertCode: CodeState] = [:]

    /// Active delivery tasks (for shutdown cancellation).
    private var deliveryTasks: [DaemonAlertCode: Task<Void, Never>] = [:]

    /// Generation counter incremented on endpoint-changing reloads.
    /// Delivery completion callbacks check this to avoid corrupting state
    /// from stale cancelled tasks that finish after a config reload.
    private var configGeneration: Int = 0

    /// Shared URLSession for webhook deliveries.
    private let session: URLSession

    // MARK: - Init

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Configuration

    /// Apply webhook config.
    ///
    /// Preserves cooldown and in-flight state when the endpoint is unchanged
    /// (same URL and format). This ensures SIGHUP reloads that only change
    /// non-webhook fields don't reset delivery cooldowns. State is fully
    /// reset when the endpoint changes or webhooks are disabled.
    public func applyConfig(webhook: WebhookConfig?) {
        let endpointChanged = !isSameEndpoint(old: webhookConfig, new: webhook)
        self.webhookConfig = webhook

        if endpointChanged {
            configGeneration += 1
            codeStates = [:]
            for (_, task) in deliveryTasks {
                task.cancel()
            }
            deliveryTasks = [:]
        }

        if let webhook {
            logger.info("WebhookAlerter configured: url=\(webhook.url.absoluteString, privacy: .public) (state \(endpointChanged ? "reset" : "preserved", privacy: .public))")
        } else {
            logger.info("WebhookAlerter: no webhook configured")
        }
    }

    /// Check whether two webhook configs point to the same endpoint.
    private func isSameEndpoint(old: WebhookConfig?, new: WebhookConfig?) -> Bool {
        guard let old, let new else {
            // Both nil = same (no endpoint), one nil = different
            return old == nil && new == nil
        }
        return old.url == new.url && old.format == new.format
    }

    // MARK: - Alert Processing

    /// Process a batch of active alerts. Starts delivery for any new alert codes
    /// that are not in-flight and not in cooldown.
    public func processAlerts(_ alerts: [DaemonAlert]) {
        guard webhookConfig != nil else { return }

        let now = ProcessInfo.processInfo.systemUptime

        for alert in alerts {
            let code = alert.code
            var state = codeStates[code] ?? CodeState()

            // Skip if already in-flight
            if state.inFlight { continue }

            // Skip if in cooldown
            if let lastTime = state.lastDeliveredAt,
               now - lastTime < Self.cooldownSeconds {
                continue
            }

            // Start delivery
            state.inFlight = true
            codeStates[code] = state

            let generation = configGeneration
            let task = Task { [weak self] in
                guard let self else { return }
                await self.deliverWithRetry(alert: alert, generation: generation)
            }
            deliveryTasks[code] = task
        }
    }

    // MARK: - Urgent Delivery

    /// Deliver an urgent alert with a single attempt and tight timeout.
    /// Used for DAEMON_RESTART. Does not check cooldown.
    public func deliverUrgent(alert: DaemonAlert) async {
        guard let config = webhookConfig else { return }

        let budgetDeadline = ProcessInfo.processInfo.systemUptime + Self.urgentBudgetSeconds

        do {
            let request = buildRequest(for: alert, config: config, timeout: Self.urgentTimeoutSeconds)
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if (200..<300).contains(httpResponse.statusCode) {
                    logger.info("WebhookAlerter urgent delivery succeeded for \(alert.code.rawValue, privacy: .public)")
                } else {
                    logger.warning("WebhookAlerter urgent delivery failed for \(alert.code.rawValue, privacy: .public): HTTP \(httpResponse.statusCode)")
                }
            }
        } catch {
            let remaining = budgetDeadline - ProcessInfo.processInfo.systemUptime
            logger.warning("WebhookAlerter urgent delivery failed for \(alert.code.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public) (remaining budget: \(String(format: "%.1f", remaining))s)")
        }
    }

    // MARK: - Shutdown

    /// Flush pending deliveries with a 3-second budget.
    public func flush() async {
        guard !deliveryTasks.isEmpty else { return }
        logger.info("WebhookAlerter flushing (\(self.deliveryTasks.count) active deliveries)")

        // Wait up to 3s for active deliveries to complete
        let deadline = Date().addingTimeInterval(Self.shutdownBudgetSeconds)
        for (code, task) in deliveryTasks {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                task.cancel()
                continue
            }
            // Race: wait for task vs timeout
            let result = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await task.value
                    return true
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(remaining))
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            if !result {
                logger.warning("WebhookAlerter flush timed out for \(code.rawValue, privacy: .public)")
                task.cancel()
            }
        }
        deliveryTasks = [:]
    }

    // MARK: - Private

    /// Deliver an alert with exponential backoff retry.
    ///
    /// The `generation` parameter ties this delivery to a specific config epoch.
    /// If the config generation has changed by the time delivery completes
    /// (due to an endpoint-changing reload), the completion is silently dropped
    /// to avoid corrupting the new config epoch's state.
    private func deliverWithRetry(alert: DaemonAlert, generation: Int) async {
        guard let config = webhookConfig else {
            markDeliveryComplete(code: alert.code, generation: generation, success: false)
            return
        }

        var backoff = Self.initialBackoffSeconds
        for attempt in 0..<Self.maxRetries {
            if Task.isCancelled { break }

            do {
                let request = buildRequest(for: alert, config: config, timeout: TimeInterval(config.timeoutSeconds))
                let (_, response) = try await session.data(for: request)
                if let httpResponse = response as? HTTPURLResponse,
                   (200..<300).contains(httpResponse.statusCode) {
                    logger.info("WebhookAlerter delivered \(alert.code.rawValue, privacy: .public) (attempt \(attempt + 1))")
                    markDeliveryComplete(code: alert.code, generation: generation, success: true)
                    return
                }
                // Non-2xx: retry
                if let httpResponse = response as? HTTPURLResponse {
                    logger.warning("WebhookAlerter delivery attempt \(attempt + 1) for \(alert.code.rawValue, privacy: .public): HTTP \(httpResponse.statusCode)")
                }
            } catch {
                logger.warning("WebhookAlerter delivery attempt \(attempt + 1) for \(alert.code.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }

            // Backoff before retry
            if attempt < Self.maxRetries - 1 {
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, Self.maxBackoffSeconds)
            }
        }

        logger.warning("WebhookAlerter exhausted retries for \(alert.code.rawValue, privacy: .public)")
        markDeliveryComplete(code: alert.code, generation: generation, success: false)
    }

    /// Mark delivery as complete and update per-code state.
    ///
    /// Only mutates state if the generation matches the current config epoch.
    /// Stale completions from cancelled tasks after an endpoint-changing reload
    /// are silently dropped.
    private func markDeliveryComplete(code: DaemonAlertCode, generation: Int, success: Bool) {
        // Drop stale completions from a previous config epoch
        guard generation == configGeneration else {
            logger.info("WebhookAlerter: dropping stale completion for \(code.rawValue, privacy: .public) (gen \(generation) != current \(self.configGeneration))")
            return
        }

        var state = codeStates[code] ?? CodeState()
        state.inFlight = false
        if success {
            state.lastDeliveredAt = ProcessInfo.processInfo.systemUptime
        }
        codeStates[code] = state
        deliveryTasks[code] = nil
    }

    /// Build an HTTP request for a webhook delivery.
    private nonisolated func buildRequest(
        for alert: DaemonAlert,
        config: WebhookConfig,
        timeout: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: config.url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CacheOut-Daemon/1.0", forHTTPHeaderField: "User-Agent")

        // Build payload without PII
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(alert) {
            request.httpBody = data
        }

        return request
    }
}

/// Parse webhook config from the autopilot JSON.
extension WebhookAlerter.WebhookConfig {
    /// Parse from the `webhook` section of autopilot.json.
    /// Returns nil if the section is absent or invalid.
    public static func parse(from json: [String: Any]) -> WebhookAlerter.WebhookConfig? {
        guard let webhook = json["webhook"] as? [String: Any],
              let urlStr = webhook["url"] as? String,
              let url = URL(string: urlStr) else {
            return nil
        }
        let format = webhook["format"] as? String ?? "generic"
        let timeout = webhook["timeout_s"] as? Int ?? 10
        return WebhookAlerter.WebhookConfig(url: url, format: format, timeoutSeconds: timeout)
    }
}
