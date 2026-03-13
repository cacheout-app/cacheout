// JetsamSnapshotEntryDTO.swift
// Data transfer object for jetsam snapshot entries.
// Wire format: page counts as raw values, sizes in bytes.

import Foundation

/// A single entry from the kernel jetsam snapshot, representing a process
/// that was recently killed or is at risk of being killed by jetsam.
///
/// Returned by `getJetsamSnapshot` as part of a `[JetsamSnapshotEntryDTO]` array.
public struct JetsamSnapshotEntryDTO: Codable, Sendable {

    /// Process ID at the time of the snapshot.
    public let pid: Int32

    /// Process name.
    public let name: String

    /// Jetsam priority band at the time of the snapshot.
    public let priority: Int32

    /// Process state flags from the kernel.
    public let state: UInt32

    /// Total resident pages at the time of the snapshot.
    public let pages: UInt64

    /// Anonymous (internal) pages.
    public let internalPages: UInt64

    /// IOKit-mapped pages.
    public let iokitPages: UInt64

    /// Coalition ID (process group for resource accounting).
    public let coalitionId: UInt64

    /// Human-readable reason the process was killed (or empty if still alive).
    public let killReason: String

    // MARK: - Initializer

    public init(
        pid: Int32,
        name: String,
        priority: Int32,
        state: UInt32,
        pages: UInt64,
        internalPages: UInt64,
        iokitPages: UInt64,
        coalitionId: UInt64,
        killReason: String
    ) {
        self.pid = pid
        self.name = name
        self.priority = priority
        self.state = state
        self.pages = pages
        self.internalPages = internalPages
        self.iokitPages = iokitPages
        self.coalitionId = coalitionId
        self.killReason = killReason
    }
}
