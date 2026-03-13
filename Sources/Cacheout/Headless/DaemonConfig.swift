// DaemonConfig.swift
// Configuration for the headless daemon mode.

import Foundation

/// Configuration passed to `DaemonMode.run(config:)`.
///
/// Parsed from CLI arguments (`--daemon --state-dir <path>`).
public struct DaemonConfig: Sendable {
    /// Directory for daemon state files (PID lock, socket, config, restart marker).
    /// Default: `~/.cacheout/`
    public let stateDir: URL

    /// Polling interval for memory sampling, in seconds.
    public let pollIntervalSeconds: TimeInterval

    public init(
        stateDir: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cacheout"),
        pollIntervalSeconds: TimeInterval = 1.0
    ) {
        self.stateDir = stateDir
        self.pollIntervalSeconds = pollIntervalSeconds
    }
}

/// Tracks the status of the autopilot configuration file.
///
/// Used by the `config_status` socket command. Task .2 wires the actual
/// loading and SIGHUP reload logic.
public struct ConfigStatus: Codable, Sendable {
    /// Monotonically increasing config generation counter.
    /// 0 = no config has ever been loaded (file missing at startup).
    /// 1 = startup load succeeded or failed.
    /// Incremented on each SIGHUP attempt.
    public var generation: Int

    /// When the last reload was attempted (nil if generation == 0).
    public var lastReload: Date?

    /// Status of the last load attempt.
    public var status: ConfigLoadStatus

    /// Error message if the last load attempt failed (nil on success or no_config).
    public var error: String?

    public init(
        generation: Int = 0,
        lastReload: Date? = nil,
        status: ConfigLoadStatus = .noConfig,
        error: String? = nil
    ) {
        self.generation = generation
        self.lastReload = lastReload
        self.status = status
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case generation
        case lastReload = "last_reload"
        case status
        case error
    }

    /// Custom encoding to ensure nullable fields are always present as `null`
    /// rather than being omitted, providing a stable JSON shape for consumers.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(generation, forKey: .generation)
        try container.encode(lastReload, forKey: .lastReload)
        try container.encode(status, forKey: .status)
        try container.encode(error, forKey: .error)
    }
}

/// Possible states for config loading.
public enum ConfigLoadStatus: String, Codable, Sendable {
    /// No config file exists (generation 0).
    case noConfig = "no_config"
    /// Config loaded and applied successfully.
    case ok
    /// Config file exists but failed validation.
    case error
}
