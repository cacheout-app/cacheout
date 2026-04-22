import Foundation

public enum Formatters {
    public static let byteCount: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    public static let iso8601: ISO8601DateFormatter = {
        return ISO8601DateFormatter()
    }()
}
