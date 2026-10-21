import BackstageCore
import SwiftUI

/// Backstage's own look, the same in every app.
enum BackstageStyle {
    /// A teal, so it never takes an app's brand color.
    static let accent = Color(red: 0.15, green: 0.71, blue: 0.81)

    static func color(forStatus status: Int?, failed: Bool) -> Color {
        if failed && status == nil { return .red }
        switch status ?? 0 {
        case 200..<300: return .green
        case 300..<400: return .secondary
        case 400..<500: return .orange
        case 500...: return .red
        default: return .secondary
        }
    }

    /// "509 bytes", "8 KB"; zero is "0 bytes", not "Zero KB".
    static func bytes(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(count))
    }

    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "…" }
        return seconds < 1 ? "\(Int(seconds * 1_000)) ms" : String(format: "%.2f s", seconds)
    }

    static let time: Date.FormatStyle = .dateTime.hour().minute().second()
}

extension NetworkTransaction {
    /// "GET", "WS", or the connection's name.
    var badge: String {
        switch kind {
        case .http: method ?? "GET"
        case .webSocket: "WS"
        case .connection(let name): name
        }
    }

    var title: String {
        if let url {
            let path = url.path().isEmpty ? "/" : url.path()
            return url.query().map { "\(path)?\($0)" } ?? path
        }
        return note ?? kind.title
    }

    var host: String? { url?.host() }

    var statusText: String {
        if let errorDescription, statusCode == nil { return errorDescription }
        if let statusCode { return Self.reasonPhrase(forStatusCode: statusCode).map { "\(statusCode) \($0)" } ?? "\(statusCode)" }
        return isComplete ? "Closed" : "Open"
    }
}

/// Copies text to the clipboard on either platform.
@MainActor
func copyToClipboard(_ text: String) {
    #if os(iOS)
    UIPasteboard.general.string = text
    #elseif os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}
