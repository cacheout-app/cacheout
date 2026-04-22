import Foundation

enum Formatters {
    static let byteCount: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static let iso8601: ISO8601DateFormatter = {
        return ISO8601DateFormatter()
    }()
}
