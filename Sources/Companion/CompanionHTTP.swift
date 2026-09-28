import Foundation

/// Turns one HTTP/1.1 request into one response.  No sockets live here, so the
/// pairing rules can be tested without opening a port.
enum CompanionHTTP {
    static func response(request: Data, body: Data, token: String, cleanHandler: ((String) -> (status: Int, body: Data))? = nil) -> Data {
        let text = String(data: request, encoding: .isoLatin1) ?? ""
        let head = text.components(separatedBy: "\r\n\r\n").first ?? text
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            return message(status: 400, reason: "Bad Request", body: Data("Bad Request".utf8))
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return message(status: 400, reason: "Bad Request", body: Data("Bad Request".utf8))
        }
        let method = String(parts[0])
        let path = String(parts[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        guard path == CompanionService.path || path == CompanionService.cleanPath else {
            return message(status: 404, reason: "Not Found", body: Data("Not Found".utf8))
        }

        let presented = bearerToken(in: lines)
        guard CompanionToken.matches(presented, token) else {
            return message(status: 401, reason: "Unauthorized", body: Data("Unauthorized".utf8))
        }

        if path == CompanionService.path {
            guard method == "GET" else {
                return message(status: 405, reason: "Method Not Allowed", body: Data("Method Not Allowed".utf8))
            }
            return message(status: 200, reason: "OK", body: body, type: "application/json; charset=utf-8")
        } else {
            guard method == "POST" else {
                return message(status: 405, reason: "Method Not Allowed", body: Data("Method Not Allowed".utf8))
            }
            if let cleanHandler {
                let (code, resBody) = cleanHandler(presented)
                return message(status: code, reason: code == 200 ? "OK" : "Error", body: resBody, type: "application/json; charset=utf-8")
            } else {
                return message(status: 501, reason: "Not Implemented", body: Data("Clean Not Configured".utf8))
            }
        }
    }

    static func request(token: String) -> Data {
        let lines = [
            "GET \(CompanionService.path) HTTP/1.1",
            "Host: hoghunter",
            "Authorization: Bearer \(token)",
            "Accept: application/json",
            "Connection: close",
            "",
        ]
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    static func cleanRequest(token: String) -> Data {
        let lines = [
            "POST \(CompanionService.cleanPath) HTTP/1.1",
            "Host: hoghunter",
            "Authorization: Bearer \(token)",
            "Accept: application/json",
            "Connection: close",
            "",
        ]
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// Status code and body from a complete HTTP/1.1 response.  Nil when the
    /// bytes are not a response yet.
    static func parseResponse(_ data: Data) -> (status: Int, body: Data)? {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = data.subdata(in: data.startIndex..<range.lowerBound)
        let body = data.subdata(in: range.upperBound..<data.endIndex)
        guard let text = String(data: head, encoding: .isoLatin1) else { return nil }
        let statusLine = text.components(separatedBy: "\r\n").first ?? ""
        let pieces = statusLine.split(separator: " ")
        guard pieces.count >= 2, let status = Int(pieces[1]) else { return nil }
        return (status, body)
    }

    private static func bearerToken(in lines: [String]) -> String {
        for line in lines.dropFirst() {
            let halves = line.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard halves.count == 2, halves[0].caseInsensitiveCompare("Authorization") == .orderedSame else { continue }
            let value = halves[1]
            let prefix = "Bearer "
            guard value.count > prefix.count, value.lowercased().hasPrefix(prefix.lowercased()) else { return "" }
            return String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    private static func message(status: Int, reason: String, body: Data, type: String = "text/plain; charset=utf-8") -> Data {
        let header = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: \(type)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "Cache-Control: no-store",
            "",
        ].joined(separator: "\r\n") + "\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return data
    }
}
