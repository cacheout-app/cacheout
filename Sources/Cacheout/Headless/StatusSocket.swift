// StatusSocket.swift
// Unix domain socket server for the headless daemon.

import CacheoutShared
import Foundation
import os

/// Unix domain socket server that accepts newline-delimited JSON commands
/// and returns JSON-envelope responses.
///
/// ## Commands
/// - `stats`: Current SystemStatsDTO
/// - `processes`: Top processes by memory (accepts `top_n` param)
/// - `compressor`: Compressor stats
/// - `health`: Alerts + health score + helper status
/// - `config_status`: Config generation and load status
/// - `validate_config`: Dry-run validation of config at path (accepts `path` param)
///
/// ## Security
/// - Socket directory: 0700
/// - Socket file: 0600
/// - umask applied during creation
/// - Path length validated < 104 (sockaddr_un limit)
///
/// ## Protocol
/// - Max message size: 64KB (messages exceeding this are rejected)
/// - Request format: `{"cmd": "<name>", ...params}\n`
/// - Response envelope: `{"ok": true, "data": ...}` or
///   `{"ok": false, "error": {"code": "...", "message": "..."}}`
/// - Concurrent clients via per-client dispatch
///
/// Implemented as a class (not actor) because the accept/read operations use
/// GCD dispatch sources and blocking POSIX I/O that must not serialize through
/// Swift's cooperative thread pool. Data access is async via the DataSource protocol.
public final class StatusSocket: @unchecked Sendable {

    // MARK: - Types

    /// Provides data for socket commands. Implemented by DaemonMode.
    public protocol DataSource: Sendable {
        /// Current daemon snapshot (nil if no sample yet).
        func currentSnapshot() async -> DaemonSnapshot?
        /// Recent sample history for alert evaluation.
        func sampleHistory() async -> [DaemonSnapshot]
        /// Current active alerts (sample-derived + daemon-owned).
        func activeAlerts() async -> [DaemonAlert]
        /// Current config status.
        func configStatus() async -> ConfigStatus
        /// Whether the XPC helper is registered.
        func helperAvailable() async -> Bool
        /// Generate advisory recommendations (nil if not wired).
        func recommendations() async -> RecommendationResult?
    }

    // MARK: - Constants

    /// Maximum message size in bytes.
    private static let maxMessageSize = 65536

    /// Maximum socket path length (sockaddr_un.sun_path limit).
    private static let maxSocketPathLength = 104

    // MARK: - State

    private let socketPath: String
    private let dataSource: DataSource
    private var listenFileDescriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var isRunning = false

    /// Dedicated queue for socket I/O — avoids blocking the cooperative thread pool.
    private let socketQueue = DispatchQueue(label: "com.cacheout.status-socket", attributes: .concurrent)

    private let logger = Logger(subsystem: "com.cacheout", category: "StatusSocket")

    // MARK: - Init

    /// Create a status socket at the given path.
    ///
    /// - Parameters:
    ///   - socketPath: Absolute path for the Unix domain socket.
    ///   - dataSource: Provider of data for command responses.
    public init(socketPath: String, dataSource: DataSource) {
        self.socketPath = socketPath
        self.dataSource = dataSource
    }

    // MARK: - Lifecycle

    /// Start listening for connections.
    ///
    /// Creates the socket file with 0600 permissions in a 0700 directory.
    /// Uses GCD DispatchSource for non-blocking accept and per-client
    /// dispatch to avoid starving Swift's cooperative thread pool.
    ///
    /// - Throws: If the socket path is too long, or bind/listen fails.
    public func start() throws {
        guard !isRunning else { return }

        // Validate path length
        guard socketPath.utf8.count < Self.maxSocketPathLength else {
            throw StatusSocketError.pathTooLong(socketPath.utf8.count, max: Self.maxSocketPathLength)
        }

        // Ensure directory exists with 0700 permissions.
        // createDirectory only sets attributes on newly created dirs, so we
        // explicitly chmod afterward to harden pre-existing directories.
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)

        // Remove stale socket if present
        unlink(socketPath)

        // Create socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw StatusSocketError.socketCreationFailed(errno)
        }

        // Set non-blocking for accept loop
        let flags = fcntl(fd, F_GETFL)
        fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        // Set umask for socket creation (0077 ensures 0600)
        let oldUmask = umask(0o077)

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        // Copy path bytes into sun_path using utf8CString (guaranteed contiguous + NUL-terminated)
        let pathCString = socketPath.utf8CString
        withUnsafeMutableBytes(of: &addr.sun_path) { pathPtr in
            pathCString.withUnsafeBufferPointer { cBuf in
                let copyLen = min(cBuf.count, pathPtr.count)
                for i in 0..<copyLen {
                    pathPtr[i] = UInt8(bitPattern: cBuf[i])
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        // Restore umask
        umask(oldUmask)

        guard bindResult == 0 else {
            close(fd)
            throw StatusSocketError.bindFailed(errno)
        }

        // Verify socket permissions are 0600
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: socketPath)
            if let perms = attrs[.posixPermissions] as? Int, perms != 0o600 {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: socketPath)
            }
        } catch {
            // Best effort — umask should have set it correctly
        }

        // Listen
        guard listen(fd, 16) == 0 else {
            close(fd)
            unlink(socketPath)
            throw StatusSocketError.listenFailed(errno)
        }

        listenFileDescriptor = fd
        isRunning = true

        // Use DispatchSource for non-blocking accept
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: socketQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Accept all pending connections
            while true {
                let clientFd = accept(fd, nil, nil)
                guard clientFd >= 0 else { break }

                // Prevent SIGPIPE from killing the daemon if a client disconnects
                // before we finish writing the response. Treat EPIPE as normal disconnect.
                var noSigPipe: Int32 = 1
                setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                           socklen_t(MemoryLayout<Int32>.size))

                // Handle each client on the concurrent dispatch queue.
                // Reads happen on the dispatch thread (blocking is fine on GCD),
                // then async data fetching happens via Task.
                self.socketQueue.async {
                    self.handleClientSync(fd: clientFd)
                }
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        acceptSource = source

        logger.info("StatusSocket listening at \(self.socketPath, privacy: .public)")
    }

    /// Stop accepting connections and clean up.
    public func stop() {
        guard isRunning else { return }
        isRunning = false

        // Cancel the dispatch source (its cancel handler closes the fd)
        acceptSource?.cancel()
        acceptSource = nil
        listenFileDescriptor = -1

        // Remove socket file
        unlink(socketPath)

        logger.info("StatusSocket stopped")
    }

    // MARK: - Client Handler

    /// Handle a single client connection synchronously on a GCD thread.
    /// Reads the command (blocking), then dispatches to async processing.
    private func handleClientSync(fd: Int32) {
        defer { close(fd) }

        // Set a read timeout (2 seconds) to handle malformed/incomplete data
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Read command (up to 64KB + 1 to detect overflow, newline-terminated)
        var buffer = [UInt8](repeating: 0, count: Self.maxMessageSize + 1)
        var totalRead = 0
        var foundNewline = false

        while totalRead < buffer.count {
            let n = read(fd, &buffer[totalRead], buffer.count - totalRead)
            if n <= 0 { break }
            totalRead += n
            if buffer[0..<totalRead].contains(0x0A) {
                foundNewline = true
                break
            }
        }

        guard totalRead > 0 else { return }

        // Reject messages exceeding 64KB
        if totalRead > Self.maxMessageSize && !foundNewline {
            Self.sendErrorResponse(fd: fd, code: "MESSAGE_TOO_LARGE",
                                   message: "Message exceeds maximum size of \(Self.maxMessageSize) bytes")
            return
        }

        // Parse command — supports JSON format {"cmd": "..."} per PROTOCOL.md
        let rawMessage = String(bytes: buffer[0..<min(totalRead, Self.maxMessageSize)], encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if rawMessage.isEmpty {
            Self.sendErrorResponse(fd: fd, code: "EMPTY_COMMAND", message: "Empty command")
            return
        }

        // Parse as JSON request
        let command: String
        let params: [String: Any]

        if let jsonData = rawMessage.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let cmd = json["cmd"] as? String {
            command = cmd
            params = json
        } else {
            // Fallback: plain-text command for backward compatibility
            let parts = rawMessage.split(separator: " ", maxSplits: 1)
            command = String(parts[0])
            if parts.count > 1 {
                params = ["cmd": command, "_arg": String(parts[1])]
            } else {
                params = ["cmd": command]
            }
        }

        // Process command — bridge from GCD to async via semaphore.
        // No timeout: all command handlers are bounded (actor state reads + local I/O).
        // The semaphore guarantees the Task completes before we close the fd in defer.
        let semaphore = DispatchSemaphore(value: 0)
        let dataSource = self.dataSource
        Task {
            await Self.processCommand(command, params: params, fd: fd, dataSource: dataSource)
            semaphore.signal()
        }
        semaphore.wait()
    }

    // MARK: - Command Processing

    private static func processCommand(_ command: String, params: [String: Any], fd: Int32, dataSource: DataSource) async {
        switch command {
        case "stats":
            await handleStats(fd: fd, dataSource: dataSource)
        case "processes":
            let rawTopN = params["top_n"] as? Int ?? 10
            guard rawTopN > 0 else {
                sendErrorResponse(fd: fd, code: "INVALID_ARGUMENT",
                                  message: "top_n must be a positive integer, got \(rawTopN)")
                return
            }
            await handleProcesses(fd: fd, topN: rawTopN)
        case "compressor":
            await handleCompressor(fd: fd, dataSource: dataSource)
        case "health":
            await handleHealth(fd: fd, dataSource: dataSource)
        case "config_status":
            await handleConfigStatus(fd: fd, dataSource: dataSource)
        case "recommendations":
            await handleRecommendations(fd: fd, dataSource: dataSource)
        case "validate_config":
            let path = params["path"] as? String ?? params["_arg"] as? String
            await handleValidateConfig(path: path, fd: fd)
        default:
            sendErrorResponse(fd: fd, code: "UNKNOWN_COMMAND",
                              message: "Unknown command: \(command)")
        }
    }

    // MARK: - Command Handlers

    private static func handleStats(fd: Int32, dataSource: DataSource) async {
        guard let snapshot = await dataSource.currentSnapshot() else {
            sendErrorResponse(fd: fd, code: "NO_DATA", message: "No data available")
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot.stats),
           let dict = try? JSONSerialization.jsonObject(with: data) {
            sendSuccessResponse(fd: fd, data: dict)
        } else {
            sendErrorResponse(fd: fd, code: "ENCODING_FAILED", message: "Encoding failed")
        }
    }

    private static func handleProcesses(fd: Int32, topN: Int) async {
        let scanner = ProcessMemoryScanner()
        let result = await scanner.scan(topN: topN)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(result.processes),
           let list = try? JSONSerialization.jsonObject(with: data) {
            sendSuccessResponse(fd: fd, data: [
                "source": result.source,
                "partial": result.partial,
                "results": list,
            ] as [String: Any])
        } else {
            sendErrorResponse(fd: fd, code: "ENCODING_FAILED", message: "Encoding failed")
        }
    }

    private static func handleCompressor(fd: Int32, dataSource: DataSource) async {
        guard let snapshot = await dataSource.currentSnapshot() else {
            sendErrorResponse(fd: fd, code: "NO_DATA", message: "No data available")
            return
        }

        let stats = snapshot.stats
        sendSuccessResponse(fd: fd, data: [
            "compressed_bytes": stats.compressedBytes,
            "compressor_bytes_used": stats.compressorBytesUsed,
            "compression_ratio": stats.compressionRatio,
            "compressor_page_count": stats.compressorPageCount,
        ] as [String: Any])
    }

    private static func handleHealth(fd: Int32, dataSource: DataSource) async {
        let alerts = await dataSource.activeAlerts()
        let snapshot = await dataSource.currentSnapshot()
        let helperAvailable = await dataSource.helperAvailable()

        let healthScore: Int
        if let snapshot {
            let stats = snapshot.stats
            let availableMB = Double(stats.freePages + stats.inactivePages) * Double(stats.pageSize) / 1048576.0
            let tier = PressureTier.from(pressureLevel: stats.pressureLevel, availableMB: availableMB)
            let swapPercent: Double = stats.swapTotalBytes > 0
                ? Double(stats.swapUsedBytes) / Double(stats.swapTotalBytes) * 100.0
                : 0.0
            healthScore = HealthScore.compute(
                pressureTier: tier.rawValue,
                swapUsedPercent: swapPercent,
                compressionRatio: stats.compressionRatio
            )
        } else {
            healthScore = HealthScore.noData
        }

        // Encode alerts
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let alertsJson: Any
        if let data = try? encoder.encode(alerts),
           let list = try? JSONSerialization.jsonObject(with: data) {
            alertsJson = list
        } else {
            alertsJson = [] as [Any]
        }

        sendSuccessResponse(fd: fd, data: [
            "health_score": healthScore,
            "alerts": alertsJson,
            "helper_available": helperAvailable,
        ] as [String: Any])
    }

    private static func handleConfigStatus(fd: Int32, dataSource: DataSource) async {
        let status = await dataSource.configStatus()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(status),
           let dict = try? JSONSerialization.jsonObject(with: data) {
            sendSuccessResponse(fd: fd, data: dict)
        } else {
            sendErrorResponse(fd: fd, code: "ENCODING_FAILED", message: "Encoding failed")
        }
    }

    private static func handleRecommendations(fd: Int32, dataSource: DataSource) async {
        guard let result = await dataSource.recommendations() else {
            sendErrorResponse(fd: fd, code: "NOT_AVAILABLE",
                              message: "Recommendation engine not initialized")
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(result.recommendations),
           let list = try? JSONSerialization.jsonObject(with: data) {
            sendSuccessResponse(fd: fd, data: [
                "recommendations": list,
                "_meta": [
                    "count": result.recommendations.count,
                    "source": "daemon",
                    "scan_partial": result.scanPartial,
                ] as [String: Any],
            ] as [String: Any])
        } else {
            sendErrorResponse(fd: fd, code: "ENCODING_FAILED", message: "Encoding failed")
        }
    }

    /// Maximum config file size for validation (1 MB). Configs are small JSON files;
    /// anything larger is almost certainly not a valid autopilot config.
    private static let maxConfigFileSize: off_t = 1_048_576

    private static func handleValidateConfig(path: String?, fd: Int32) async {
        guard let path, !path.isEmpty else {
            sendErrorResponse(fd: fd, code: "MISSING_ARGUMENT",
                              message: "validate_config requires a file path argument")
            return
        }

        let expandedPath = (path as NSString).expandingTildeInPath
        let standardizedPath = (expandedPath as NSString).standardizingPath

        let allowedPrefix = NSHomeDirectory() + "/.cacheout/"
        guard standardizedPath.hasPrefix(allowedPrefix) else {
            sendSuccessResponse(fd: fd, data: [
                "valid": false,
                "errors": ["Path traversal detected. File must be within \(allowedPrefix)"],
            ] as [String: Any])
            return
        }

        // lstat to reject symlinks to special files, FIFOs, devices, etc.
        var sb = Darwin.stat()
        let statResult: Int32 = lstat(standardizedPath, &sb)
        guard statResult == 0 else {
            sendSuccessResponse(fd: fd, data: [
                "valid": false,
                "errors": ["File not found: \(standardizedPath)"],
            ] as [String: Any])
            return
        }

        // Only accept regular files (reject FIFOs, devices, directories, sockets)
        guard (sb.st_mode & S_IFMT) == S_IFREG else {
            sendSuccessResponse(fd: fd, data: [
                "valid": false,
                "errors": ["Not a regular file: \(standardizedPath)"],
            ] as [String: Any])
            return
        }

        // Enforce size cap to prevent memory exhaustion
        guard sb.st_size <= maxConfigFileSize else {
            sendSuccessResponse(fd: fd, data: [
                "valid": false,
                "errors": ["File too large (\(sb.st_size) bytes, max \(maxConfigFileSize))"],
            ] as [String: Any])
            return
        }

        do {
            let fileData = try Data(contentsOf: URL(fileURLWithPath: standardizedPath))
            let errors = AutopilotConfigValidator.validate(data: fileData)
            sendSuccessResponse(fd: fd, data: [
                "valid": errors.isEmpty,
                "errors": errors,
            ] as [String: Any])
        } catch {
            sendSuccessResponse(fd: fd, data: [
                "valid": false,
                "errors": ["Failed to read file: \(error.localizedDescription)"],
            ] as [String: Any])
        }
    }

    // MARK: - Response Helpers

    /// Write a success JSON envelope response to the client fd.
    private static func sendSuccessResponse(fd: Int32, data: Any) {
        let envelope: [String: Any] = ["ok": true, "data": data]
        writeJsonLine(fd: fd, envelope: envelope)
    }

    /// Write an error JSON envelope response to the client fd.
    /// Error format per PROTOCOL.md: `{"ok": false, "error": {"code": "...", "message": "..."}}`
    private static func sendErrorResponse(fd: Int32, code: String, message: String) {
        let envelope: [String: Any] = [
            "ok": false,
            "error": ["code": code, "message": message] as [String: String],
        ]
        writeJsonLine(fd: fd, envelope: envelope)
    }

    /// Serialize and write a JSON envelope as a newline-terminated line.
    private static func writeJsonLine(fd: Int32, envelope: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]),
              var response = String(data: jsonData, encoding: .utf8) else {
            return
        }

        response += "\n"
        let bytes = Array(response.utf8)
        bytes.withUnsafeBufferPointer { buf in
            var written = 0
            while written < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + written, buf.count - written)
                if n <= 0 { break }
                written += n
            }
        }
    }
}

// MARK: - Errors

/// Errors that can occur during socket setup.
public enum StatusSocketError: LocalizedError {
    case pathTooLong(Int, max: Int)
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let actual, let max):
            return "Socket path too long (\(actual) bytes, max \(max))"
        case .socketCreationFailed(let err):
            return "Failed to create socket: errno \(err)"
        case .bindFailed(let err):
            return "Failed to bind socket: errno \(err)"
        case .listenFailed(let err):
            return "Failed to listen on socket: errno \(err)"
        }
    }
}

// MARK: - Autopilot Config Validator

/// Validates autopilot configuration data against the v1 schema.
///
/// Used by `validate_config` socket command, startup config loading,
/// and SIGHUP reload (task .2). Single source of truth.
public enum AutopilotConfigValidator {

    // MARK: - Type-safe NSNumber helpers

    /// Check if a value is a JSON boolean (not a numeric NSNumber).
    /// `JSONSerialization` deserializes JSON `true`/`false` as `__NSCFBoolean`,
    /// which is an `NSNumber` subclass. `as? Int` and `as? Double` succeed on
    /// these, so we must reject booleans explicitly before numeric casts.
    private static func isJSONBoolean(_ value: Any) -> Bool {
        // CFBooleanGetTypeID() matches __NSCFBoolean but not __NSCFNumber
        guard let nsNumber = value as? NSNumber else { return false }
        return CFGetTypeID(nsNumber) == CFBooleanGetTypeID()
    }

    /// Extract an Int from a JSON value, rejecting booleans.
    private static func intValue(_ value: Any) -> Int? {
        guard !isJSONBoolean(value) else { return nil }
        return value as? Int
    }

    /// Extract a Double from a JSON value, rejecting booleans.
    private static func doubleValue(_ value: Any) -> Double? {
        guard !isJSONBoolean(value) else { return nil }
        return value as? Double
    }

    /// Validate the given JSON data against the autopilot config v1 schema.
    ///
    /// - Parameter data: Raw JSON data to validate.
    /// - Returns: Array of validation error messages (empty = valid).
    public static func validate(data: Data) -> [String] {
        var errors: [String] = []

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["Invalid JSON: expected a JSON object"]
        }

        // version — reject booleans (NSNumber coercion)
        guard let versionValue = json["version"], !isJSONBoolean(versionValue),
              let version = versionValue as? Int else {
            errors.append("Missing or non-integer 'version' field")
            return errors
        }
        if version != 1 {
            errors.append("Unsupported version: \(version) (expected 1)")
            return errors
        }

        // enabled
        guard json["enabled"] is Bool else {
            errors.append("Missing or non-boolean 'enabled' field")
            return errors
        }

        // rules
        if let rules = json["rules"] as? [[String: Any]] {
            for (i, rule) in rules.enumerated() {
                if let action = rule["action"] as? String {
                    if !InterventionRegistry.autopilotActions.contains(action) {
                        errors.append("Rule[\(i)]: unsupported action '\(action)' (allowed: \(InterventionRegistry.autopilotActions.sorted().joined(separator: ", ")))")
                    }
                } else {
                    errors.append("Rule[\(i)]: missing or non-string 'action' field")
                }

                if let condition = rule["condition"] as? [String: Any] {
                    if let tier = condition["pressure_tier"] as? String {
                        if !PressureTier.validConfigValues.contains(tier) {
                            errors.append("Rule[\(i)]: invalid pressure_tier '\(tier)' (allowed: \(PressureTier.validConfigValues.sorted().joined(separator: ", ")))")
                        }
                    } else if condition["pressure_tier"] != nil {
                        errors.append("Rule[\(i)]: pressure_tier must be a string")
                    } else {
                        errors.append("Rule[\(i)]: condition missing 'pressure_tier'")
                    }

                    // Validate numeric condition fields (type + range).
                    // Use safe helpers to reject booleans coerced via NSNumber.
                    if let rawVal = condition["consecutive_samples"] {
                        if let consecutive = intValue(rawVal) {
                            if consecutive < 1 {
                                errors.append("Rule[\(i)]: consecutive_samples must be >= 1, got \(consecutive)")
                            }
                        } else {
                            errors.append("Rule[\(i)]: consecutive_samples must be an integer")
                        }
                    }
                    if let rawVal = condition["compression_ratio_window"] {
                        if let ratioWindow = intValue(rawVal) {
                            if ratioWindow < 1 {
                                errors.append("Rule[\(i)]: compression_ratio_window must be >= 1, got \(ratioWindow)")
                            }
                        } else {
                            errors.append("Rule[\(i)]: compression_ratio_window must be an integer")
                        }
                    }
                    if let rawVal = condition["compression_ratio_below"] {
                        if let ratioBelow = doubleValue(rawVal) {
                            if ratioBelow <= 0 {
                                errors.append("Rule[\(i)]: compression_ratio_below must be > 0, got \(ratioBelow)")
                            }
                        } else {
                            errors.append("Rule[\(i)]: compression_ratio_below must be a number")
                        }
                    }
                } else if rule["condition"] != nil {
                    errors.append("Rule[\(i)]: 'condition' must be an object")
                } else {
                    errors.append("Rule[\(i)]: missing 'condition' field")
                }
            }
        } else if json["rules"] != nil {
            errors.append("'rules' must be an array of objects")
        }

        // webhook (optional section, but all fields required when present)
        if json["webhook"] != nil && !(json["webhook"] is [String: Any]) {
            errors.append("'webhook' must be an object")
        } else if let webhook = json["webhook"] as? [String: Any] {
            if let urlStr = webhook["url"] as? String {
                if let url = URL(string: urlStr) {
                    let scheme = url.scheme?.lowercased() ?? ""
                    if scheme != "http" && scheme != "https" {
                        errors.append("webhook: url must use http or https scheme, got '\(scheme)'")
                    }
                    if url.host == nil || url.host?.isEmpty == true {
                        errors.append("webhook: url must be an absolute URL with a host")
                    }
                } else {
                    errors.append("webhook: url is not a valid URL")
                }
            } else {
                errors.append("webhook: missing or non-string 'url'")
            }
            if let format = webhook["format"] as? String {
                if format != "generic" {
                    errors.append("webhook: unsupported format '\(format)' (must be 'generic')")
                }
            } else {
                errors.append("webhook: missing or non-string 'format' (must be 'generic')")
            }
            if let rawTimeout = webhook["timeout_s"], let timeout = intValue(rawTimeout) {
                if timeout < 1 || timeout > 60 {
                    errors.append("webhook: timeout_s must be 1-60, got \(timeout)")
                }
            } else {
                errors.append("webhook: missing or non-integer 'timeout_s' (must be 1-60)")
            }
        }

        // telegram (optional section, but all fields required when present)
        if json["telegram"] != nil && !(json["telegram"] is [String: Any]) {
            errors.append("'telegram' must be an object")
        } else if let telegram = json["telegram"] as? [String: Any] {
            if telegram["bot_token"] as? String == nil {
                errors.append("telegram: missing or non-string 'bot_token'")
            }
            if telegram["chat_id"] as? String == nil {
                errors.append("telegram: missing or non-string 'chat_id'")
            }
            if let rawTimeout = telegram["timeout_s"], let timeout = intValue(rawTimeout) {
                if timeout < 1 || timeout > 60 {
                    errors.append("telegram: timeout_s must be 1-60, got \(timeout)")
                }
            } else {
                errors.append("telegram: missing or non-integer 'timeout_s' (must be 1-60)")
            }
        }

        return errors
    }
}
