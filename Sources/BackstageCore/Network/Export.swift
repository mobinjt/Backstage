import Foundation

/// Turning recorded traffic into something to paste or open elsewhere.
public enum NetworkExport {
    /// A `curl` command that repeats the request. Sensitive headers are left out unless asked for.
    public static func curl(_ transaction: NetworkTransaction, sensitiveHeaders: Set<String> = [], includingSensitive: Bool = false) -> String? {
        guard transaction.kind == .http, let url = transaction.url else { return nil }
        var parts = ["curl"]
        let method = transaction.method ?? "GET"
        if method != "GET" {
            parts.append("-X \(method)")
        }
        for (field, value) in transaction.requestHeaders.sorted(by: { $0.key < $1.key }) {
            let shown = !includingSensitive && sensitiveHeaders.contains(field.lowercased()) ? "<hidden>" : value
            parts.append("-H \(quoted("\(field): \(shown)"))")
        }
        if let body = transaction.requestBody, !body.data.isEmpty {
            parts.append("--data-binary \(quoted(String(decoding: body.data, as: UTF8.self)))")
        }
        parts.append(quoted(url.absoluteString))
        return parts.joined(separator: " \\\n  ")
    }

    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// An HTTP Archive (HAR 1.2) of the HTTP transactions, which opens in Proxyman, Charles and
    /// browsers' developer tools. Connections are left out: HAR has no place for them.
    public static func har(_ transactions: [NetworkTransaction], sensitiveHeaders: Set<String> = [], includingSensitive: Bool = false, creator: String = "Backstage") throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func headers(_ fields: [String: String]) -> [[String: String]] {
            fields.sorted { $0.key < $1.key }.map { field, value in
                ["name": field, "value": !includingSensitive && sensitiveHeaders.contains(field.lowercased()) ? "<hidden>" : value]
            }
        }
        let entries: [[String: Any]] = transactions
            .filter { $0.kind == .http }
            .sorted { $0.startDate < $1.startDate }
            .map { transaction in
                let url = transaction.url
                let query = URLComponents(url: url ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false)?.queryItems ?? []
                var request: [String: Any] = [
                    "method": transaction.method ?? "GET",
                    "url": url?.absoluteString ?? "",
                    "httpVersion": "HTTP/1.1",
                    "headers": headers(transaction.requestHeaders),
                    "queryString": query.map { ["name": $0.name, "value": $0.value ?? ""] },
                    "cookies": [],
                    "headersSize": -1,
                    "bodySize": transaction.requestBody?.size ?? 0
                ]
                if let body = transaction.requestBody {
                    request["postData"] = [
                        "mimeType": transaction.requestHeaders.first { $0.key.lowercased() == "content-type" }?.value ?? "application/octet-stream",
                        "text": String(decoding: body.data, as: UTF8.self)
                    ]
                }
                let mimeType = transaction.responseHeaders.first { $0.key.lowercased() == "content-type" }?.value ?? ""
                var content: [String: Any] = ["size": transaction.responseBody?.size ?? 0, "mimeType": mimeType]
                if let body = transaction.responseBody {
                    if let text = String(data: body.data, encoding: .utf8) {
                        content["text"] = text
                    } else {
                        content["text"] = body.data.base64EncodedString()
                        content["encoding"] = "base64"
                    }
                }
                let milliseconds = (transaction.duration ?? 0) * 1_000
                var entry: [String: Any] = [
                    "startedDateTime": formatter.string(from: transaction.startDate),
                    "time": milliseconds,
                    "request": request,
                    "response": [
                        "status": transaction.statusCode ?? 0,
                        "statusText": transaction.statusCode.map { HTTPURLResponse.localizedString(forStatusCode: $0) } ?? "",
                        "httpVersion": "HTTP/1.1",
                        "headers": headers(transaction.responseHeaders),
                        "cookies": [],
                        "content": content,
                        "redirectURL": "",
                        "headersSize": -1,
                        "bodySize": transaction.responseBody?.size ?? -1
                    ] as [String: Any],
                    "cache": [:] as [String: Any],
                    "timings": ["send": 0, "wait": milliseconds, "receive": 0]
                ]
                if let error = transaction.errorDescription {
                    entry["comment"] = error
                }
                return entry
            }
        let har: [String: Any] = [
            "log": [
                "version": "1.2",
                "creator": ["name": creator, "version": "1.0"],
                "entries": entries
            ] as [String: Any]
        ]
        return try JSONSerialization.data(withJSONObject: har, options: [.prettyPrinted, .sortedKeys])
    }

    /// Everything recorded, connections included, as Backstage's own JSON.
    public static func json(_ transactions: [NetworkTransaction], sensitiveHeaders: Set<String> = [], includingSensitive: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let shown = includingSensitive ? transactions : transactions.map { $0.hidingHeaders(sensitiveHeaders) }
        return try encoder.encode(shown)
    }
}

extension NetworkTransaction {
    /// A copy with the values of these headers (compared without case) replaced.
    public func hidingHeaders(_ fields: Set<String>) -> NetworkTransaction {
        var copy = self
        copy.requestHeaders = copy.requestHeaders.reduce(into: [:]) { $0[$1.key] = fields.contains($1.key.lowercased()) ? "<hidden>" : $1.value }
        copy.responseHeaders = copy.responseHeaders.reduce(into: [:]) { $0[$1.key] = fields.contains($1.key.lowercased()) ? "<hidden>" : $1.value }
        return copy
    }
}
