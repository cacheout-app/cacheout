// SystemStatsDTO.swift
// Data transfer object for system-wide memory statistics.
// Wire format: all sizes in bytes, page counts as raw values.

import Foundation

/// System-wide memory statistics returned by `getSystemStats`.
///
/// All memory sizes are in bytes. Page counts are raw kernel values;
/// multiply by `pageSize` to convert to bytes.
public struct SystemStatsDTO: Codable, Sendable {

    // MARK: - Timestamp

    /// When this snapshot was captured.
    public let timestamp: Date

    // MARK: - VM page counts (from vm_statistics64)

    /// Free pages available for immediate use.
    public let freePages: UInt64

    /// Pages currently in active use.
    public let activePages: UInt64

    /// Pages that have been recently used but are candidates for reclaim.
    public let inactivePages: UInt64

    /// Pages wired into memory (cannot be paged out).
    public let wiredPages: UInt64

    /// Pages held by the in-memory compressor.
    public let compressorPageCount: UInt64

    // MARK: - Compressor stats (from sysctl)

    /// Logical (original/uncompressed) size of data in the compressor, in bytes.
    public let compressedBytes: UInt64

    /// Physical storage used by the compressor, in bytes.
    public let compressorBytesUsed: UInt64

    /// Compression ratio: `compressedBytes / compressorBytesUsed`.
    /// Values > 1.0 indicate effective compression.
    public let compressionRatio: Double

    // MARK: - Page metadata

    /// Kernel page size in bytes (typically 16384 on Apple Silicon).
    public let pageSize: UInt64

    /// Pages marked as purgeable (can be reclaimed without I/O).
    public let purgeableCount: UInt64

    /// File-backed (external) pages.
    public let externalPages: UInt64

    /// Anonymous (internal) pages.
    public let internalPages: UInt64

    // MARK: - Activity counters (cumulative since boot)

    /// Total compression operations.
    public let compressions: UInt64

    /// Total decompression operations.
    public let decompressions: UInt64

    /// Total page-in operations (from disk/swap).
    public let pageins: UInt64

    /// Total page-out operations (to disk/swap).
    public let pageouts: UInt64

    // MARK: - Swap

    /// Swap space currently in use, in bytes.
    public let swapUsedBytes: UInt64

    /// Total swap space available, in bytes.
    public let swapTotalBytes: UInt64

    // MARK: - Pressure and classification

    /// Raw kernel memory pressure level from `kern.memorystatus_vm_pressure_level`.
    /// 0 = normal, 1 = warn, 2 = critical, 4 = urgent.
    public let pressureLevel: Int32

    /// Hardware-based memory tier classification (e.g. "constrained", "moderate").
    public let memoryTier: String

    /// Total installed physical memory, in bytes.
    public let totalPhysicalMemory: UInt64

    // MARK: - Initializer

    public init(
        timestamp: Date,
        freePages: UInt64,
        activePages: UInt64,
        inactivePages: UInt64,
        wiredPages: UInt64,
        compressorPageCount: UInt64,
        compressedBytes: UInt64,
        compressorBytesUsed: UInt64,
        compressionRatio: Double,
        pageSize: UInt64,
        purgeableCount: UInt64,
        externalPages: UInt64,
        internalPages: UInt64,
        compressions: UInt64,
        decompressions: UInt64,
        pageins: UInt64,
        pageouts: UInt64,
        swapUsedBytes: UInt64,
        swapTotalBytes: UInt64,
        pressureLevel: Int32,
        memoryTier: String,
        totalPhysicalMemory: UInt64
    ) {
        self.timestamp = timestamp
        self.freePages = freePages
        self.activePages = activePages
        self.inactivePages = inactivePages
        self.wiredPages = wiredPages
        self.compressorPageCount = compressorPageCount
        self.compressedBytes = compressedBytes
        self.compressorBytesUsed = compressorBytesUsed
        self.compressionRatio = compressionRatio
        self.pageSize = pageSize
        self.purgeableCount = purgeableCount
        self.externalPages = externalPages
        self.internalPages = internalPages
        self.compressions = compressions
        self.decompressions = decompressions
        self.pageins = pageins
        self.pageouts = pageouts
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.pressureLevel = pressureLevel
        self.memoryTier = memoryTier
        self.totalPhysicalMemory = totalPhysicalMemory
    }
}
