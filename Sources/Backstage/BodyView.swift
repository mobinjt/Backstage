import BackstageCore
import SwiftUI

/// A body shown the best way it can be: pretty JSON, an image, text, or hex.
struct BodyView: View {
    let content: NetworkTransaction.Body
    let contentType: String?

    enum Style: String, CaseIterable, Identifiable {
        case formatted = "Formatted", raw = "Raw", hex = "Hex"
        var id: String { rawValue }
    }

    @State private var style = Style.formatted
    @State private var filter = ""

    var body: some View {
        if content.data.isEmpty {
            Text("\(BackstageStyle.bytes(content.size)), not kept: older bodies are dropped to save space.")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Style", selection: $style) {
                    ForEach(Style.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if let image = image, style == .formatted {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 320)
                } else {
                    TextField("Filter lines", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .font(.footnote)
                    ScrollView(.horizontal) {
                        Text(shownText)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if content.isTruncated {
                    Text("Cut at \(BackstageStyle.bytes(content.data.count)) of \(BackstageStyle.bytes(content.size)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var text: String {
        switch style {
        case .formatted: Self.prettyJSON(content.data) ?? String(data: content.data, encoding: .utf8) ?? Self.hex(content.data)
        case .raw: String(data: content.data, encoding: .utf8) ?? Self.hex(content.data)
        case .hex: Self.hex(content.data)
        }
    }

    private var shownText: String {
        // Very long bodies are slow to draw in full.
        let text = text
        let lines = filter.isEmpty ? text : text.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.localizedCaseInsensitiveContains(filter) }.joined(separator: "\n")
        return lines.count > 200_000 ? String(lines.prefix(200_000)) + "\n…" : lines
    }

    private var image: Image? {
        guard contentType?.lowercased().hasPrefix("image/") == true else { return nil }
        #if os(iOS)
        return UIImage(data: content.data).map(Image.init(uiImage:))
        #elseif os(macOS)
        return NSImage(data: content.data).map(Image.init(nsImage:))
        #endif
    }

    static func prettyJSON(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) else { return nil }
        return String(data: pretty, encoding: .utf8)
    }

    /// 16 bytes a line, with an offset and the printable characters.
    static func hex(_ data: Data) -> String {
        let shown = data.prefix(64 * 1_024)
        var lines: [String] = []
        var offset = 0
        for chunk in stride(from: shown.startIndex, to: shown.endIndex, by: 16) {
            let bytes = shown[chunk..<min(chunk + 16, shown.endIndex)]
            let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = String(bytes.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%08x  ", offset) + hex.padding(toLength: 47, withPad: " ", startingAt: 0) + "  " + ascii)
            offset += 16
        }
        if data.count > shown.count {
            lines.append("…")
        }
        return lines.joined(separator: "\n")
    }
}
