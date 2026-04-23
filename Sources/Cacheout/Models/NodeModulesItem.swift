/// # NodeModulesItem — node_modules Directory Info
///
/// Represents a single discovered `node_modules` directory with its parent project
/// context. Used by the `NodeModulesSection` view to display per-project cleanup options.
///
/// ## Staleness Detection
///
/// A node_modules directory is considered "stale" if its modification date is older
/// than 30 days. This helps users identify abandoned projects whose dependencies can
/// be safely removed. The `staleBadge` property provides a human-readable age label
/// (e.g., "3mo old", "1y old") for display in the UI.
///
/// ## Size
///
/// Size is calculated using `totalFileAllocatedSize` (same as `CacheScanner`) to
/// accurately report actual disk consumption including sparse file handling.

import Foundation

struct NodeModulesItem: Identifiable, Hashable {
    let id = UUID()
    let projectName: String
    let projectPath: URL
    let nodeModulesPath: URL
    let sizeBytes: Int64
    let lastModified: Date?
    var isSelected: Bool = false

    var formattedSize: String {
        Formatters.byteCountFormatter.string(fromByteCount: sizeBytes)
    }

    var daysSinceModified: Int? {
        guard let date = lastModified else { return nil }
        return Calendar.current.dateComponents([.day], from: date, to: Date()).day
    }

    /// Stale if node_modules hasn't been touched in 30+ days
    var isStale: Bool {
        guard let days = daysSinceModified else { return false }
        return days > 30
    }

    var staleBadge: String? {
        guard let days = daysSinceModified else { return nil }
        if days > 365 { return "\(days / 365)y old" }
        if days > 30 { return "\(days / 30)mo old" }
        return nil
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: NodeModulesItem, rhs: NodeModulesItem) -> Bool { lhs.id == rhs.id }
}
