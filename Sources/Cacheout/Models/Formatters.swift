import Foundation

enum Formatters {
    // Cached statically for performance to avoid expensive allocations during high-frequency formatting
    static let byteCount: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static let iso8601: ISO8601DateFormatter = {
        return ISO8601DateFormatter()
    }()
}
