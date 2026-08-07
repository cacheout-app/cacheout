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
    /// The configured search root (container) this item was discovered under
    /// — origin provenance (R14). Nil only for items constructed outside a
    /// scan (fixtures/tests); the scanner always populates it.
    let originContainer: URL?
    var isSelected: Bool = false

    init(
        projectName: String,
        projectPath: URL,
        nodeModulesPath: URL,
        sizeBytes: Int64,
        lastModified: Date?,
        originContainer: URL? = nil,
        isSelected: Bool = false
    ) {
        self.projectName = projectName
        self.projectPath = projectPath
        self.nodeModulesPath = nodeModulesPath
        self.sizeBytes = sizeBytes
        self.lastModified = lastModified
        self.originContainer = originContainer
        self.isSelected = isSelected
    }

    var formattedSize: String {
        ByteCountFormatter.sharedFile.string(fromByteCount: sizeBytes)
    }

    var daysSinceModified: Int? { Self.daysSince(modified: lastModified) }

    /// Stale if node_modules hasn't been touched in 30+ days
    var isStale: Bool { Self.isStale(daysSinceModified: daysSinceModified) }

    var staleBadge: String? {
        Self.staleAge(daysSinceModified: daysSinceModified).map { "\($0) old" }
    }

    // MARK: Staleness helpers (fn-2.2)
    //
    // The SAME math the instance properties always used, extracted as
    // statics so the `SpaceScanner` mapping in `NodeModulesScanner` derives
    // `ReclaimableItem.isStale` and the evidence age phrase from ONE source
    // of truth — a threshold drift between GUI badge and protocol policy
    // would silently break "Select Stale" (fn-2.4).

    static func daysSince(modified date: Date?) -> Int? {
        guard let date else { return nil }
        return Calendar.current.dateComponents([.day], from: date, to: Date()).day
    }

    /// The 30-day staleness threshold — `staleBadge`'s "mo old" boundary and
    /// the selection policy's `isStale` are the same predicate.
    static func isStale(daysSinceModified days: Int?) -> Bool {
        guard let days else { return false }
        return days > 30
    }

    /// Human age token ("3mo", "1y") for items past the staleness threshold;
    /// nil when fresh or unknown. `staleBadge` renders it as "3mo old"; the
    /// protocol mapping's evidence renders it as "last touched 3mo ago".
    static func staleAge(daysSinceModified days: Int?) -> String? {
        guard let days else { return nil }
        if days > 365 { return "\(days / 365)y" }
        if days > 30 { return "\(days / 30)mo" }
        return nil
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: NodeModulesItem, rhs: NodeModulesItem) -> Bool { lhs.id == rhs.id }
}
