// ProcessEntryDTO.swift
// Data transfer object for per-process memory metrics.
// Wire format: all sizes in bytes.

import Foundation

/// Per-process memory and resource metrics returned by `getProcessList` and `getRosettaProcesses`.
///
/// All memory sizes are in bytes. Jetsam priority and limit come from the kernel's
/// memorystatus priority list; a value of -1 indicates the process was not found
/// in the priority list.
public struct ProcessEntryDTO: Codable, Sendable {

    /// Process ID.
    public let pid: Int32

    /// Process name (from proc_name, truncated to MAXCOMLEN).
    public let name: String

    /// Current physical memory footprint in bytes.
    public let physFootprint: UInt64

    /// Highest physical footprint ever observed for this process, in bytes.
    public let lifetimeMaxFootprint: UInt64

    /// Cumulative page-in count for this process.
    public let pageins: UInt64

    /// Jetsam priority band (-1 if not in priority list).
    public let jetsamPriority: Int32

    /// Jetsam memory limit in MB (-1 if not in priority list).
    public let jetsamLimit: Int32

    /// Whether this process is running under Rosetta 2 translation.
    public let isRosetta: Bool

    /// Ratio of lifetime max footprint to current footprint.
    /// Values near 1.0 suggest the process is at its peak (possible leak).
    /// Values > 1.0 mean the process has shrunk from its peak (normal).
    public let leakIndicator: Double

    // MARK: - Initializer

    public init(
        pid: Int32,
        name: String,
        physFootprint: UInt64,
        lifetimeMaxFootprint: UInt64,
        pageins: UInt64,
        jetsamPriority: Int32,
        jetsamLimit: Int32,
        isRosetta: Bool,
        leakIndicator: Double
    ) {
        self.pid = pid
        self.name = name
        self.physFootprint = physFootprint
        self.lifetimeMaxFootprint = lifetimeMaxFootprint
        self.pageins = pageins
        self.jetsamPriority = jetsamPriority
        self.jetsamLimit = jetsamLimit
        self.isRosetta = isRosetta
        self.leakIndicator = leakIndicator
    }
}
