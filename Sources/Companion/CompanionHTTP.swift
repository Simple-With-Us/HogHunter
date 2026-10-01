import Foundation

/// Turns one HTTP/1.1 request into one response.  No sockets live here, so the
/// pairing rules can be tested without opening a port.
enum CompanionHTTP {
    static func response(
        request: Data,
        body: Data,
        token: String,
        cleanHandler: ((String) -> (status: Int, body: Data))? = nil,
        quitHandler: ((_ pid: pid_t, _ force: Bool) -> (status: Int, body: Data))? = nil
    ) -> Data {
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
        let fullPath = String(parts[1])
        let path = fullPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        guard path == CompanionService.path || path == CompanionService.cleanPath || path == CompanionService.quitPath else {
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
        } else if path == CompanionService.cleanPath {
            guard method == "POST" else {
                return message(status: 405, reason: "Method Not Allowed", body: Data("Method Not Allowed".utf8))
            }
            if let cleanHandler {
                let (code, resBody) = cleanHandler(presented)
                return message(status: code, reason: code == 200 ? "OK" : "Error", body: resBody, type: "application/json; charset=utf-8")
            } else {
                return message(status: 501, reason: "Not Implemented", body: Data("Clean Not Configured".utf8))
            }
        } else if path == CompanionService.quitPath {
            guard method == "POST" else {
                return message(status: 405, reason: "Method Not Allowed", body: Data("Method Not Allowed".utf8))
            }
            guard let quitHandler else {
                return message(status: 501, reason: "Not Implemented", body: Data("Quit Not Configured".utf8))
            }
            var targetPid: pid_t? = nil
            var isForce = false
            if fullPath.contains("?") {
                let query = String(fullPath.split(separator: "?", maxSplits: 1)[1])
                for param in query.split(separator: "&") {
                    let kv = param.split(separator: "=", maxSplits: 1)
                    if kv.count == 2 {
                        let k = String(kv[0])
                        let v = String(kv[1])
                        if k == "pid", let p = Int32(v) { targetPid = p }
                        if k == "force" { isForce = (v.lowercased() == "true" || v == "1") }
                    }
                }
            }
            if targetPid == nil, let range = request.range(of: Data("\r\n\r\n".utf8)) {
                let bodyData = request.subdata(in: range.upperBound..<request.endIndex)
                if let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                    if let p = json["pid"] as? Int { targetPid = Int32(p) }
                    else if let p = json["pid"] as? Int32 { targetPid = p }
                    if let f = json["force"] as? Bool { isForce = f }
                }
            }
            guard let pid = targetPid else {
                return message(status: 400, reason: "Bad Request", body: Data("{\"error\": \"Missing pid parameter\"}".utf8), type: "application/json; charset=utf-8")
            }
            let (code, resBody) = quitHandler(pid, isForce)
            return message(status: code, reason: code == 200 ? "OK" : "Error", body: resBody, type: "application/json; charset=utf-8")
        }
        return message(status: 404, reason: "Not Found", body: Data("Not Found".utf8))
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

    static func quitRequest(token: String, pid: Int32, force: Bool = false) -> Data {
        let lines = [
            "POST \(CompanionService.quitPath)?pid=\(pid)&force=\(force) HTTP/1.1",
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
