import Darwin
import Foundation
import Network

/// Advertises Hog Hunter on the local network and answers one read-only
/// snapshot route.  The pairing code stays in the request header.
final class CompanionServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "hoghunter.companion")
    private var listener: NWListener?
    private var payload = Data()
    private var token = ""
    private var onStatus: (@Sendable (String) -> Void)?

    static let defaultPort: UInt16 = 24240
    private(set) var activePort: UInt16 = defaultPort

    func start(name: String, peerID: String, token: String, onStatus: @escaping @Sendable (String) -> Void) {
        queue.async {
            self.token = token
            self.onStatus = onStatus
            if self.listener != nil {
                onStatus("Sharing on port \(self.activePort)")
                return
            }
            do {
                let preferredPort = NWEndpoint.Port(rawValue: Self.defaultPort) ?? .any
                let listener: NWListener
                if let fixed = try? NWListener(using: .tcp, on: preferredPort) {
                    listener = fixed
                } else {
                    listener = try NWListener(using: .tcp, on: .any)
                }
                var service = NWListener.Service(name: Self.serviceName(from: name), type: CompanionService.type)
                service.txtRecordObject = NWTXTRecord(["ver": "1", "id": peerID])
                listener.service = service
                listener.stateUpdateHandler = { [weak self] state in
                    self?.queue.async {
                        switch state {
                        case .ready:
                            if let p = self?.listener?.port?.rawValue {
                                self?.activePort = p
                            }
                            self?.onStatus?("Sharing on port \(self?.activePort ?? Self.defaultPort)")
                        case .failed(let error):
                            self?.listener?.cancel()
                            self?.listener = nil
                            self?.onStatus?("Could not share.  \(error.localizedDescription)")
                        case .waiting(let error):
                            self?.onStatus?("Waiting to share.  \(error.localizedDescription)")
                        default:
                            break
                        }
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: self.queue)
                self.listener = listener
            } catch {
                onStatus("Could not share.  \(error.localizedDescription)")
            }
        }
    }

    func update(snapshot: CompanionSnapshot) {
        guard let data = try? CompanionJSON.encode(snapshot) else { return }
        queue.async { self.payload = data }
    }

    func updateToken(_ token: String) {
        queue.async { self.token = token }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.onStatus?("Off")
        }
    }

    /// Bonjour instance names are a single label, at most 63 bytes.
    static func serviceName(from host: String) -> String {
        let first = host.split(separator: ".").first.map(String.init) ?? host
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Hog Hunter" : trimmed
        return String(name.prefix(63))
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    var allowRemoteQuit = false
    var onRemoteQuit: ((_ pid: pid_t, _ force: Bool) -> (status: Int, body: Data))? = nil
    var onRemoteTame: ((_ pid: pid_t, _ action: String) -> (status: Int, body: Data))? = nil

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            self.queue.async {
                var buffer = buffer
                if let data { buffer.append(data) }
                let finished = buffer.range(of: Data("\r\n\r\n".utf8)) != nil
                    || isComplete
                    || error != nil
                    || buffer.count >= 8_192
                guard finished else {
                    self.receive(connection, buffer: buffer)
                    return
                }
                let response = CompanionHTTP.response(
                    request: buffer,
                    body: self.payload,
                    token: self.token,
                    cleanHandler: { [weak self] _ in
                        self?.handleRemoteClean() ?? (status: 500, body: Data("{}".utf8))
                    },
                    quitHandler: { [weak self] pid, force in
                        guard let self else { return (500, Data("{\"error\": \"Server unavailable\"}".utf8)) }
                        guard self.allowRemoteQuit else {
                            let res = ["status": "forbidden", "error": "Remote process termination is disabled in Hog Hunter Mac Settings."]
                            return (403, (try? JSONSerialization.data(withJSONObject: res)) ?? Data())
                        }
                        if let handler = self.onRemoteQuit {
                            return handler(pid, force)
                        }
                        return (501, Data("{\"error\": \"Quit handler not configured\"}".utf8))
                    },
                    tameHandler: { [weak self] pid, action in
                        guard let self else { return (500, Data("{\"error\": \"Server unavailable\"}".utf8)) }
                        guard self.allowRemoteQuit else {
                            let res = ["status": "forbidden", "error": "Remote process control is disabled in Hog Hunter Mac Settings."]
                            return (403, (try? JSONSerialization.data(withJSONObject: res)) ?? Data())
                        }
                        if let handler = self.onRemoteTame {
                            return handler(pid, action)
                        }
                        return (501, Data("{\"error\": \"Tame handler not configured\"}".utf8))
                    }
                )
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func handleRemoteClean() -> (status: Int, body: Data) {
        let cleaner = DiskCleaner()
        let exclusions = CleanerExclusions.load()
        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data = Data("{}".utf8)
        Task {
            let scanReport = await cleaner.scan(tier: .standard, exclusions: exclusions)
            let itemsToClean = scanReport.categories.flatMap { $0.items }.filter(\.isSelected)
            let cleanResult = await cleaner.clean(items: itemsToClean, tier: .standard, createSnapshot: true, exclusions: exclusions)
            let responseObj = CompanionCleanResponse(
                status: "completed",
                bytesReclaimed: cleanResult.bytesReclaimed,
                formattedBytesReclaimed: cleanResult.formattedBytesReclaimed,
                itemsRemoved: cleanResult.itemsRemoved,
                snapshotCreated: cleanResult.snapshotName != nil,
                snapshotName: cleanResult.snapshotName,
                tier: cleanResult.tier.title
            )
            if let encoded = try? JSONEncoder().encode(responseObj) {
                resultData = encoded
            }
            semaphore.signal()
        }
        semaphore.wait()
        return (status: 200, body: resultData)
    }

    /// Detects current local LAN IPv4 and Tailscale IPv4 addresses on the host.
    static func detectHostAddresses() -> (localIP: String?, tailscaleIP: String?) {
        var local: String? = nil
        var tailscale: String? = nil

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return (nil, nil)
        }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            guard let sa = ptr.pointee.ifa_addr else { continue }
            let flags = Int32(ptr.pointee.ifa_flags)

            guard (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
                  (flags & IFF_LOOPBACK) == 0,
                  sa.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: hostname)
            let ifName = String(cString: ptr.pointee.ifa_name)

            if isTailscaleIP(ip) || (ifName.hasPrefix("utun") && ip.hasPrefix("100.")) {
                tailscale = ip
            } else if local == nil && (ifName.hasPrefix("en") || ifName.hasPrefix("wi")) {
                local = ip
            }
        }
        return (local, tailscale)
    }

    private static func isTailscaleIP(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts[0] == 100 else { return false }
        return parts[1] >= 64 && parts[1] <= 127
    }
}
