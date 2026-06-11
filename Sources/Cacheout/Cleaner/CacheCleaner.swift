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
import Darwin

actor CacheCleaner {
    private let fileManager = FileManager.default

    func clean(results: [ScanResult], nodeModules: [NodeModulesItem] = [], moveToTrash: Bool) async -> CleanupReport {
        var cleaned: [(category: String, bytesFreed: Int64)] = []
        var errors: [(category: String, error: String)] = []

        // Clean cache categories
        for result in results where result.isSelected && !result.isEmpty {
            var categoryFreed: Int64 = 0

            // If the category has custom clean commands, run them sequentially instead of deleting files
            if let commands = result.category.cleanCommands {
                do {
                    for command in commands {
                        try runCleanCommand(command)
                    }
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
                            try await removeContents(of: url)
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

        // Clean selected node_modules.
        // Move-to-Trash stays sequential because trashItem is @MainActor and the
        // Finder serializes Trash operations anyway. Permanent delete is parallelized
        // with the same sliding-window pattern as removeContents(of:).
        let selectedNodeModules = nodeModules.filter { $0.isSelected }
        if moveToTrash {
            for item in selectedNodeModules {
                do {
                    try await trashItem(item.nodeModulesPath)
                    cleaned.append(("node_modules: \(item.projectName)", item.sizeBytes))
                    logCleanup(category: "node_modules/\(item.projectName)", bytesFreed: item.sizeBytes)
                } catch {
                    errors.append(("node_modules: \(item.projectName)", error.localizedDescription))
                }
            }
        } else {
            let results = await removeNodeModulesConcurrently(items: selectedNodeModules)
            for (item, error) in results {
                if let error {
                    errors.append(("node_modules: \(item.projectName)", error.localizedDescription))
                } else {
                    cleaned.append(("node_modules: \(item.projectName)", item.sizeBytes))
                    logCleanup(category: "node_modules/\(item.projectName)", bytesFreed: item.sizeBytes)
                }
            }
        }

        return CleanupReport(cleaned: cleaned, errors: errors)
    }

    /// Run a custom clean command via /usr/bin/env with a 30-second timeout.
    private func runCleanCommand(_ args: [String]) throws {
        guard !args.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
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

    private func removeContents(of url: URL) async throws {
        let contents = try fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        )
        let currentFileManager = self.fileManager

        // ⚡ Bolt Optimization: Parallelize bulk file deletion using a TaskGroup with a sliding window.
        // Synchronous disk I/O is offloaded to a GCD background queue to avoid thread pool exhaustion.
        let maxConcurrency = 8
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = contents.makeIterator()

            for _ in 0..<maxConcurrency {
                if let item = iterator.next() {
                    group.addTask {
                        try await Self.removeItemConcurrently(at: item, fileManager: currentFileManager)
                    }
                }
            }

            while try await group.next() != nil {
                if let nextItem = iterator.next() {
                    group.addTask {
                        try await Self.removeItemConcurrently(at: nextItem, fileManager: currentFileManager)
                    }
                }
            }
        }
    }

    /// Parallel per-item deletion with isolated error handling. Each result preserves
    /// its input ordering so callers can build consistent cleaned/errors arrays.
    private func removeNodeModulesConcurrently(
        items: [NodeModulesItem]
    ) async -> [(item: NodeModulesItem, error: Error?)] {
        guard !items.isEmpty else { return [] }
        let currentFileManager = self.fileManager
        let maxConcurrency = 8

        return await withTaskGroup(
            of: (Int, Error?).self,
            returning: [(item: NodeModulesItem, error: Error?)].self
        ) { group in
            var iterator = items.indices.makeIterator()

            for _ in 0..<min(maxConcurrency, items.count) {
                guard let index = iterator.next() else { break }
                let path = items[index].nodeModulesPath
                group.addTask {
                    do {
                        try await Self.removeItemConcurrently(at: path, fileManager: currentFileManager)
                        return (index, nil)
                    } catch {
                        return (index, error)
                    }
                }
            }

            var results = Array<(item: NodeModulesItem, error: Error?)?>(repeating: nil, count: items.count)

            while let (index, error) = await group.next() {
                results[index] = (items[index], error)
                if let nextIndex = iterator.next() {
                    let path = items[nextIndex].nodeModulesPath
                    group.addTask {
                        do {
                            try await Self.removeItemConcurrently(at: path, fileManager: currentFileManager)
                            return (nextIndex, nil)
                        } catch {
                            return (nextIndex, error)
                        }
                    }
                }
            }

            return results.compactMap { $0 }
        }
    }

    nonisolated private static func removeItemConcurrently(at url: URL, fileManager: FileManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try fileManager.removeItem(at: url)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
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
        let size = ByteCountFormatter.sharedFile.string(fromByteCount: bytesFreed)
        let entry = "[\(ISO8601DateFormatter.shared.string(from: Date()))] Cleaned \(category): \(size)\n"
        let data = entry.data(using: .utf8) ?? Data()

        _ = logFile.withUnsafeFileSystemRepresentation { pathPtr -> Int32 in
            guard let ptr = pathPtr else { return -1 }
            let fd = open(ptr, O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd != -1 {
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                if #available(macOS 10.15.4, *) {
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                } else {
                    handle.write(data)
                    handle.closeFile()
                }
            }
            return fd
        }
    }
}
