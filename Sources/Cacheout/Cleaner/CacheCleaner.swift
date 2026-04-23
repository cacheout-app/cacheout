/// # CacheCleaner — Cache Deletion Handler
///
/// An `actor` that handles the actual deletion of cache files and directories.
/// Supports two deletion modes: permanent removal and move-to-Trash (recoverable).
///
/// ## Deletion Modes
///
/// - **Permanent delete** (`moveToTrash: false`): Uses `FileManager.removeItem()`.
///   Faster but irreversible. Contents of the directory are removed individually
///   (the directory itself is preserved) so the tool/app can recreate it.
///
/// - **Move to Trash** (`moveToTrash: true`): Uses `FileManager.trashItem()`.
///   Items appear in Finder's Trash and can be recovered. Requires `@MainActor`
///   because `trashItem` interacts with the Finder process.
///
/// ## Custom Clean Commands
///
/// Categories with a `cleanCommand` (e.g., Simulator Devices) bypass file deletion
/// entirely. The command runs via `/bin/bash -c` with a 30-second timeout and a
/// restricted `PATH` environment. If the command times out, the process is terminated
/// and an error is reported.
///
/// ## Cleanup Logging
///
/// Every cleanup action is logged to `~/.cacheout/cleanup.log` with ISO 8601
/// timestamps and byte counts. The log directory is created if it doesn't exist.
/// Log writes are append-mode to preserve history across sessions.
///
/// ## Error Handling
///
/// Errors are collected per-category rather than aborting the entire cleanup.
/// The returned `CleanupReport` contains both successful cleanups and errors,
/// allowing the UI to display partial results.

import Foundation
import AppKit

actor CacheCleaner {
    private let fileManager = FileManager.default

    func clean(results: [ScanResult], nodeModules: [NodeModulesItem] = [], moveToTrash: Bool) async -> CleanupReport {
        var cleaned: [(category: String, bytesFreed: Int64)] = []
        var errors: [(category: String, error: String)] = []

        // Clean cache categories
        for result in results where result.isSelected && !result.isEmpty {
            var categoryFreed: Int64 = 0

            // If the category has a custom clean command, run it instead of deleting files
            if let command = result.category.cleanCommand {
                do {
                    try runCleanCommand(command)
                    categoryFreed = result.sizeBytes
                } catch {
                    errors.append((result.category.name, error.localizedDescription))
                }
            } else {
                let paths = result.category.resolvedPaths

                for url in paths {
                    do {
                        if moveToTrash {
                            try await trashDirectory(url)
                        } else {
                            try removeContents(of: url)
                        }
                        categoryFreed += result.sizeBytes
                    } catch {
                        errors.append((result.category.name, error.localizedDescription))
                    }
                }
            }

            if categoryFreed > 0 {
                cleaned.append((result.category.name, categoryFreed))
            }

            logCleanup(category: result.category.name, bytesFreed: categoryFreed)
        }

        // Clean selected node_modules
        for item in nodeModules where item.isSelected {
            do {
                if moveToTrash {
                    try await trashItem(item.nodeModulesPath)
                } else {
                    try fileManager.removeItem(at: item.nodeModulesPath)
                }
                cleaned.append(("node_modules: \(item.projectName)", item.sizeBytes))
                logCleanup(category: "node_modules/\(item.projectName)", bytesFreed: item.sizeBytes)
            } catch {
                errors.append(("node_modules: \(item.projectName)", error.localizedDescription))
            }
        }

        return CleanupReport(cleaned: cleaned, errors: errors)
    }

    /// Run a custom clean command via /bin/bash with a 30-second timeout.
    private func runCleanCommand(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path
        ]

        try process.run()

        let deadline = DispatchTime.now() + .seconds(30)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            group.leave()
        }

        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            throw NSError(domain: "CacheCleaner", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Clean command timed out after 30s"])
        }

        guard process.terminationStatus == 0 else {
            throw NSError(domain: "CacheCleaner", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Clean command exited with status \(process.terminationStatus)"])
        }
    }

    private func removeContents(of url: URL) throws {
        let contents = try fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        )
        for item in contents {
            try fileManager.removeItem(at: item)
        }
    }

    @MainActor
    private func trashItem(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    @MainActor
    private func trashDirectory(_ url: URL) throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        )
        for item in contents {
            try FileManager.default.trashItem(at: item, resultingItemURL: nil)
        }
    }

    private func logCleanup(category: String, bytesFreed: Int64) {
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cacheout")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let logFile = logDir.appendingPathComponent("cleanup.log")
        let size = Formatters.byteCountFormatter.string(fromByteCount: bytesFreed)
        let entry = "[\(Formatters.iso8601.string(from: Date()))] Cleaned \(category): \(size)\n"

        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(entry.data(using: .utf8) ?? Data())
            handle.closeFile()
        } else {
            try? entry.write(to: logFile, atomically: true, encoding: .utf8)
        }
    }
}
