import Darwin
import Foundation
import Network

/// Advertises Hog Hunter on the local network and serves companion telemetry
/// and remote control routes.  The pairing code stays in the request header.
final class CompanionServer: @unchecked Sendable {
    /// The phones paired with this Mac, one token each.
    let devices: CompanionDeviceRegistry
    private let queue = DispatchQueue(label: "hoghunter.companion")
    private var listener: NWListener?
    private var payload = Data()
    private var targets: [String: CompanionTarget] = [:]
    /// Wrong-credential counts per client address.  Touched only on `queue`.
    private var throttle = CompanionAuthThrottle()
    private var token = ""
    private var onStatus: (@Sendable (String) -> Void)?

    /// `devices` defaults to an empty, memory-only registry, so a bare server
    /// in a test starts with no paired phones and writes nothing to disk.
    init(devices: CompanionDeviceRegistry? = nil) {
        self.devices = devices ?? CompanionDeviceRegistry(defaults: nil)
    }

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

    /// Stores the snapshot to serve and the processes behind its rows.  The
    /// phone names a row; these are what that name resolves to.
    func update(snapshot: CompanionSnapshot, targets: [String: CompanionTarget] = [:]) {
        guard let data = try? CompanionJSON.encode(snapshot) else { return }
        queue.async {
            self.payload = data
            self.targets = targets
        }
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
        receive(connection, buffer: Data(), peer: CompanionPeer.from(connection.endpoint))
    }

    typealias Reply = (status: Int, body: Data)

    /// The owner's opt-ins.  Set from the main thread, read on `queue`, so
    /// each sits behind a lock instead of being a bare stored property.
    private let quitFlag = CompanionLocked(false)
    private let cleanFlag = CompanionLocked(false)
    private let editFlag = CompanionLocked(false)

    var allowRemoteQuit: Bool {
        get { quitFlag.value }
        set { quitFlag.value = newValue }
    }
    /// Off until the owner turns on "Allow iPhone to Run Disk Cleaner" in
    /// Settings, or ticks it when approving a phone.
    var allowRemoteClean: Bool {
        get { cleanFlag.value }
        set { cleanFlag.value = newValue }
    }
    /// Called with the live processes behind the row the phone pointed at.
    /// The server resolves the target itself, from the rows it was last
    /// handed, so the store never sees an address it cannot verify.
    /// Off until the owner allows the phone to change cleaner exclusions and
    /// the Mac panel's lookback, grouping and CPU scale.
    var allowRemoteEdit: Bool {
        get { editFlag.value }
        set { editFlag.value = newValue }
    }
    var onRemoteQuit: ((_ target: CompanionTarget, _ force: Bool) -> Reply)? = nil
    var onRemoteTame: ((_ target: CompanionTarget, _ action: String) -> Reply)? = nil
    /// A clean takes minutes.  The handler starts it and calls `completion`
    /// once, when it finishes, from any thread.  It must not block: the
    /// server queue also answers the phone's snapshot polls.
    var onRemoteClean: ((_ completion: @escaping @Sendable (Reply) -> Void) -> Void)? = nil
    var onRemoteExclusionsUpdate: ((CompanionExclusionsUpdateRequest) -> Reply)? = nil
    var onRemoteViewUpdate: ((CompanionViewUpdateRequest) -> Reply)? = nil
    /// Called on the server queue each time a phone fetches the snapshot, so
    /// the host can refresh slow-to-gather data only while someone is looking.
    var onSnapshotServed: (() -> Void)? = nil
    /// Asks the person at the Mac whether `deviceName` may pair.  Called on
    /// the server queue; `reply` may be called from any thread, once.
    var onRemotePair: ((_ deviceName: String, _ reply: @escaping @Sendable (Bool) -> Void) -> Void)? = nil
    /// One approval alert at a time, so a flood of requests cannot stack
    /// alerts on the Mac.  Touched only on `queue`.
    private var pairPending = false
    private var lastPairPromptAt: Date = .distantPast

    /// Pairing waits on a person, so it is answered off the synchronous
    /// router and never holds the queue that serves snapshots.
    private func handlePair(_ connection: NWConnection, deviceName: String, peer: CompanionPeer) {
        let send: @Sendable (Data) -> Void = { response in
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
        // Pairing hands out a credential that can change this Mac, so it is
        // offered only on the local network and Tailscale.
        guard peer.isTrusted else {
            send(CompanionHTTP.untrustedNetworkReply())
            return
        }
        guard let ask = onRemotePair else {
            send(CompanionHTTP.pairResponse(approvedToken: nil))
            return
        }
        guard !pairPending, Date().timeIntervalSince(lastPairPromptAt) >= 5.0 else {
            send(CompanionHTTP.pairBusyResponse())
            return
        }
        pairPending = true
        lastPairPromptAt = Date()
        ask(deviceName) { [weak self] approved in
            guard let self else { return }
            self.queue.async {
                self.pairPending = false
                self.lastPairPromptAt = Date()
                // Each approved phone gets a token of its own, not the shared code.
                send(CompanionHTTP.pairResponse(approvedToken: approved ? self.devices.issue(name: deviceName).token : nil))
            }
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data, peer: CompanionPeer) {
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
                    self.receive(connection, buffer: buffer, peer: peer)
                    return
                }
                if let deviceName = CompanionHTTP.pairDeviceName(in: buffer) {
                    self.handlePair(connection, deviceName: deviceName, peer: peer)
                    return
                }
                if let enrollment = CompanionHTTP.enrollParams(in: buffer) {
                    let reply = self.enroll(code: enrollment.code, deviceName: enrollment.deviceName, peer: peer)
                    connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                switch self.disposition(for: buffer, peer: peer) {
                case .reply(let response):
                    connection.send(content: response, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                case .startClean:
                    self.startClean(on: connection)
                }
            }
        }
    }

    /// Runs `body` on the server queue and returns its value.  Tests use it to
    /// drive routing without opening a socket.
    func syncOnQueue<T>(_ body: () -> T) -> T {
        queue.sync(execute: body)
    }

    /// What to do with one complete request.  A clean is not answered
    /// inline: it runs for minutes, so the connection is held open and the
    /// reply is sent when the Mac is done, while this queue keeps serving
    /// the phone's snapshot polls.
    enum Disposition: Equatable {
        case reply(Data)
        case startClean
    }

    /// Routes one request.  Runs on `queue`; split out so tests can drive it
    /// without opening a socket.
    func disposition(for buffer: Data, peer: CompanionPeer, now: Date = Date()) -> Disposition {
        // A client that keeps presenting wrong credentials is told to wait
        // before anything about the request is looked at.
        if let wait = throttle.retryAfter(for: peer.key, now: now) {
            return .reply(CompanionHTTP.throttledReply(retryAfter: wait))
        }
        var cleanRequested = false
        let response = CompanionHTTP.response(
            request: buffer,
            body: payload,
            token: token,
            cleanHandler: { [weak self] _ in
                guard let self else { return (500, Data("{\"error\": \"Server unavailable\"}".utf8)) }
                guard self.allowRemoteClean else {
                    let res = ["status": "forbidden", "error": "Running the disk cleaner from iPhone is off.  Turn on Allow iPhone to Run Disk Cleaner in Hog Hunter Settings on the Mac."]
                    return (403, (try? JSONSerialization.data(withJSONObject: res)) ?? Data())
                }
                guard self.onRemoteClean != nil else {
                    return (501, Data("{\"error\": \"Clean handler not configured\"}".utf8))
                }
                cleanRequested = true
                // Placeholder: never sent.  `startClean` answers later.
                return (202, Data())
            },
            quitHandler: { [weak self] request, force in
                guard let self else { return (500, Data("{\"error\": \"Server unavailable\"}".utf8)) }
                guard self.allowRemoteQuit else {
                    let res = ["status": "forbidden", "error": "Remote process termination is disabled in Hog Hunter Mac Settings."]
                    return (403, (try? JSONSerialization.data(withJSONObject: res)) ?? Data())
                }
                guard let handler = self.onRemoteQuit else {
                    return (501, Data("{\"error\": \"Quit handler not configured\"}".utf8))
                }
                guard let target = CompanionTargets.resolve(request, in: self.targets) else {
                    let res = CompanionQuitResponse(status: "changed", pid: request.pid ?? 0, name: "", message: nil, error: CompanionTargets.unresolvedMessage(for: request))
                    return (400, (try? JSONEncoder().encode(res)) ?? Data())
                }
                return handler(target, force)
            },
            tameHandler: { [weak self] request, action in
                guard let self else { return (500, Data("{\"error\": \"Server unavailable\"}".utf8)) }
                guard self.allowRemoteQuit else {
                    let res = ["status": "forbidden", "error": "Remote process control is disabled in Hog Hunter Mac Settings."]
                    return (403, (try? JSONSerialization.data(withJSONObject: res)) ?? Data())
                }
                guard let handler = self.onRemoteTame else {
                    return (501, Data("{\"error\": \"Tame handler not configured\"}".utf8))
                }
                guard let target = CompanionTargets.resolve(request, in: self.targets) else {
                    let res = CompanionTameResponse(status: "changed", pid: request.pid ?? 0, name: "", isTamed: false, message: nil, error: CompanionTargets.unresolvedMessage(for: request))
                    return (400, (try? JSONEncoder().encode(res)) ?? Data())
                }
                return handler(target, action)
            },
            exclusionsHandler: { [weak self] req in
                guard let self else { return (500, Data("{\"error\": \"Server unavailable\"}".utf8)) }
                guard self.allowRemoteEdit else { return Self.editRefusal }
                if let handler = self.onRemoteExclusionsUpdate {
                    return handler(req)
                }
                return (501, Data("{\"error\": \"Exclusions handler not configured\"}".utf8))
            },
            viewHandler: { [weak self] req in
                guard let self else { return (500, Data("{\"error\": \"Server unavailable\"}".utf8)) }
                guard self.allowRemoteEdit else { return Self.editRefusal }
                if let handler = self.onRemoteViewUpdate {
                    return handler(req)
                }
                return (501, Data("{\"error\": \"View handler not configured\"}".utf8))
            },
            peerTrusted: peer.isTrusted,
            deviceAuthenticator: { [devices] presented in devices.authenticate(presented, now: now) }
        )
        // 401 is a wrong credential.  404 never got as far as checking one.
        // Anything else means the credential was accepted.
        let status = CompanionHTTP.statusCode(of: response)
        if status == 401 {
            throttle.recordFailure(peer: peer.key, now: now)
        } else if status != 404 {
            throttle.recordSuccess(peer: peer.key)
        }
        if cleanRequested { return .startClean }
        if CompanionHTTP.isSnapshotRequest(buffer), status == 200 {
            onSnapshotServed?()
        }
        return .reply(response)
    }

    /// Trades the shared pairing code for a token of the phone's own.  Runs on
    /// `queue`.  The code is the proof that someone read it off this Mac's
    /// Settings, so a wrong one counts against the throttle like any other
    /// wrong credential, and the route works only for local and Tailscale peers.
    func enroll(code: String, deviceName: String, peer: CompanionPeer, now: Date = Date()) -> Data {
        if let wait = throttle.retryAfter(for: peer.key, now: now) {
            return CompanionHTTP.throttledReply(retryAfter: wait)
        }
        guard peer.isTrusted else {
            return CompanionHTTP.untrustedNetworkReply()
        }
        guard CompanionToken.matches(code, token) else {
            throttle.recordFailure(peer: peer.key, now: now)
            return CompanionHTTP.enrollRejectedReply()
        }
        throttle.recordSuccess(peer: peer.key)
        let issued = devices.issue(name: deviceName, now: now)
        return CompanionHTTP.enrollResponse(token: issued.token, deviceId: issued.device.id)
    }

    /// The answer to an exclusions or view change while the owner has not
    /// allowed phone edits.
    static var editRefusal: Reply {
        let res = ["status": "forbidden", "error": "Changing cleaner exclusions or the panel view from iPhone is off.\u{00A0} Turn on Allow iPhone to Change Exclusions & View in Hog Hunter Settings > iPhone on the Mac."]
        return (403, (try? JSONSerialization.data(withJSONObject: res)) ?? Data())
    }

    /// How long the connection of an unfinished clean is held before the
    /// phone is told to watch the progress instead.
    static let cleanReplyDeadline: TimeInterval = 15 * 60

    private func startClean(on connection: NWConnection) {
        guard let begin = onRemoteClean else {
            connection.send(content: CompanionHTTP.jsonReply(status: 501, body: Data("{\"error\": \"Clean handler not configured\"}".utf8)), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let once = CompanionOneShotReply { data in
            connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
        }
        queue.asyncAfter(deadline: .now() + Self.cleanReplyDeadline) {
            let body = Data(#"{"status":"running","error":"The clean is still running on the Mac.  Watch its progress in the app."}"#.utf8)
            once.send(CompanionHTTP.jsonReply(status: 504, body: body))
        }
        begin { reply in
            once.send(CompanionHTTP.jsonReply(status: reply.status, body: reply.body))
        }
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

/// A value shared between the main thread and the server queue.
final class CompanionLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Sends one reply at most once.  A finishing clean and the deadline timer
/// can both try; whichever arrives first wins.
final class CompanionOneShotReply: @unchecked Sendable {
    private let lock = NSLock()
    private var sent = false
    private let deliver: @Sendable (Data) -> Void

    init(deliver: @escaping @Sendable (Data) -> Void) { self.deliver = deliver }

    func send(_ data: Data) {
        lock.lock()
        let first = !sent
        sent = true
        lock.unlock()
        if first { deliver(data) }
    }
}
