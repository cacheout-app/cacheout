import Foundation

extension ByteCountFormatter {
    static let sharedFile: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

extension ISO8601DateFormatter {
    static let shared: ISO8601DateFormatter = {
        return ISO8601DateFormatter()
    }()
}
