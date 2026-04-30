import Foundation

public extension ByteCountFormatter {
    /// Shared instance to avoid expensive allocations in hot paths and UI updates
    static let sharedFile: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

public extension ISO8601DateFormatter {
    /// Shared instance to avoid expensive allocations
    static let shared: ISO8601DateFormatter = {
        return ISO8601DateFormatter()
    }()
}
