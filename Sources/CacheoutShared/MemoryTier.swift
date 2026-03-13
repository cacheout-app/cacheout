import Darwin

/// Hardware-based memory tier classification.
///
/// Tiers are derived from **physical RAM** (`hw.memsize`) using half-open ranges (in GB).
/// This is a static classification — it never changes at runtime and involves **no hysteresis**.
///
/// ### Rationale
/// - **constrained (< 12 GB):** 8 GB machines. macOS itself consumes ~3-4 GB, leaving
///   limited headroom. Aggressive cache management is essential to avoid memory pressure.
/// - **moderate (12..<20 GB):** 16 GB machines. Comfortable for typical workloads but
///   memory-intensive apps can push into pressure. Conservative cache policies recommended.
/// - **comfortable (20..<48 GB):** 24/32 GB machines. Ample room for caches and buffers
///   without risking jetsam events under normal use.
/// - **abundant (48..<96 GB):** 64 GB machines. Large working sets and generous caching
///   are safe; pressure events are rare outside extreme workloads.
/// - **extreme (96+ GB):** 96/128+ GB configurations. Essentially unconstrained; cache
///   eviction can be very relaxed.
///
/// The 12 GB boundary (not 16) is a conservative policy choice: on 16 GB
/// unified-memory Macs, treating the full 16 GB as "moderate" headroom would
/// be optimistic given real-world working-set sizes and OS overhead.
public enum MemoryTier: String, Codable, Sendable {
    case constrained
    case moderate
    case comfortable
    case abundant
    case extreme

    /// Detect the memory tier for the current machine based on physical RAM.
    ///
    /// Uses `hw.memsize` via `sysctl`, which reports total physical memory in bytes.
    /// Falls back to `.constrained` if the sysctl call fails (defensive default).
    public static func detect() -> MemoryTier {
        var memsize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        let result = sysctlbyname("hw.memsize", &memsize, &size, nil, 0)

        guard result == 0 else {
            // Defensive: treat unknown hardware as constrained to avoid over-caching.
            return .constrained
        }

        let gigabytes = memsize / (1024 * 1024 * 1024)

        switch gigabytes {
        case 0..<12:
            return .constrained
        case 12..<20:
            return .moderate
        case 20..<48:
            return .comfortable
        case 48..<96:
            return .abundant
        default:
            return .extreme
        }
    }
}
