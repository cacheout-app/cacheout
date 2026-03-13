// JetsamPriorityEntryDTO.swift
// Data transfer object for jetsam priority list entries.

import Foundation

/// A single entry from the kernel jetsam priority list, representing a process
/// with its current jetsam priority band and memory limit.
///
/// Returned by `getJetsamPriorityList` as part of a `[JetsamPriorityEntryDTO]` array.
public struct JetsamPriorityEntryDTO: Codable, Sendable {

    /// Process ID.
    public let pid: Int32

    /// Jetsam priority band (0 = idle, higher = more important).
    public let priority: Int32

    /// Jetsam memory limit in MB (-1 if no limit set).
    public let limit: Int32

    // MARK: - Initializer

    public init(
        pid: Int32,
        priority: Int32,
        limit: Int32
    ) {
        self.pid = pid
        self.priority = priority
        self.limit = limit
    }
}
