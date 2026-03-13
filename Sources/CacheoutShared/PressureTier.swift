/// Runtime memory pressure classification.
///
/// Derived from the kernel pressure level and available memory at each sample.
/// This changes dynamically as system memory conditions evolve.
///
/// Distinct from ``MemoryTier``, which is a static hardware classification
/// based on installed physical RAM.
public enum PressureTier: String, Codable, Sendable, CaseIterable {
    case normal
    case elevated
    case warning
    case critical

    /// All valid pressure tier strings for config validation.
    /// Derived from enum cases so config and runtime stay in sync.
    /// Includes "warn" as an accepted alias for "warning" (used in spec examples
    /// and kernel pressure level naming).
    public static let validConfigValues: Set<String> = {
        var values = Set(allCases.map(\.rawValue))
        values.insert("warn") // accepted alias for "warning"
        return values
    }()

    /// Normalize a config pressure tier string, mapping aliases to canonical values.
    /// Returns nil if the string is not a valid config value.
    public static func fromConfigValue(_ value: String) -> PressureTier? {
        if value == "warn" { return .warning }
        return PressureTier(rawValue: value)
    }

    /// Classify the current pressure state from the raw kernel level and available memory.
    ///
    /// - Parameters:
    ///   - pressureLevel: Raw value from `kern.memorystatus_vm_pressure_level`
    ///     (0 = normal, 1 = warn, 2 = critical, 4 = urgent).
    ///   - availableMB: Estimated available memory in megabytes,
    ///     computed as `(freePages + inactivePages) * pageSize / 1048576`.
    /// - Returns: The appropriate pressure tier.
    public static func from(pressureLevel: Int32, availableMB: Double) -> PressureTier {
        if pressureLevel >= 4 || availableMB < 512  { return .critical }
        if pressureLevel >= 2 || availableMB < 1500 { return .warning }
        if pressureLevel >= 1 || availableMB < 4000 { return .elevated }
        return .normal
    }
}
