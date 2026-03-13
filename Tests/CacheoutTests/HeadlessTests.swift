import XCTest
@testable import Cacheout
@testable import CacheoutShared

// MARK: - Test Helpers

/// Build a SystemStatsDTO with customizable fields for headless daemon tests.
private func makeStats(
    timestamp: Date = Date(),
    freePages: UInt64 = 100_000,
    activePages: UInt64 = 200_000,
    inactivePages: UInt64 = 50_000,
    wiredPages: UInt64 = 80_000,
    compressorPageCount: UInt64 = 30_000,
    compressedBytes: UInt64 = 1_000_000,
    compressorBytesUsed: UInt64 = 500_000,
    compressionRatio: Double = 2.0,
    pageSize: UInt64 = 16384,
    swapUsedBytes: UInt64 = 0,
    swapTotalBytes: UInt64 = 4_000_000_000,
    pressureLevel: Int32 = 0
) -> SystemStatsDTO {
    SystemStatsDTO(
        timestamp: timestamp,
        freePages: freePages,
        activePages: activePages,
        inactivePages: inactivePages,
        wiredPages: wiredPages,
        compressorPageCount: compressorPageCount,
        compressedBytes: compressedBytes,
        compressorBytesUsed: compressorBytesUsed,
        compressionRatio: compressionRatio,
        pageSize: pageSize,
        purgeableCount: 100,
        externalPages: 200,
        internalPages: 300,
        compressions: 1000,
        decompressions: 500,
        pageins: 0,
        pageouts: 0,
        swapUsedBytes: swapUsedBytes,
        swapTotalBytes: swapTotalBytes,
        pressureLevel: pressureLevel,
        memoryTier: "moderate",
        totalPhysicalMemory: 16 * 1024 * 1024 * 1024
    )
}

private func makeSnapshot(
    timestamp: Date = Date(),
    pressureLevel: Int32 = 0,
    swapUsedBytes: UInt64 = 0,
    swapTotalBytes: UInt64 = 4_000_000_000,
    compressionRatio: Double = 2.0,
    freePages: UInt64 = 100_000,
    inactivePages: UInt64 = 50_000
) -> DaemonSnapshot {
    DaemonSnapshot(
        stats: makeStats(
            timestamp: timestamp,
            freePages: freePages,
            inactivePages: inactivePages,
            compressionRatio: compressionRatio,
            swapUsedBytes: swapUsedBytes,
            swapTotalBytes: swapTotalBytes,
            pressureLevel: pressureLevel
        ),
        timestamp: timestamp
    )
}

// MARK: - HealthScore Tests

final class HealthScoreTests: XCTestCase {

    func testPerfectHealth() {
        let score = HealthScore.compute(
            pressureTier: "normal",
            swapUsedPercent: 0,
            compressionRatio: 3.0
        )
        XCTAssertEqual(score, 100)
    }

    func testNoDataSentinel() {
        XCTAssertEqual(HealthScore.noData, -1)
    }

    func testCriticalPressurePenalty() {
        let score = HealthScore.compute(
            pressureTier: "critical",
            swapUsedPercent: 0,
            compressionRatio: 3.0
        )
        XCTAssertEqual(score, 50, "Critical pressure should subtract 50 from base")
    }

    func testWarningPressurePenalty() {
        let score = HealthScore.compute(
            pressureTier: "warning",
            swapUsedPercent: 0,
            compressionRatio: 3.0
        )
        XCTAssertEqual(score, 75, "Warning pressure should subtract 25 from base")
    }

    func testWarnAlias() {
        let score = HealthScore.compute(
            pressureTier: "warn",
            swapUsedPercent: 0,
            compressionRatio: 3.0
        )
        XCTAssertEqual(score, 75, "'warn' should be treated the same as 'warning'")
    }

    func testSwapPenalty() {
        // 80% swap → penalty = min(50, 80/2) = 40
        let score = HealthScore.compute(
            pressureTier: "normal",
            swapUsedPercent: 80,
            compressionRatio: 3.0
        )
        XCTAssertEqual(score, 60, "80% swap should subtract 40")
    }

    func testSwapPenaltyCapped() {
        // 120% (shouldn't happen but test cap) → penalty = min(50, 60) = 50
        let score = HealthScore.compute(
            pressureTier: "normal",
            swapUsedPercent: 120,
            compressionRatio: 3.0
        )
        XCTAssertEqual(score, 50, "Swap penalty should cap at 50")
    }

    func testCompressorPenalty() {
        // ratio=1.0 → penalty = min(30, max(0, (3.0-1.0)*10)) = min(30, 20) = 20
        let score = HealthScore.compute(
            pressureTier: "normal",
            swapUsedPercent: 0,
            compressionRatio: 1.0
        )
        XCTAssertEqual(score, 80, "Ratio 1.0 should subtract 20")
    }

    func testCompressorPenaltyCapped() {
        // ratio=0 → penalty = min(30, max(0, 30)) = 30
        let score = HealthScore.compute(
            pressureTier: "normal",
            swapUsedPercent: 0,
            compressionRatio: 0
        )
        XCTAssertEqual(score, 70, "Compressor penalty should cap at 30")
    }

    func testAllPenaltiesCombined() {
        // critical(-50) + 80% swap(-40) + ratio 0(-30) = base 100 - 120 → clamped to 0
        let score = HealthScore.compute(
            pressureTier: "critical",
            swapUsedPercent: 80,
            compressionRatio: 0
        )
        XCTAssertEqual(score, 0, "Combined penalties should clamp to 0")
    }

    func testScoreNeverNegative() {
        let score = HealthScore.compute(
            pressureTier: "critical",
            swapUsedPercent: 100,
            compressionRatio: 0
        )
        XCTAssertGreaterThanOrEqual(score, 0)
    }
}

// MARK: - AlertEvaluator Tests

final class AlertEvaluatorTests: XCTestCase {

    let evaluator = AlertEvaluator()

    func testNoAlertsWithNoSamples() {
        let alerts = evaluator.evaluate(samples: [], currentSnapshot: nil)
        XCTAssertTrue(alerts.isEmpty)
    }

    func testNoAlertsUnderThresholdWindow() {
        // 5 critical samples (need 10 for PRESSURE_CRITICAL)
        let samples = (0..<5).map { i in
            makeSnapshot(
                timestamp: Date().addingTimeInterval(Double(i)),
                pressureLevel: 4 // critical
            )
        }
        let alerts = evaluator.evaluate(samples: samples, currentSnapshot: samples.last)
        XCTAssertTrue(alerts.isEmpty, "5 critical samples should not trigger alert (need 10)")
    }

    func testPressureCriticalAlert() {
        // 10 consecutive critical samples
        let samples = (0..<10).map { i in
            makeSnapshot(
                timestamp: Date().addingTimeInterval(Double(i)),
                pressureLevel: 4, // triggers critical
                freePages: 10,
                inactivePages: 10
            )
        }
        let alerts = evaluator.evaluate(samples: samples, currentSnapshot: samples.last)
        let critical = alerts.filter { $0.code == .pressureCritical }
        XCTAssertEqual(critical.count, 1, "10 consecutive critical samples should trigger PRESSURE_CRITICAL")
        XCTAssertEqual(critical.first?.severity, .emergency)
    }

    func testPressureWarnAlert() {
        // 30 consecutive warning samples (not critical)
        let samples = (0..<30).map { i in
            makeSnapshot(
                timestamp: Date().addingTimeInterval(Double(i)),
                pressureLevel: 2, // triggers warning
                freePages: 50_000, // ~800MB available, above 512 critical threshold
                inactivePages: 50_000
            )
        }
        let alerts = evaluator.evaluate(samples: samples, currentSnapshot: samples.last)
        let warn = alerts.filter { $0.code == .pressureWarn }
        XCTAssertEqual(warn.count, 1, "30 consecutive warning samples should trigger PRESSURE_WARN")
        XCTAssertEqual(warn.first?.severity, .warning)
    }

    func testSwapHighAlert() {
        // 30 consecutive samples with swap > 75%
        let total: UInt64 = 4_000_000_000
        let used: UInt64 = 3_200_000_000 // 80%
        let samples = (0..<30).map { i in
            makeSnapshot(
                timestamp: Date().addingTimeInterval(Double(i)),
                swapUsedBytes: used,
                swapTotalBytes: total
            )
        }
        let alerts = evaluator.evaluate(samples: samples, currentSnapshot: samples.last)
        let swap = alerts.filter { $0.code == .swapHigh }
        XCTAssertEqual(swap.count, 1, "30 consecutive high-swap samples should trigger SWAP_HIGH")
    }

    func testCompressorDegradedAlert() {
        // 30 consecutive samples with ratio < 2.0
        let samples = (0..<30).map { i in
            makeSnapshot(
                timestamp: Date().addingTimeInterval(Double(i)),
                compressionRatio: 1.5
            )
        }
        let alerts = evaluator.evaluate(samples: samples, currentSnapshot: samples.last)
        let degraded = alerts.filter { $0.code == .compressorDegraded }
        XCTAssertEqual(degraded.count, 1, "30 consecutive low-ratio samples should trigger COMPRESSOR_DEGRADED")
    }

    func testCriticalSuppressesWarning() {
        // 30+ critical samples → PRESSURE_CRITICAL should fire, not PRESSURE_WARN
        let samples = (0..<30).map { i in
            makeSnapshot(
                timestamp: Date().addingTimeInterval(Double(i)),
                pressureLevel: 4,
                freePages: 10,
                inactivePages: 10
            )
        }
        let alerts = evaluator.evaluate(samples: samples, currentSnapshot: samples.last)
        XCTAssertTrue(alerts.contains { $0.code == .pressureCritical })
        XCTAssertFalse(alerts.contains { $0.code == .pressureWarn },
                      "PRESSURE_CRITICAL should suppress PRESSURE_WARN")
    }

    func testAlertSnapshotFields() {
        let samples = (0..<10).map { i in
            makeSnapshot(
                timestamp: Date().addingTimeInterval(Double(i)),
                pressureLevel: 4,
                freePages: 10,
                inactivePages: 10
            )
        }
        let alerts = evaluator.evaluate(samples: samples, currentSnapshot: samples.last)
        guard let alert = alerts.first else {
            XCTFail("Expected at least one alert")
            return
        }
        XCTAssertNotNil(alert.snapshotAgeMs, "Sample-derived alert should have snapshotAgeMs")
        XCTAssertNotNil(alert.pressureTier, "Sample-derived alert should have pressureTier")
    }
}

// MARK: - DaemonAlert Tests

final class DaemonAlertTests: XCTestCase {

    func testNonSnapshotAlertNilFields() {
        let alert = DaemonAlert(
            code: .helperUnavailable,
            severity: .warning,
            message: "Helper not available"
        )
        XCTAssertNil(alert.snapshotAgeMs)
        XCTAssertNil(alert.pressureTier)
    }

    func testNilFieldsEncodedAsNull() throws {
        let alert = DaemonAlert(
            code: .helperUnavailable,
            severity: .warning,
            message: "Helper not available"
            // snapshotAgeMs and pressureTier default to nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(alert)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        // Fields must be present as NSNull, not absent
        XCTAssertTrue(json.keys.contains("snapshot_age_ms"),
                      "snapshot_age_ms must be present (as null) in JSON")
        XCTAssertTrue(json.keys.contains("pressure_tier"),
                      "pressure_tier must be present (as null) in JSON")
        XCTAssertTrue(json["snapshot_age_ms"] is NSNull)
        XCTAssertTrue(json["pressure_tier"] is NSNull)
    }

    func testSnapshotAlertPopulatedFields() {
        let alert = DaemonAlert(
            code: .pressureCritical,
            severity: .emergency,
            message: "Critical pressure",
            snapshotAgeMs: 500,
            pressureTier: "critical"
        )
        XCTAssertEqual(alert.snapshotAgeMs, 500)
        XCTAssertEqual(alert.pressureTier, "critical")
    }

    func testAlertCodableRoundTrip() throws {
        let alert = DaemonAlert(
            code: .swapHigh,
            severity: .warning,
            message: "Swap high",
            snapshotAgeMs: 100,
            pressureTier: "warning",
            timestamp: Date(timeIntervalSinceReferenceDate: 700_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(alert)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Verify snake_case keys
        XCTAssertNotNil(json["snapshot_age_ms"])
        XCTAssertNotNil(json["pressure_tier"])
        XCTAssertEqual(json["code"] as? String, "SWAP_HIGH")
        XCTAssertEqual(json["severity"] as? String, "warning")
    }
}

// MARK: - DaemonConfig / ConfigStatus Tests

final class DaemonConfigTests: XCTestCase {

    func testDefaultConfig() {
        let config = DaemonConfig()
        XCTAssertTrue(config.stateDir.path.hasSuffix(".cacheout"))
        XCTAssertEqual(config.pollIntervalSeconds, 1.0)
    }

    func testCustomConfig() {
        let dir = URL(fileURLWithPath: "/tmp/test-cacheout")
        let config = DaemonConfig(stateDir: dir, pollIntervalSeconds: 5.0)
        XCTAssertEqual(config.stateDir, dir)
        XCTAssertEqual(config.pollIntervalSeconds, 5.0)
    }

    func testConfigStatusDefaults() {
        let status = ConfigStatus()
        XCTAssertEqual(status.generation, 0)
        XCTAssertNil(status.lastReload)
        XCTAssertEqual(status.status, .noConfig)
        XCTAssertNil(status.error)
    }

    func testConfigStatusNilFieldsEncodedAsNull() throws {
        let status = ConfigStatus() // lastReload=nil, error=nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(status)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertTrue(json.keys.contains("last_reload"),
                      "last_reload must be present (as null) in JSON")
        XCTAssertTrue(json.keys.contains("error"),
                      "error must be present (as null) in JSON")
        XCTAssertTrue(json["last_reload"] is NSNull)
        XCTAssertTrue(json["error"] is NSNull)
    }

    func testConfigStatusCodableRoundTrip() throws {
        let status = ConfigStatus(
            generation: 3,
            lastReload: Date(timeIntervalSinceReferenceDate: 700_000_000),
            status: .ok,
            error: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(status)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["generation"] as? Int, 3)
        XCTAssertNotNil(json["last_reload"])
        XCTAssertEqual(json["status"] as? String, "ok")
    }
}

// MARK: - AutopilotConfigValidator Tests

final class AutopilotConfigValidatorTests: XCTestCase {

    func testValidMinimalConfig() {
        let json = """
        {"version": 1, "enabled": true}
        """.data(using: .utf8)!
        let errors = AutopilotConfigValidator.validate(data: json)
        XCTAssertTrue(errors.isEmpty, "Minimal valid config should pass: \(errors)")
    }

    func testValidFullConfig() {
        let json = """
        {
            "version": 1,
            "enabled": true,
            "rules": [
                {"action": "pressure-trigger", "condition": {"pressure_tier": "warning"}}
            ],
            "webhook": {
                "url": "https://example.com/hook",
                "format": "generic",
                "timeout_s": 10
            },
            "telegram": {
                "bot_token": "123:ABC",
                "chat_id": "-100123",
                "timeout_s": 5
            }
        }
        """.data(using: .utf8)!
        let errors = AutopilotConfigValidator.validate(data: json)
        XCTAssertTrue(errors.isEmpty, "Full valid config should pass: \(errors)")
    }

    func testInvalidJSON() {
        let data = "not json".data(using: .utf8)!
        let errors = AutopilotConfigValidator.validate(data: data)
        XCTAssertFalse(errors.isEmpty)
        XCTAssertTrue(errors[0].contains("Invalid JSON"))
    }

    func testMissingVersion() {
        let json = """
        {"enabled": true}
        """.data(using: .utf8)!
        let errors = AutopilotConfigValidator.validate(data: json)
        XCTAssertTrue(errors.contains { $0.contains("version") })
    }

    func testWrongVersion() {
        let json = """
        {"version": 2, "enabled": true}
        """.data(using: .utf8)!
        let errors = AutopilotConfigValidator.validate(data: json)
        XCTAssertTrue(errors.contains { $0.contains("Unsupported version") })
    }

    func testMissingEnabled() {
        let json = """
        {"version": 1}
        """.data(using: .utf8)!
        let errors = AutopilotConfigValidator.validate(data: json)
        XCTAssertTrue(errors.contains { $0.contains("enabled") })
    }

    func testInvalidRuleAction() {
        let json = """
        {
            "version": 1,
            "enabled": true,
            "rules": [
                {"action": "jetsam-limit", "condition": {"pressure_tier": "warning"}}
            ]
        }
        """.data(using: .utf8)!
        let errors = AutopilotConfigValidator.validate(data: json)
        XCTAssertTrue(errors.contains { $0.contains("unsupported action") },
                     "Tier 2+ actions should be rejected: \(errors)")
    }

    func testMissingRuleCondition() {
        let json = """
        {
            "version": 1,
            "enabled": true,
            "rules": [
                {"action": "pressure-trigger"}
            ]
        }
        """.data(using: .utf8)!
        let errors = AutopilotConfigValidator.validate(data: json)
        XCTAssertTrue(errors.contains { $0.contains("condition") })
    }

    func testMissingConditionPressureTier() {
        let json = """
        {
            "version": 1,
            "enabled": true,
            "rules": [
                {"action": "pressure-trigger", "condition": {}}
            ]
        }
        """.data(using: .utf8)!
        let errors = AutopilotConfigValidator.validate(data: json)
        XCTAssertTrue(errors.contains { $0.contains("pressure_tier") })
    }

    func testWebhookMissingFields() {
        let json = """
        {
            "version": 1,
            "enabled": true,
            "webhook": {}
        }
        """.data(using: .utf8)!
        let errors = AutopilotConfigValidator.validate(data: json)
        XCTAssertTrue(errors.contains { $0.contains("webhook: missing") && $0.contains("url") })
        XCTAssertTrue(errors.contains { $0.contains("webhook: missing") && $0.contains("format") })
        XCTAssertTrue(errors.contains { $0.contains("webhook: missing") && $0.contains("timeout_s") })
    }

    func testWebhookInvalidFormat() {
        let json = """
        {
            "version": 1,
            "enabled": true,
            "webhook": {"url": "https://x.com", "format": "slack", "timeout_s": 5}
        }
        """.data(using: .utf8)!
        let errors = AutopilotConfigValidator.validate(data: json)
        XCTAssertTrue(errors.contains { $0.contains("unsupported format") })
    }

    func testWebhookTimeoutOutOfRange() {
        let json = """
        {
            "version": 1,
            "enabled": true,
            "webhook": {"url": "https://x.com", "format": "generic", "timeout_s": 120}
        }
        """.data(using: .utf8)!
        let errors = AutopilotConfigValidator.validate(data: json)
        XCTAssertTrue(errors.contains { $0.contains("timeout_s must be 1-60") })
    }

    func testTelegramMissingFields() {
        let json = """
        {
            "version": 1,
            "enabled": true,
            "telegram": {}
        }
        """.data(using: .utf8)!
        let errors = AutopilotConfigValidator.validate(data: json)
        XCTAssertTrue(errors.contains { $0.contains("bot_token") })
        XCTAssertTrue(errors.contains { $0.contains("chat_id") })
        XCTAssertTrue(errors.contains { $0.contains("timeout_s") })
    }

    func testValidAutopilotActions() {
        // Verify the autopilot actions match what's in the registry
        XCTAssertTrue(InterventionRegistry.autopilotActions.contains("pressure-trigger"))
        XCTAssertTrue(InterventionRegistry.autopilotActions.contains("reduce-transparency"))
        XCTAssertEqual(InterventionRegistry.autopilotActions.count, 2)
    }

    func testPressureTierNonString() {
        let json = """
        {
            "version": 1,
            "enabled": true,
            "rules": [
                {"action": "pressure-trigger", "condition": {"pressure_tier": 123}}
            ]
        }
        """.data(using: .utf8)!
        let errors = AutopilotConfigValidator.validate(data: json)
        XCTAssertTrue(errors.contains { $0.contains("pressure_tier must be a string") })
    }

    func testPressureTierInvalidValue() {
        let json = """
        {
            "version": 1,
            "enabled": true,
            "rules": [
                {"action": "pressure-trigger", "condition": {"pressure_tier": "banana"}}
            ]
        }
        """.data(using: .utf8)!
        let errors = AutopilotConfigValidator.validate(data: json)
        XCTAssertTrue(errors.contains { $0.contains("invalid pressure_tier") })
    }

    func testConditionNonObject() {
        let json = """
        {
            "version": 1,
            "enabled": true,
            "rules": [
                {"action": "pressure-trigger", "condition": "not_an_object"}
            ]
        }
        """.data(using: .utf8)!
        let errors = AutopilotConfigValidator.validate(data: json)
        XCTAssertTrue(errors.contains { $0.contains("must be an object") })
    }

    func testWebhookNonObject() {
        let json = """
        {"version": 1, "enabled": true, "webhook": "not_an_object"}
        """.data(using: .utf8)!
        let errors = AutopilotConfigValidator.validate(data: json)
        XCTAssertTrue(errors.contains { $0.contains("'webhook' must be an object") })
    }

    func testTelegramNonObject() {
        let json = """
        {"version": 1, "enabled": true, "telegram": 42}
        """.data(using: .utf8)!
        let errors = AutopilotConfigValidator.validate(data: json)
        XCTAssertTrue(errors.contains { $0.contains("'telegram' must be an object") })
    }

    // MARK: - Boolean coercion rejection (NSNumber parity with Python)

    func testBooleanVersionRejected() {
        // JSON `true` is NSNumber/CFBoolean — must not pass as Int version
        let json = """
        {"version": true, "enabled": true}
        """.data(using: .utf8)!
        let errors = AutopilotConfigValidator.validate(data: json)
        XCTAssertTrue(errors.contains { $0.contains("version") },
                      "Boolean version should be rejected: \(errors)")
    }

    func testBooleanConsecutiveSamplesRejected() {
        let json = """
        {
            "version": 1, "enabled": true,
            "rules": [{"action": "pressure-trigger",
                        "condition": {"pressure_tier": "warning", "consecutive_samples": false}}]
        }
        """.data(using: .utf8)!
        let errors = AutopilotConfigValidator.validate(data: json)
        XCTAssertTrue(errors.contains { $0.contains("consecutive_samples must be an integer") },
                      "Boolean consecutive_samples should be rejected: \(errors)")
    }

    func testBooleanCompressionRatioBelowRejected() {
        let json = """
        {
            "version": 1, "enabled": true,
            "rules": [{"action": "pressure-trigger",
                        "condition": {"pressure_tier": "warning", "compression_ratio_below": true}}]
        }
        """.data(using: .utf8)!
        let errors = AutopilotConfigValidator.validate(data: json)
        XCTAssertTrue(errors.contains { $0.contains("compression_ratio_below must be a number") },
                      "Boolean compression_ratio_below should be rejected: \(errors)")
    }

    func testBooleanCompressionRatioWindowRejected() {
        let json = """
        {
            "version": 1, "enabled": true,
            "rules": [{"action": "pressure-trigger",
                        "condition": {"pressure_tier": "warning", "compression_ratio_window": true}}]
        }
        """.data(using: .utf8)!
        let errors = AutopilotConfigValidator.validate(data: json)
        XCTAssertTrue(errors.contains { $0.contains("compression_ratio_window must be an integer") },
                      "Boolean compression_ratio_window should be rejected: \(errors)")
    }

    func testBooleanWebhookTimeoutRejected() {
        let json = """
        {
            "version": 1, "enabled": true,
            "webhook": {"url": "https://x.com", "format": "generic", "timeout_s": true}
        }
        """.data(using: .utf8)!
        let errors = AutopilotConfigValidator.validate(data: json)
        XCTAssertTrue(errors.contains { $0.contains("timeout_s") },
                      "Boolean webhook timeout_s should be rejected: \(errors)")
    }

    func testBooleanTelegramTimeoutRejected() {
        let json = """
        {
            "version": 1, "enabled": true,
            "telegram": {"bot_token": "t", "chat_id": "c", "timeout_s": false}
        }
        """.data(using: .utf8)!
        let errors = AutopilotConfigValidator.validate(data: json)
        XCTAssertTrue(errors.contains { $0.contains("timeout_s") },
                      "Boolean telegram timeout_s should be rejected: \(errors)")
    }
}

// MARK: - InterventionRegistry Tests

final class InterventionRegistryTests: XCTestCase {

    func testCanonicalizeUnderscoresToHyphens() {
        XCTAssertEqual(InterventionRegistry.canonicalize("pressure_trigger"), "pressure-trigger")
        XCTAssertEqual(InterventionRegistry.canonicalize("sleep_image_delete"), "sleep-image-delete")
    }

    func testCanonicalizeAlreadyHyphenated() {
        XCTAssertEqual(InterventionRegistry.canonicalize("pressure-trigger"), "pressure-trigger")
    }

    func testRegistryContainsAllExpectedInterventions() {
        let expected = [
            "pressure-trigger", "reduce-transparency",
            "jetsam-limit", "jetsam-hwm",
            "flush-windowserver", "windowserver-flush",
            "compressor-tuning",
            "delete-snapshot", "snapshot-cleanup",
            "sigterm-cascade", "sigstop-freeze",
            "sleep-image-delete",
        ]
        for name in expected {
            XCTAssertNotNil(InterventionRegistry.registry[name], "Registry missing: \(name)")
        }
    }

    func testSignalInterventionNames() {
        XCTAssertTrue(InterventionRegistry.signalInterventionNames.contains("sigterm-cascade"))
        XCTAssertTrue(InterventionRegistry.signalInterventionNames.contains("sigstop-freeze"))
    }
}

// MARK: - DaemonSnapshot Tests

final class DaemonSnapshotTests: XCTestCase {

    func testAgeMsComputation() {
        let past = Date().addingTimeInterval(-2.0) // 2 seconds ago
        let snapshot = DaemonSnapshot(stats: makeStats(), timestamp: past)
        // ageMs should be approximately 2000ms (allow some tolerance)
        XCTAssertGreaterThan(snapshot.ageMs, 1900)
        XCTAssertLessThan(snapshot.ageMs, 2200)
    }
}

// MARK: - StatusSocket Integration Tests

final class StatusSocketIntegrationTests: XCTestCase {

    /// Create a short temp directory path suitable for Unix sockets (< 104 bytes).
    /// Uses /tmp/co-XXXXX to keep well under the sockaddr_un limit.
    private func makeShortTmpDir() throws -> URL {
        let suffix = String(UInt32.random(in: 10000...99999))
        let dir = URL(fileURLWithPath: "/tmp/co-\(suffix)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Test that StatusSocket can be created, started, queried, and stopped
    /// using a temporary directory with --state-dir.
    func testSocketLifecycle() async throws {
        let tmpDir = try makeShortTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let socketPath = tmpDir.appendingPathComponent("status.sock").path

        // Verify path is short enough
        XCTAssertLessThan(socketPath.utf8.count, 104)

        // Create a mock data source
        let mockSource = MockDataSource()
        let socket = StatusSocket(socketPath: socketPath, dataSource: mockSource)

        try socket.start()
        defer { socket.stop() }

        // Connect and send "health" command using JSON format
        let response = try sendSocketCommand("{\"cmd\":\"health\"}\n", to: socketPath)
        XCTAssertNotNil(response)

        // Parse response envelope
        let json = try JSONSerialization.jsonObject(with: response.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(json["ok"] as? Bool, true)

        let data = json["data"] as! [String: Any]
        XCTAssertEqual(data["health_score"] as? Int, -1, "No snapshot → health_score should be -1")
        XCTAssertEqual(data["helper_available"] as? Bool, false)
        XCTAssertNotNil(data["alerts"])
    }

    func testSocketStatsCommand() async throws {
        let tmpDir = try makeShortTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let socketPath = tmpDir.appendingPathComponent("status.sock").path
        let mockSource = MockDataSource(snapshot: DaemonSnapshot(stats: makeStats()))
        let socket = StatusSocket(socketPath: socketPath, dataSource: mockSource)
        try socket.start()
        defer { socket.stop() }

        let response = try sendSocketCommand("{\"cmd\":\"stats\"}\n", to: socketPath)
        let json = try JSONSerialization.jsonObject(with: response.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertNotNil(json["data"])
    }

    func testSocketConfigStatusCommand() async throws {
        let tmpDir = try makeShortTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let socketPath = tmpDir.appendingPathComponent("status.sock").path
        let mockSource = MockDataSource()
        let socket = StatusSocket(socketPath: socketPath, dataSource: mockSource)
        try socket.start()
        defer { socket.stop() }

        let response = try sendSocketCommand("{\"cmd\":\"config_status\"}\n", to: socketPath)
        let json = try JSONSerialization.jsonObject(with: response.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(json["ok"] as? Bool, true, "Response: \(response)")
        guard let data = json["data"] as? [String: Any] else {
            XCTFail("Expected data in response: \(response)")
            return
        }
        XCTAssertEqual(data["generation"] as? Int, 0, "Default generation should be 0")
        XCTAssertEqual(data["status"] as? String, "no_config")
    }

    func testSocketValidateConfigCommand() async throws {
        let tmpDir = try makeShortTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Write a valid config file
        let configPath = tmpDir.appendingPathComponent("autopilot.json")
        let validConfig = """
        {"version": 1, "enabled": true}
        """
        try validConfig.write(to: configPath, atomically: true, encoding: .utf8)

        let socketPath = tmpDir.appendingPathComponent("status.sock").path
        let mockSource = MockDataSource()
        let socket = StatusSocket(socketPath: socketPath, dataSource: mockSource)
        try socket.start()
        defer { socket.stop() }

        let vcJSON = "{\"cmd\":\"validate_config\",\"path\":\"\(configPath.path)\"}\n"
        let response = try sendSocketCommand(vcJSON, to: socketPath)
        let json = try JSONSerialization.jsonObject(with: response.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(json["ok"] as? Bool, true)
        let data = json["data"] as! [String: Any]
        XCTAssertEqual(data["valid"] as? Bool, true)
    }

    func testSocketValidateConfigInvalid() async throws {
        let tmpDir = try makeShortTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Write an invalid config file
        let configPath = tmpDir.appendingPathComponent("bad-config.json")
        try "not json".write(to: configPath, atomically: true, encoding: .utf8)

        let socketPath = tmpDir.appendingPathComponent("status.sock").path
        let mockSource = MockDataSource()
        let socket = StatusSocket(socketPath: socketPath, dataSource: mockSource)
        try socket.start()
        defer { socket.stop() }

        let vcJSON = "{\"cmd\":\"validate_config\",\"path\":\"\(configPath.path)\"}\n"
        let response = try sendSocketCommand(vcJSON, to: socketPath)
        let json = try JSONSerialization.jsonObject(with: response.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(json["ok"] as? Bool, true)
        let data = json["data"] as! [String: Any]
        XCTAssertEqual(data["valid"] as? Bool, false)
        XCTAssertFalse((data["errors"] as? [String])?.isEmpty ?? true)
    }

    func testSocketUnknownCommand() async throws {
        let tmpDir = try makeShortTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let socketPath = tmpDir.appendingPathComponent("status.sock").path
        let mockSource = MockDataSource()
        let socket = StatusSocket(socketPath: socketPath, dataSource: mockSource)
        try socket.start()
        defer { socket.stop() }

        let response = try sendSocketCommand("{\"cmd\":\"bogus\"}\n", to: socketPath)
        let json = try JSONSerialization.jsonObject(with: response.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(json["ok"] as? Bool, false)
        let errorObj = json["error"] as? [String: Any]
        XCTAssertEqual(errorObj?["code"] as? String, "UNKNOWN_COMMAND")
        XCTAssertTrue((errorObj?["message"] as? String)?.contains("bogus") ?? false)
    }

    func testSocketPermissions() async throws {
        let tmpDir = try makeShortTmpDir()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmpDir.path)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let socketPath = tmpDir.appendingPathComponent("status.sock").path
        let mockSource = MockDataSource()
        let socket = StatusSocket(socketPath: socketPath, dataSource: mockSource)
        try socket.start()
        defer { socket.stop() }

        // Check directory permissions
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: tmpDir.path)
        let dirPerms = dirAttrs[.posixPermissions] as? Int
        XCTAssertEqual(dirPerms, 0o700, "State directory should be 0700")

        // Check socket file permissions
        let sockAttrs = try FileManager.default.attributesOfItem(atPath: socketPath)
        let sockPerms = sockAttrs[.posixPermissions] as? Int
        XCTAssertEqual(sockPerms, 0o600, "Socket file should be 0600")
    }

    func testSocketHardensPreExistingLoosePermissions() async throws {
        // Create a directory with loose 0755 permissions BEFORE socket start
        let tmpDir = try makeShortTmpDir()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpDir.path)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let socketPath = tmpDir.appendingPathComponent("status.sock").path
        let mockSource = MockDataSource()
        let socket = StatusSocket(socketPath: socketPath, dataSource: mockSource)
        try socket.start()
        defer { socket.stop() }

        // Socket start should have tightened directory to 0700
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: tmpDir.path)
        let dirPerms = dirAttrs[.posixPermissions] as? Int
        XCTAssertEqual(dirPerms, 0o700, "Pre-existing 0755 directory should be tightened to 0700")
    }

    func testNegativeTopNRejected() async throws {
        let tmpDir = try makeShortTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let socketPath = tmpDir.appendingPathComponent("status.sock").path
        let mockSource = MockDataSource()
        let socket = StatusSocket(socketPath: socketPath, dataSource: mockSource)
        try socket.start()
        defer { socket.stop() }

        let response = try sendSocketCommand("{\"cmd\":\"processes\",\"top_n\":-1}\n", to: socketPath)
        let json = try JSONSerialization.jsonObject(with: response.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(json["ok"] as? Bool, false, "Negative top_n should be rejected")
        let errorObj = json["error"] as? [String: Any]
        XCTAssertEqual(errorObj?["code"] as? String, "INVALID_ARGUMENT")
    }

    func testZeroTopNRejected() async throws {
        let tmpDir = try makeShortTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let socketPath = tmpDir.appendingPathComponent("status.sock").path
        let mockSource = MockDataSource()
        let socket = StatusSocket(socketPath: socketPath, dataSource: mockSource)
        try socket.start()
        defer { socket.stop() }

        let response = try sendSocketCommand("{\"cmd\":\"processes\",\"top_n\":0}\n", to: socketPath)
        let json = try JSONSerialization.jsonObject(with: response.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(json["ok"] as? Bool, false, "Zero top_n should be rejected")
    }

    func testSocketPathTooLong() {
        let longPath = String(repeating: "a", count: 110) + "/status.sock"
        let mockSource = MockDataSource()
        let socket = StatusSocket(socketPath: longPath, dataSource: mockSource)
        XCTAssertThrowsError(try socket.start()) { error in
            XCTAssertTrue(error.localizedDescription.contains("too long"))
        }
    }

    func testConcurrentClients() async throws {
        let tmpDir = try makeShortTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let socketPath = tmpDir.appendingPathComponent("status.sock").path
        let mockSource = MockDataSource()
        let socket = StatusSocket(socketPath: socketPath, dataSource: mockSource)
        try socket.start()
        defer { socket.stop() }

        // Brief pause so the GCD dispatch source is fully registered before
        // clients hammer the socket — prevents ECONNREFUSED under load.
        usleep(10_000) // 10ms

        // Send 10 concurrent requests
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 {
                group.addTask { [self] in
                    try sendSocketCommand("{\"cmd\":\"health\"}\n", to: socketPath)
                }
            }
            var responses: [String] = []
            for try await response in group {
                responses.append(response)
            }
            XCTAssertEqual(responses.count, 10, "All 10 concurrent clients should get responses")
            for response in responses {
                let json = try JSONSerialization.jsonObject(with: response.data(using: .utf8)!) as! [String: Any]
                XCTAssertEqual(json["ok"] as? Bool, true)
            }
        }
    }

    // MARK: - Helper: Send command to Unix socket

    private func sendSocketCommand(_ command: String, to path: String) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "test", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathCString = path.utf8CString
        withUnsafeMutableBytes(of: &addr.sun_path) { pathPtr in
            pathCString.withUnsafeBufferPointer { cBuf in
                let copyLen = min(cBuf.count, pathPtr.count)
                for i in 0..<copyLen {
                    pathPtr[i] = UInt8(bitPattern: cBuf[i])
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw NSError(domain: "test", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "connect() failed: errno \(errno)"])
        }

        // Send command
        let bytes = Array(command.utf8)
        bytes.withUnsafeBufferPointer { buf in
            _ = Darwin.write(fd, buf.baseAddress!, buf.count)
        }

        // Read response
        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else {
            throw NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: "No response"])
        }
        return String(bytes: buffer[0..<n], encoding: .utf8) ?? ""
    }
}

// MARK: - Mock DataSource

private final class MockDataSource: StatusSocket.DataSource {
    let snapshot: DaemonSnapshot?
    let alerts: [DaemonAlert]
    let config: ConfigStatus

    init(
        snapshot: DaemonSnapshot? = nil,
        alerts: [DaemonAlert] = [],
        config: ConfigStatus = ConfigStatus()
    ) {
        self.snapshot = snapshot
        self.alerts = alerts
        self.config = config
    }

    func currentSnapshot() async -> DaemonSnapshot? { snapshot }
    func sampleHistory() async -> [DaemonSnapshot] {
        snapshot.map { [$0] } ?? []
    }
    func activeAlerts() async -> [DaemonAlert] { alerts }
    func configStatus() async -> ConfigStatus { config }
    func helperAvailable() async -> Bool { false }
    func recommendations() async -> RecommendationResult? { nil }
}
