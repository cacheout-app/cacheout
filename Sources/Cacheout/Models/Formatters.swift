import Foundation

enum Formatters {
    static let byteCount: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        return formatter
    }()

    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()
}
