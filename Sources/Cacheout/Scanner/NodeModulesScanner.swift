/// # NodeModulesScanner — Recursive node_modules Finder
///
/// An `actor` that recursively searches common developer project directories
/// for `node_modules` folders. Designed to find abandoned or stale dependencies
/// that consume significant disk space.
///
/// ## Search Strategy
///
/// 1. Scans predefined root directories (`Documents`, `Developer`, `Projects`, etc.)
///    in parallel using `TaskGroup`.
/// 2. Recursively descends into subdirectories up to `maxDepth` (default: 6).
/// 3. When a `node_modules` directory is found, calculates its size and records it
///    **without recursing further** (projects with node_modules won't have nested projects).
/// 4. Skips noise directories (`.git`, `.build`, `DerivedData`, etc.) for performance.
///
/// ## Deduplication
///
/// Results are deduplicated by absolute path (using `Set<String>` insertion) to handle
/// cases where search roots overlap (e.g., `~/Documents/Code` and `~/Code` pointing
/// to the same location via symlinks).
///
/// ## Performance
///
/// - Parallel scanning of root directories via `TaskGroup`
/// - Early termination when `node_modules` found (no deeper recursion)
/// - Skip list eliminates most irrelevant directories
/// - `maxDepth` cap prevents excessive filesystem traversal

import Foundation

// ⚡ BOLT OPTIMIZATION:
// Using `struct` instead of `actor` prevents task serialization.
// An `actor` forces `withTaskGroup` tasks calling its methods to run sequentially
// on its executor. Changing to a stateless `struct` allows `FileManager` heavy I/O
// tasks to execute concurrently across threads.
struct NodeModulesScanner {
    private let fileManager = FileManager.default

    /// Common directories where developers keep projects
    private static let searchRoots: [String] = [
        "Documents",
        "Developer",
        "Projects",
        "Code",
        "Sites",
        "Desktop",
        "Dropbox",
        "repos",
        "src",
        "work",
    ]

    /// Directories to skip during recursive search
    private static let skipDirs: Set<String> = [
        ".Trash", ".git", ".hg", "node_modules", ".build",
        "DerivedData", "Pods", ".next", "dist", "build",
        "Library", ".cache", ".npm", ".yarn",
    ]

    func scan(maxDepth: Int = 6) async -> [NodeModulesItem] {
        let home = fileManager.homeDirectoryForCurrentUser
        var allItems: [NodeModulesItem] = []

        // Scan each search root in parallel
        await withTaskGroup(of: [NodeModulesItem].self) { group in
            for root in Self.searchRoots {
                let rootURL = home.appendingPathComponent(root)
                guard fileManager.fileExists(atPath: rootURL.path) else { continue }
                group.addTask {
                    await self.findNodeModules(in: rootURL, maxDepth: maxDepth)
                }
            }
            for await items in group {
                allItems.append(contentsOf: items)
            }
        }

        // Deduplicate by path and sort by size
        var seen = Set<String>()
        return allItems
            .filter { seen.insert($0.nodeModulesPath.path).inserted }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private func findNodeModules(in directory: URL, maxDepth: Int, currentDepth: Int = 0) async -> [NodeModulesItem] {
        guard currentDepth < maxDepth else { return [] }

        var results: [NodeModulesItem] = []
        let nodeModulesURL = directory.appendingPathComponent("node_modules")

        // Check if this directory contains node_modules
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: nodeModulesURL.path, isDirectory: &isDir), isDir.boolValue {
            let size = directorySize(at: nodeModulesURL)
            if size > 0 {
                let lastMod = try? fileManager.attributesOfItem(atPath: nodeModulesURL.path)[.modificationDate] as? Date
                let projectName = directory.lastPathComponent
                results.append(NodeModulesItem(
                    projectName: projectName,
                    projectPath: directory,
                    nodeModulesPath: nodeModulesURL,
                    sizeBytes: size,
                    lastModified: lastMod
                ))
            }
            // Don't recurse into projects that have node_modules — they won't have nested projects
            return results
        }

        // Recurse into subdirectories
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return results }

        for item in contents {
            let name = item.lastPathComponent
            guard !Self.skipDirs.contains(name) else { continue }
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let subResults = await findNodeModules(in: item, maxDepth: maxDepth, currentDepth: currentDepth + 1)
            results.append(contentsOf: subResults)
        }

        return results
    }

    private func directorySize(at url: URL) -> Int64 {
        var total: Int64 = 0
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
               let size = values.totalFileAllocatedSize {
                total += Int64(size)
            }
        }
        return total
    }
}
