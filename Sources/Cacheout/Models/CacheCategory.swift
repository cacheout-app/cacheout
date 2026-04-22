/// # CacheCategory — Cache Category Model
///
/// Defines the data model for a cache category that Cacheout can scan and clean.
/// Each category represents a specific type of cache on the filesystem (e.g., Xcode
/// DerivedData, npm cache, Docker disk image).
///
/// ## Key Concepts
///
/// ### Risk Levels
///
/// Every category has a `RiskLevel` that communicates the impact of deletion:
/// - **Safe** (green): System auto-rebuilds. No user intervention needed.
/// - **Review** (yellow): May require re-download or reconnection. Generally harmless.
/// - **Caution** (red): Destructive. May lose data (e.g., Docker containers/volumes).
///
/// ### Path Discovery
///
/// Categories use `PathDiscovery` to locate cache directories on the current machine:
/// - **staticPath**: A fixed path relative to `$HOME` (e.g., `Library/Caches/Homebrew`).
/// - **probed**: Runs a shell command to discover the actual path at runtime
///   (e.g., `brew --cache`), with fallback static paths if the probe fails.
///   Probe commands have a 2-second timeout to prevent hanging.
/// - **absolutePath**: A fixed absolute filesystem path (e.g., `/tmp/caches`).
///
/// ### Custom Clean Steps
///
/// Some categories (like Simulator Devices) require a specialized cleanup process
/// instead of simple file deletion. The `cleanSteps` property holds optional
/// structured command steps that the `CacheCleaner` runs securely with a 30-second timeout.

import Foundation

/// Risk level classification for cache categories, indicating how safe it is to delete.
enum RiskLevel: String, CaseIterable {
    case safe = "Safe"
    case review = "Review"
    case caution = "Caution"

    var icon: String {
        switch self {
        case .safe: return "checkmark.shield.fill"
        case .review: return "eye.fill"
        case .caution: return "exclamationmark.triangle.fill"
        }
    }

    var color: String {
        switch self {
        case .safe: return "green"
        case .review: return "yellow"
        case .caution: return "red"
        }
    }
}

/// How a cache category discovers its actual path on this machine.
enum PathDiscovery: Hashable {
    /// Static path relative to home directory (original behavior).
    /// Always checked via FileManager.fileExists.
    case staticPath(String)

    /// Run a shell command that outputs the cache path on stdout.
    /// Falls back to `fallbacks` if the command fails or path doesn't exist.
    /// The `requiresTool` is checked via `/usr/bin/which` before probing.
    case probed(command: String, requiresTool: String?, fallbacks: [String])

    /// Absolute path (not relative to home). Used for system-level paths
    /// that live outside ~/
    case absolutePath(String)
}

struct CacheCategory: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let slug: String
    let description: String
    let icon: String
    let discovery: [PathDiscovery]
    let riskLevel: RiskLevel
    let rebuildNote: String
    let defaultSelected: Bool

    /// Optional structured commands to run for cleanup instead of deleting files.
    /// When set, the cleaner runs these commands instead of rm/trash.
    /// Each inner array represents a command and its arguments, executed via /usr/bin/env.
    let cleanSteps: [[String]]?

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: CacheCategory, rhs: CacheCategory) -> Bool { lhs.id == rhs.id }

    // MARK: - Backward compatibility

    /// Legacy init for categories that only use static home-relative paths
    init(
        name: String, slug: String, description: String, icon: String,
        paths: [String], riskLevel: RiskLevel, rebuildNote: String,
        defaultSelected: Bool
    ) {
        self.name = name
        self.slug = slug
        self.description = description
        self.icon = icon
        self.discovery = paths.map { .staticPath($0) }
        self.riskLevel = riskLevel
        self.rebuildNote = rebuildNote
        self.defaultSelected = defaultSelected
        self.cleanSteps = nil
    }

    /// Full init with discovery and optional clean steps
    init(
        name: String, slug: String, description: String, icon: String,
        discovery: [PathDiscovery], riskLevel: RiskLevel, rebuildNote: String,
        defaultSelected: Bool, cleanSteps: [[String]]? = nil
    ) {
        self.name = name
        self.slug = slug
        self.description = description
        self.icon = icon
        self.discovery = discovery
        self.riskLevel = riskLevel
        self.rebuildNote = rebuildNote
        self.defaultSelected = defaultSelected
        self.cleanSteps = cleanSteps
    }

    // MARK: - Path Resolution

    /// Resolve all discovery entries to actual filesystem URLs.
    /// Probed commands are run synchronously with a short timeout.
    var resolvedPaths: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var results: [URL] = []

        for entry in discovery {
            switch entry {
            case .staticPath(let relative):
                let url = home.appendingPathComponent(relative)
                if directoryExists(at: url) {
                    results.append(url)
                }

            case .absolutePath(let path):
                let url = URL(fileURLWithPath: path)
                if directoryExists(at: url) {
                    results.append(url)
                }

            case .probed(let command, let requiresTool, let fallbacks):
                // Check if required tool is installed
                if let tool = requiresTool, !toolExists(tool) {
                    continue
                }

                // Try the probe command
                if let probedPath = runProbe(command),
                   directoryExists(at: URL(fileURLWithPath: probedPath)) {
                    results.append(URL(fileURLWithPath: probedPath))
                    continue
                }

                // Fall through to static fallbacks
                for fallback in fallbacks {
                    let url: URL
                    if fallback.hasPrefix("/") {
                        url = URL(fileURLWithPath: fallback)
                    } else {
                        url = home.appendingPathComponent(fallback)
                    }
                    if directoryExists(at: url) {
                        results.append(url)
                        break // Use first matching fallback
                    }
                }
            }
        }

        return results
    }

    // MARK: - Private Helpers

    private func directoryExists(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func toolExists(_ tool: String) -> Bool {
        let result = shell("/usr/bin/which \(tool)")
        return result != nil && !result!.isEmpty
    }

    private func runProbe(_ command: String) -> String? {
        guard let output = shell(command) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Run a shell command with a 2-second timeout. Returns stdout or nil.
    private func shell(_ command: String) -> String? {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path
        ]

        do {
            try process.run()
        } catch {
            return nil
        }

        // 2-second timeout to prevent hanging on interactive prompts
        let deadline = DispatchTime.now() + .seconds(2)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            group.leave()
        }

        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
