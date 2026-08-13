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
/// ### Custom Clean Commands
///
/// Some categories (like Simulator Devices) require a specialized cleanup command
/// instead of simple file deletion. The `cleanCommands` property holds optional
/// argv arrays that `CacheCleaner` runs directly via `/usr/bin/env` (never a
/// shell) with a 30-second timeout and a restricted `PATH` — after every
/// resolved root passes `PathGuard` admission (R17).

import Foundation
import Darwin

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

    /// Optional shell commands to run sequentially for cleanup instead of deleting files.
    /// When set, the cleaner runs these commands instead of rm/trash.
    /// The commands run directly via /usr/bin/env.
    let cleanCommands: [[String]]?

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
        self.cleanCommands = nil
    }

    /// Full init with discovery and optional clean command
    init(
        name: String, slug: String, description: String, icon: String,
        discovery: [PathDiscovery], riskLevel: RiskLevel, rebuildNote: String,
        defaultSelected: Bool, cleanCommands: [[String]]? = nil
    ) {
        self.name = name
        self.slug = slug
        self.description = description
        self.icon = icon
        self.discovery = discovery
        self.riskLevel = riskLevel
        self.rebuildNote = rebuildNote
        self.defaultSelected = defaultSelected
        self.cleanCommands = cleanCommands
    }

    // MARK: - Path Resolution

    /// Resolve all discovery entries to actual filesystem URLs, anchored to
    /// `home`: `.staticPath` entries and non-`/`-prefixed probed fallbacks
    /// are appended to it, and probe subprocesses run with `HOME` set to it.
    /// Callers MUST pass the same home their `CategoryAdmissionPolicy` is
    /// anchored to — resolving against one home and admitting against
    /// another silently defeats the injectable-home seam.
    /// Probed commands are run synchronously with a short timeout.
    func resolvedPaths(home: URL) -> [URL] {
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
                if let tool = requiresTool, !toolExists(tool, home: home) {
                    continue
                }

                // Try the probe command
                if let probedPath = runProbe(command, home: home),
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

    private func toolExists(_ tool: String, home: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [tool]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin",
            "HOME": home.path
        ]

        do {
            try process.run()
        } catch {
            return false
        }

        // Bounded wait (2s, the probe-timeout doctrine): `which` answers in
        // milliseconds, and the unbounded `waitUntilExit()` this replaces
        // could block a scan forever when the termination wakeup is missed
        // (see `Process.waitForExit(within:)`).
        guard process.waitForExit(within: 2) else {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }

    private func runProbe(_ command: String, home: URL) -> String? {
        guard let output = shell(command, home: home) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Run a shell command with a 2-second timeout. Returns stdout or nil.
    private func shell(_ command: String, home: URL) -> String? {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin",
            "HOME": home.path
        ]

        do {
            try process.run()
        } catch {
            return nil
        }

        // 2-second timeout to prevent hanging on interactive prompts.
        //
        // Single-threaded on purpose: the previous
        // read-to-EOF-then-`waitUntilExit()`-on-a-global-queue pattern hung
        // when `waitUntilExit` missed its termination wakeup (see
        // `Process.waitForExit(within:)`), so a probe whose command
        // finished in milliseconds timed out and resolved as nil. Instead,
        // poll for exit while draining stdout NON-BLOCKINGLY — the drain
        // preserves the buffer-fill defense (a probe emitting more than
        // the 64 KiB pipe buffer would otherwise block on write and never
        // exit).
        let readFD = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var reachedEOF = false
        var exited = false
        let deadline = DispatchTime.now() + 2.0
        var pollInterval: UInt32 = 1_000 // µs; backs off to 16ms
        while true {
            if !reachedEOF {
                reachedEOF = Self.drainAvailableOutput(from: readFD, into: &data)
            }
            if !exited { exited = !process.isRunning }
            // EOF alone is not exit (terminationStatus needs the exit);
            // exit alone is not EOF (buffered output still needs draining
            // — though once the child is gone EOF follows immediately,
            // because Process closed the parent's write end at launch).
            if exited && reachedEOF { break }
            if DispatchTime.now() >= deadline {
                // Includes the child that exited but handed its stdout to
                // a still-running grandchild (no EOF): nil, as before.
                process.terminate()
                return nil
            }
            usleep(pollInterval)
            pollInterval = min(pollInterval * 2, 16_000)
        }

        guard process.terminationStatus == 0 else { return nil }

        return String(data: data, encoding: .utf8)
    }

    /// Appends whatever is currently readable on `fd` (which must be
    /// `O_NONBLOCK`) to `data`. Returns `true` once EOF is reached, `false`
    /// when the pipe is merely empty right now (`EAGAIN`) or errored.
    private static func drainAvailableOutput(from fd: Int32, into data: inout Data) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
                continue
            }
            if count == 0 { return true } // EOF: every write end closed
            if errno == EINTR { continue }
            return false // EAGAIN/EWOULDBLOCK or error: nothing more now
        }
    }
}

// MARK: - Deterministic bounded subprocess wait

/// `Process.waitUntilExit()` can miss its termination wakeup when several
/// processes are spawned and reaped concurrently (macOS Foundation
/// contention — reproduced on macOS 26: the child exits and is reaped,
/// `isRunning` is already `false`, yet `waitUntilExit` stays blocked
/// indefinitely; ~12-25% of spawns under parallel-test/build load). Every
/// bounded subprocess wait in this module therefore polls `isRunning`
/// under a monotonic deadline instead: the poll observes the same
/// Foundation state `waitUntilExit` gates on, needs no helper thread, and
/// is deterministic under load.
extension Process {
    /// Returns `true` once the process has exited — `terminationStatus`
    /// is then safe to read — or `false` if it is still running when
    /// `timeout` elapses (the caller decides termination policy).
    func waitForExit(within timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + timeout
        var pollInterval: UInt32 = 1_000 // µs; backs off to 16ms
        while isRunning {
            if DispatchTime.now() >= deadline { return false }
            usleep(pollInterval)
            pollInterval = min(pollInterval * 2, 16_000)
        }
        return true
    }
}
