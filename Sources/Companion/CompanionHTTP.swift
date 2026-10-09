import Foundation

/// Turns one HTTP/1.1 request into one response.  No sockets live here, so the
/// pairing rules can be tested without opening a port.
enum CompanionHTTP {
    static func response(
        request: Data,
        body: Data,
        token: String,
        cleanHandler: ((String) -> (status: Int, body: Data))? = nil,
        quitHandler: ((_ request: CompanionProcessRequest, _ force: Bool) -> (status: Int, body: Data))? = nil,
        tameHandler: ((_ request: CompanionProcessRequest, _ action: String) -> (status: Int, body: Data))? = nil,
        exclusionsHandler: ((CompanionExclusionsUpdateRequest) -> (status: Int, body: Data))? = nil,
        viewHandler: ((CompanionViewUpdateRequest) -> (status: Int, body: Data))? = nil
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
        guard path == CompanionService.path
            || path == CompanionService.cleanPath
            || path == CompanionService.quitPath
            || path == CompanionService.tamePath
            || path == CompanionService.exclusionsPath
            || path == CompanionService.viewPath else {
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
            var isForce = false
            let processRequest = parseProcessRequest(fullPath: fullPath, request: request) { key, value in
                if key == "force" { isForce = (value.lowercased() == "true" || value == "1") }
            } bodyField: { json in
                if let f = json["force"] as? Bool { isForce = f }
            }
            guard processRequest.isAddressed else {
                return message(status: 400, reason: "Bad Request", body: Data("{\"error\": \"Missing row or pid parameter\"}".utf8), type: "application/json; charset=utf-8")
            }
            let (code, resBody) = quitHandler(processRequest, isForce)
            return message(status: code, reason: reason(for: code), body: resBody, type: "application/json; charset=utf-8")
        } else if path == CompanionService.tamePath {
            guard method == "POST" else {
                return message(status: 405, reason: "Method Not Allowed", body: Data("Method Not Allowed".utf8))
            }
            guard let tameHandler else {
                return message(status: 501, reason: "Not Implemented", body: Data("Tame Not Configured".utf8))
            }
            var action = "tame"
            let processRequest = parseProcessRequest(fullPath: fullPath, request: request) { key, value in
                if key == "action" { action = value }
            } bodyField: { json in
                if let a = json["action"] as? String { action = a }
            }
            guard processRequest.isAddressed else {
                return message(status: 400, reason: "Bad Request", body: Data("{\"error\": \"Missing row or pid parameter\"}".utf8), type: "application/json; charset=utf-8")
            }
            let (code, resBody) = tameHandler(processRequest, action)
            return message(status: code, reason: reason(for: code), body: resBody, type: "application/json; charset=utf-8")
        } else if path == CompanionService.exclusionsPath {
            guard method == "POST" else {
                return message(status: 405, reason: "Method Not Allowed", body: Data("Method Not Allowed".utf8))
            }
            guard let exclusionsHandler else {
                return message(status: 501, reason: "Not Implemented", body: Data("Exclusions Not Configured".utf8))
            }
            var updateReq = CompanionExclusionsUpdateRequest()
            if fullPath.contains("?") {
                let query = String(fullPath.split(separator: "?", maxSplits: 1)[1])
                for param in query.split(separator: "&") {
                    let kv = param.split(separator: "=", maxSplits: 1)
                    if kv.count == 2 {
                        let k = String(kv[0])
                        let v = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                        if k == "toggleCategory" { updateReq.toggleCategory = v }
                        if k == "addPath" { updateReq.addPath = v }
                        if k == "removePath" { updateReq.removePath = v }
                    }
                }
            }
            if let range = request.range(of: Data("\r\n\r\n".utf8)) {
                let bodyData = request.subdata(in: range.upperBound..<request.endIndex)
                if let decoded = try? JSONDecoder().decode(CompanionExclusionsUpdateRequest.self, from: bodyData) {
                    if decoded.toggleCategory != nil { updateReq.toggleCategory = decoded.toggleCategory }
                    if decoded.addPath != nil { updateReq.addPath = decoded.addPath }
                    if decoded.removePath != nil { updateReq.removePath = decoded.removePath }
                }
            }
            let (code, resBody) = exclusionsHandler(updateReq)
            return message(status: code, reason: code == 200 ? "OK" : "Error", body: resBody, type: "application/json; charset=utf-8")
        } else if path == CompanionService.viewPath {
            guard method == "POST" else {
                return message(status: 405, reason: "Method Not Allowed", body: Data("Method Not Allowed".utf8))
            }
            guard let viewHandler else {
                return message(status: 501, reason: "Not Implemented", body: Data("View Not Configured".utf8))
            }
            var updateReq = CompanionViewUpdateRequest()
            if fullPath.contains("?") {
                let query = String(fullPath.split(separator: "?", maxSplits: 1)[1])
                for param in query.split(separator: "&") {
                    let kv = param.split(separator: "=", maxSplits: 1)
                    if kv.count == 2 {
                        let k = String(kv[0])
                        let v = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                        if k == "window" { updateReq.window = v }
                        if k == "grouping" { updateReq.grouping = v }
                        if k == "cpuScale" || k == "scale" { updateReq.cpuScale = v }
                    }
                }
            }
            if let range = request.range(of: Data("\r\n\r\n".utf8)) {
                let bodyData = request.subdata(in: range.upperBound..<request.endIndex)
                if let decoded = try? JSONDecoder().decode(CompanionViewUpdateRequest.self, from: bodyData) {
                    if decoded.window != nil { updateReq.window = decoded.window }
                    if decoded.grouping != nil { updateReq.grouping = decoded.grouping }
                    if decoded.cpuScale != nil { updateReq.cpuScale = decoded.cpuScale }
                }
            }
            let (code, resBody) = viewHandler(updateReq)
            return message(status: code, reason: code == 200 ? "OK" : "Error", body: resBody, type: "application/json; charset=utf-8")
        }
        return message(status: 404, reason: "Not Found", body: Data("Not Found".utf8))
    }

    /// A JSON reply built outside the router, for answers that come later
    /// (a finished clean) rather than inline.
    static func jsonReply(status: Int, body: Data) -> Data {
        message(status: status, reason: reason(for: status), body: body, type: "application/json; charset=utf-8")
    }

    static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 429: return "Too Many Requests"
        case 501: return "Not Implemented"
        case 504: return "Gateway Timeout"
        default: return status >= 500 ? "Server Error" : "Error"
        }
    }

    /// True for `GET /v1/snapshot`, whatever its auth outcome.
    static func isSnapshotRequest(_ request: Data) -> Bool {
        let text = String(data: request.prefix(512), encoding: .isoLatin1) ?? ""
        guard let line = text.components(separatedBy: "\r\n").first else { return false }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return false }
        return parts[1].split(separator: "?", maxSplits: 1).first.map(String.init) == CompanionService.path
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

    // MARK: - Approve-on-Mac pairing
    //
    // A phone that has no code asks the Mac to approve it.  This is the only
    // route without a bearer token, so it carries nothing but a display name
    // and it never touches the snapshot.  The server answers it on its own
    // path (see CompanionServer) because the answer waits on a person.

    /// Longest device name the Mac will show in the approval alert.
    static let maxDeviceNameLength = 40

    static func pairRequest(deviceName: String) -> Data {
        let lines = [
            "POST \(CompanionService.pairPath)?device=\(queryAllowedValue(sanitizedDeviceName(deviceName))) HTTP/1.1",
            "Host: hoghunter",
            "Accept: application/json",
            "Connection: close",
            "",
        ]
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// The device name when `request` is a pairing request, otherwise nil.
    /// Only POST counts; anything else falls through to the normal router.
    static func pairDeviceName(in request: Data) -> String? {
        let text = String(data: request, encoding: .isoLatin1) ?? ""
        guard let requestLine = text.components(separatedBy: "\r\n").first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "POST" else { return nil }
        let pieces = parts[1].split(separator: "?", maxSplits: 1)
        guard pieces.first.map(String.init) == CompanionService.pairPath else { return nil }
        var name = ""
        if pieces.count == 2 {
            for pair in pieces[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2, kv[0] == "device" {
                    name = String(kv[1]).removingPercentEncoding ?? ""
                }
            }
        }
        let clean = sanitizedDeviceName(name)
        return clean.isEmpty ? "An iPhone" : clean
    }

    /// Strips control characters and caps the length, so a hostile name
    /// cannot stretch or spoof the Mac's alert.
    static func sanitizedDeviceName(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let text = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(maxDeviceNameLength))
    }

    /// JSON reply for a pairing request.
    static func pairResponse(approvedToken: String?) -> Data {
        if let approvedToken {
            let body = (try? JSONSerialization.data(withJSONObject: ["token": approvedToken])) ?? Data()
            return message(status: 200, reason: "OK", body: body, type: "application/json; charset=utf-8")
        }
        let body = Data(#"{"error":"Pairing was not approved on the Mac."}"#.utf8)
        return message(status: 403, reason: "Forbidden", body: body, type: "application/json; charset=utf-8")
    }

    /// Reply when another approval alert is already open on the Mac.
    static func pairBusyResponse() -> Data {
        let body = Data(#"{"error":"The Mac is already showing a pairing request."}"#.utf8)
        return message(status: 429, reason: "Too Many Requests", body: body, type: "application/json; charset=utf-8")
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

    /// Reads which process or app a quit or tame request addresses, from the
    /// query string first and the JSON body second.  `extraQuery` and
    /// `bodyField` let each route pick up its own parameters in the same pass.
    private static func parseProcessRequest(
        fullPath: String,
        request: Data,
        extraQuery: (_ key: String, _ value: String) -> Void,
        bodyField: (_ json: [String: Any]) -> Void
    ) -> CompanionProcessRequest {
        var result = CompanionProcessRequest()
        if fullPath.contains("?") {
            let query = String(fullPath.split(separator: "?", maxSplits: 1)[1])
            for param in query.split(separator: "&") {
                let kv = param.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                let k = String(kv[0])
                let v = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                if k == "pid", let p = Int32(v) { result.pid = p }
                if k == "row" { result.rowId = v }
                extraQuery(k, v)
            }
        }
        if !result.isAddressed, let range = request.range(of: Data("\r\n\r\n".utf8)) {
            let bodyData = request.subdata(in: range.upperBound..<request.endIndex)
            if let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                if let p = json["pid"] as? Int { result.pid = Int32(truncatingIfNeeded: p) }
                if let r = json["row"] as? String { result.rowId = r }
                bodyField(json)
            }
        }
        if result.rowId?.isEmpty == true { result.rowId = nil }
        return result
    }

    static func quitRequest(token: String, pid: Int32, rowId: String? = nil, force: Bool = false) -> Data {
        let rowParam = rowId.map { "&row=\(queryAllowedValue($0))" } ?? ""
        let lines = [
            "POST \(CompanionService.quitPath)?pid=\(pid)\(rowParam)&force=\(force) HTTP/1.1",
            "Host: hoghunter",
            "Authorization: Bearer \(token)",
            "Accept: application/json",
            "Connection: close",
            "",
        ]
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    static func tameRequest(token: String, pid: Int32, rowId: String? = nil, action: String = "tame") -> Data {
        let rowParam = rowId.map { "&row=\(queryAllowedValue($0))" } ?? ""
        let lines = [
            "POST \(CompanionService.tamePath)?pid=\(pid)\(rowParam)&action=\(queryAllowedValue(action)) HTTP/1.1",
            "Host: hoghunter",
            "Authorization: Bearer \(token)",
            "Accept: application/json",
            "Connection: close",
            "",
        ]
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }


    static func queryAllowedValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ";&=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func exclusionsRequest(token: String, toggleCategory: String? = nil, addPath: String? = nil, removePath: String? = nil) -> Data {
        var queryItems: [String] = []
        if let toggleCategory { queryItems.append("toggleCategory=\(queryAllowedValue(toggleCategory))") }
        if let addPath {
            queryItems.append("addPath=\(queryAllowedValue(addPath))")
        }
        if let removePath {
            queryItems.append("removePath=\(queryAllowedValue(removePath))")
        }
        let queryString = queryItems.isEmpty ? "" : "?" + queryItems.joined(separator: "&")
        let lines = [
            "POST \(CompanionService.exclusionsPath)\(queryString) HTTP/1.1",
            "Host: hoghunter",
            "Authorization: Bearer \(token)",
            "Accept: application/json",
            "Connection: close",
            "",
        ]
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    static func viewRequest(token: String, window: String? = nil, grouping: String? = nil, cpuScale: String? = nil) -> Data {
        var queryItems: [String] = []
        if let window { queryItems.append("window=\(queryAllowedValue(window))") }
        if let grouping { queryItems.append("grouping=\(queryAllowedValue(grouping))") }
        if let cpuScale { queryItems.append("cpuScale=\(queryAllowedValue(cpuScale))") }
        let queryString = queryItems.isEmpty ? "" : "?" + queryItems.joined(separator: "&")
        let lines = [
            "POST \(CompanionService.viewPath)\(queryString) HTTP/1.1",
            "Host: hoghunter",
            "Authorization: Bearer \(token)",
            "Accept: application/json",
            "Connection: close",
            "",
        ]
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// Status code and body from a complete HTTP/1.1 response.  Nil when the
    /// bytes are not a response yet.  A buffer that contains the header break
    /// but fewer body bytes than `Content-Length` is still incomplete: the
    /// first TCP segment of a snapshot often ends there, and treating it as
    /// the whole reply makes the phone fail pairing.
    static func parseResponse(_ data: Data) -> (status: Int, body: Data)? {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = data.subdata(in: data.startIndex..<range.lowerBound)
        let rawBody = data.subdata(in: range.upperBound..<data.endIndex)
        guard let text = String(data: head, encoding: .isoLatin1) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let statusLine = lines.first ?? ""
        let pieces = statusLine.split(separator: " ")
        guard pieces.count >= 2, let status = Int(pieces[1]) else { return nil }
        var declaredLength: Int?
        for line in lines.dropFirst() {
            let halves = line.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard halves.count == 2, halves[0].caseInsensitiveCompare("Content-Length") == .orderedSame else { continue }
            declaredLength = Int(halves[1])
            break
        }
        let body: Data
        if let declaredLength {
            guard declaredLength >= 0, rawBody.count >= declaredLength else { return nil }
            body = rawBody.prefix(declaredLength)
        } else {
            body = rawBody
        }
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
