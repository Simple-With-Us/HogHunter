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
    private var detailPayload: Data?
    private var targets: [String: CompanionTarget] = [:]
    /// Wrong-credential counts per client address.  Touched only on `queue`.
    private var throttle = CompanionAuthThrottle()
    /// Last successful enroll per client address.  Touched only on `queue`.
    /// A loop handing the code back must not mint phones fast enough to push
    /// the owner's phones past the 32-device LRU.  A person pairs once; a
    /// repeat within the minute waits.
    private var lastEnrollSuccess: [String: Date] = [:]
    private static let enrollSuccessCooldown: TimeInterval = 60
    private var token = ""
    private var onStatus: (@Sendable (String) -> Void)?

    /// `devices` defaults to an empty, memory-only registry, so a bare server
    /// in a test starts with no paired phones and writes nothing to disk.
    init(devices: CompanionDeviceRegistry? = nil) {
        self.devices = devices ?? CompanionDeviceRegistry(defaults: nil)
    }

    static let defaultPort: UInt16 = 24240
    private(set) var activePort: UInt16 = defaultPort

    /// `advertise`, `preferredPort` and `loopbackOnly` exist for tests, which
    /// listen on a throwaway port, on loopback only, without publishing a
    /// Bonjour service.  The app uses the defaults.
    func start(
        name: String,
        peerID: String,
        token: String,
        advertise: Bool = true,
        preferredPort: UInt16? = CompanionServer.defaultPort,
        loopbackOnly: Bool = false,
        onStatus: @escaping @Sendable (String) -> Void
    ) {
        queue.async {
            self.token = token
            self.onStatus = onStatus
            if self.listener != nil {
                onStatus("Sharing on port \(self.activePort)")
                return
            }
            do {
                let preferred = preferredPort.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
                let parameters = NWParameters.tcp
                if loopbackOnly { parameters.requiredInterfaceType = .loopback }
                let listener: NWListener
                if let fixed = try? NWListener(using: parameters, on: preferred) {
                    listener = fixed
                } else {
                    listener = try NWListener(using: parameters, on: .any)
                }
                if advertise {
                    var service = NWListener.Service(name: Self.serviceName(from: name), type: CompanionService.type)
                    service.txtRecordObject = NWTXTRecord(["ver": "1", "id": peerID])
                    listener.service = service
                }
                listener.stateUpdateHandler = { [weak self] state in
                    self?.queue.async {
                        switch state {
                        case .ready:
                            if let p = self?.listener?.port?.rawValue {
                                self?.activePort = p
                            }
                            self?.onStatus?("Sharing on port \(self?.activePort ?? Self.defaultPort)")
                        case .failed:
                            self?.listener?.cancel()
                            self?.listener = nil
                            self?.onStatus?("Could not share.\u{00A0} Check the port and try again.")
                        case .waiting:
                            self?.onStatus?("Waiting to share.\u{00A0} Retrying.")
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
                onStatus("Could not share.\u{00A0} Check the port and try again.")
            }
        }
    }

    /// Stores the snapshot to serve and the processes behind its rows.  The
    /// phone names a row; these are what that name resolves to.
    /// `detailed`, when given, is what a phone's own token on the local network
    /// or Tailscale reads in place of `snapshot`.  The shared pairing code, and
    /// anyone arriving from outside, read `snapshot`, so anything that can name
    /// a folder or a server belongs only in `detailed`.
    func update(snapshot: CompanionSnapshot, detailed: CompanionSnapshot? = nil, targets: [String: CompanionTarget] = [:]) {
        guard let data = try? CompanionJSON.encode(snapshot) else { return }
        let detail = detailed.flatMap { try? CompanionJSON.encode($0) }
        queue.async {
            self.payload = data
            self.detailPayload = detail
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
        var result = name
        while result.utf8.count > 63 {
            result = String(result.dropLast())
        }
        return result
    }

    /// How long a client has to send a whole request.  A reply that is held
    /// open on purpose (a clean, a sample) starts counting after this.
    static let requestDeadline: TimeInterval = 15

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        let waiting = CompanionLocked(true)
        queue.asyncAfter(deadline: .now() + Self.requestDeadline) {
            if waiting.value { connection.cancel() }
        }
        receive(connection, buffer: Data(), peer: CompanionPeer.from(connection.endpoint), waiting: waiting)
    }

    typealias Reply = (status: Int, body: Data)

    /// The owner's opt-ins.  Set from the main thread, read on `queue`, so
    /// each sits behind a lock instead of being a bare stored property.
    private let quitFlag = CompanionLocked(false)
    private let cleanFlag = CompanionLocked(false)
    private let editFlag = CompanionLocked(false)
    private let maintainFlag = CompanionLocked(false)
    private let maintainRunningFlag = CompanionLocked(false)
    private let serverControlFlag = CompanionLocked(false)
    private let serverActionBusyFlag = CompanionLocked(false)

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
    /// Off until the owner turns on "Allow iPhone to Run Maintenance" in
    /// Settings.  Not offered in the pairing alert: a run can retire old git
    /// worktrees and run maintenance on remote servers, so the owner grants
    /// it on purpose, in Settings only.
    var allowRemoteMaintain: Bool {
        get { maintainFlag.value }
        set { maintainFlag.value = newValue }
    }
    /// Off until the owner turns on both Allow iPhone to Control the Server and
    /// Allow iPhone to See Server Status in Settings.  Not offered in the
    /// pairing alert.
    var allowRemoteServerControl: Bool {
        get { serverControlFlag.value }
        set { serverControlFlag.value = newValue }
    }
    /// Runs one server action off this queue and calls `completion` once, from
    /// any thread.  Set by the host.  The router allows one at a time.
    var onRemoteServerAction: ((_ request: CompanionServerActionRequest, _ device: String, _ completion: @escaping @Sendable (Reply) -> Void) -> Void)? = nil
    /// Hears a server control request refused at the gate, for the Mac's log.
    var onServerControlRefused: ((_ device: String, _ path: String, _ outcome: String) -> Void)? = nil
    /// Whether a Maintain run is going on the Mac, whoever started it.
    /// The host keeps it current; the router also sets it when it accepts a
    /// phone's request, so two quick taps cannot both start a run.
    var maintainRunning: Bool {
        get { maintainRunningFlag.value }
        set { maintainRunningFlag.value = newValue }
    }
    var onRemoteQuit: ((_ target: CompanionTarget, _ force: Bool) -> Reply)? = nil
    var onRemoteTame: ((_ target: CompanionTarget, _ action: String) -> Reply)? = nil
    /// A clean takes minutes.  The handler starts it and calls `completion`
    /// once, when it finishes, from any thread.  It must not block: the
    /// server queue also answers the phone's snapshot polls.
    var onRemoteClean: ((_ request: CompanionCleanRequest?, _ completion: @escaping @Sendable (Reply) -> Void) -> Void)? = nil
    /// Starts a scan for the cleaner.  Answers at once (the scan runs on the
    /// Mac and the phone reads its progress from the report); `completion`
    /// may be called from any thread.
    var onRemoteCleanScan: ((_ request: CompanionCleanScanRequest, _ completion: @escaping @Sendable (Reply) -> Void) -> Void)? = nil
    /// The cleaner's last scan, its progress and the cleanup history.
    var onRemoteCleanReport: ((_ completion: @escaping @Sendable (Reply) -> Void) -> Void)? = nil
    var onRemoteExclusionsUpdate: ((CompanionExclusionsUpdateRequest) -> Reply)? = nil
    var onRemoteViewUpdate: ((CompanionViewUpdateRequest) -> Reply)? = nil
    /// Refresh interval, alerts and the webhook.  Called on the server queue
    /// with values the router has not yet checked: the handler validates them.
    var onRemoteSettings: ((CompanionSettingsUpdateRequest) -> Reply)? = nil
    /// Sample for 3 Seconds takes longer than a request should hold the
    /// server queue, so the handler starts it and calls `completion` once,
    /// from any thread, when the report is written.
    var onRemoteSample: ((_ target: CompanionTarget, _ completion: @escaping @Sendable (Reply) -> Void) -> Void)? = nil
    /// Starts a Maintain run.  Called on the server queue, only when the
    /// opt-in is on and no run is going.  It must answer at once, without
    /// waiting for the run: the run takes minutes, the server queue also
    /// serves snapshot polls, and the phone watches the snapshot instead.
    var onRemoteMaintainRun: ((_ kind: String) -> Reply)? = nil
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
    ///
    /// Repeat requesters wait per address before they may prompt the Mac
    /// again.  Trusted peers count per key only, never toward the global
    /// cap, so one spammer cannot lock out the owner.
    func pairThrottleWait(for peerKey: String, now: Date = Date()) -> Int? {
        throttle.retryAfter(for: peerKey, now: now, appliesGlobal: false)
    }

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
        // Pairing prompts interrupt the person at the Mac, so repeat
        // requesters are throttled per address like any other credential
        // route.  Trusted peers count per key only, never toward the
        // global cap, so one spammer cannot lock out the owner.
        let now = Date()
        if let wait = pairThrottleWait(for: peer.key, now: now) {
            send(CompanionHTTP.throttledReply(retryAfter: wait))
            return
        }
        guard let ask = onRemotePair else {
            send(CompanionHTTP.pairResponse(approvedToken: nil))
            return
        }
        // If a previous pair prompt was pending for more than 90 seconds, clear it so
        // an expired/abandoned request cannot permanently block future pairing attempts.
        if pairPending && Date().timeIntervalSince(lastPairPromptAt) >= 90.0 {
            pairPending = false
        }
        guard !pairPending, Date().timeIntervalSince(lastPairPromptAt) >= 5.0 else {
            throttle.recordFailure(peer: peer.key, now: now, countsTowardGlobal: false)
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

    private func receive(_ connection: NWConnection, buffer: Data, peer: CompanionPeer, waiting: CompanionLocked<Bool>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            self.queue.async {
                var buffer = buffer
                if let data { buffer.append(data) }
                // A request with a body is not whole until the body is: the
                // headers can arrive in one read and the body in the next.
                let completeness = CompanionHTTP.completeness(of: buffer)
                let finished = completeness != .needsMore || isComplete || error != nil
                guard finished else {
                    self.receive(connection, buffer: buffer, peer: peer, waiting: waiting)
                    return
                }
                waiting.value = false
                // A connection that closed or failed before the request was
                // whole is not a request.  Routing it would act on a body that
                // never arrived, or raise the pairing alert for a half line.
                if completeness == .needsMore {
                    connection.cancel()
                    return
                }
                if completeness == .tooLarge {
                    connection.send(content: CompanionHTTP.payloadTooLargeReply(), completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                // Only a loopback peer (a tunnel daemon on this Mac) may name
                // its client in a forwarded header; other peers' are ignored.
                // The socket's own addresses, read here because an accepted
                // connection has no path until it is ready.
                let effectivePeer = peer
                    .provingTailscaleArrival(remote: connection.endpoint, local: connection.currentPath?.localEndpoint)
                    .resolvingForwardedClient(in: buffer)
                if let deviceName = CompanionHTTP.pairDeviceName(in: buffer) {
                    self.handlePair(connection, deviceName: deviceName, peer: effectivePeer)
                    return
                }
                if let enrollment = CompanionHTTP.enrollParams(in: buffer) {
                    let reply = self.enroll(code: enrollment.code, deviceName: enrollment.deviceName, peer: effectivePeer)
                    connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                switch self.disposition(for: buffer, peer: effectivePeer) {
                case .reply(let response):
                    connection.send(content: response, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                case .startClean(let request):
                    self.startClean(request, on: connection)
                case .startCleanScan(let request):
                    self.startCleanScan(request, on: connection)
                case .startCleanReport:
                    self.startCleanReport(on: connection)
                case .startSample(let target):
                    self.startSample(target, on: connection)
                case .startServerAction(let request, let device):
                    self.startServerAction(request, device: device, on: connection)
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
        case startClean(CompanionCleanRequest?)
        /// A scan or a report is answered from the main actor, which the router
        /// must not wait on, so these are held for a moment the same way.
        case startCleanScan(CompanionCleanScanRequest)
        case startCleanReport
        /// A sample takes at least its three seconds, so it is held the same way.
        case startSample(CompanionTarget)
        /// A server action goes over SSH, so it is held the same way.  The
        /// device is the paired phone's name, for the Mac's log.
        case startServerAction(CompanionServerActionRequest, device: String)
    }

    /// Routes one request.  Runs on `queue`; split out so tests can drive it
    /// without opening a socket.
    func disposition(for buffer: Data, peer: CompanionPeer, now: Date = Date()) -> Disposition {
        // A client that keeps presenting wrong credentials is told to wait
        // before anything about the request is looked at.
        if let wait = throttle.retryAfter(for: peer.key, now: now, appliesGlobal: !peer.isTrusted) {
            return .reply(CompanionHTTP.throttledReply(retryAfter: wait))
        }
        var cleanRequested: CompanionCleanRequest??
        var scanRequested: CompanionCleanScanRequest?
        var reportRequested = false
        var sampleRequested: CompanionTarget?
        var serverActionRequested: CompanionServerActionRequest?
        var authenticatedDevice = ""
        let response = CompanionHTTP.response(
            request: buffer,
            body: payload,
            detailBody: detailPayload,
            token: token,
            cleanHandler: { [weak self] request in
                guard let self else { return (500, Data("{\"error\": \"Server unavailable\"}".utf8)) }
                guard self.allowRemoteClean else { return Self.cleanOptInRefusal }
                guard self.onRemoteClean != nil else {
                    return (501, Data("{\"error\": \"Clean handler not configured\"}".utf8))
                }
                cleanRequested = .some(request)
                // Placeholder: never sent.  `startClean` answers later.
                return (202, Data())
            },
            cleanRunHandler: { [weak self] request in
                guard let self else { return (500, Data("{\"error\": \"Server unavailable\"}".utf8)) }
                guard self.allowRemoteClean else { return Self.cleanOptInRefusal }
                guard self.onRemoteClean != nil else {
                    return (501, Data("{\"error\": \"Clean handler not configured\"}".utf8))
                }
                cleanRequested = .some(request)
                return (202, Data())
            },
            cleanScanHandler: { [weak self] request in
                guard let self else { return (500, Data("{\"error\": \"Server unavailable\"}".utf8)) }
                guard self.allowRemoteClean else { return Self.cleanOptInRefusal }
                guard self.onRemoteCleanScan != nil else {
                    return (501, Data("{\"error\": \"Scan handler not configured\"}".utf8))
                }
                scanRequested = request
                return (202, Data())
            },
            cleanReportHandler: { [weak self] in
                guard let self else { return (500, Data("{\"error\": \"Server unavailable\"}".utf8)) }
                guard self.allowRemoteClean else { return Self.cleanOptInRefusal }
                guard self.onRemoteCleanReport != nil else {
                    return (501, Data("{\"error\": \"Report handler not configured\"}".utf8))
                }
                reportRequested = true
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
            settingsHandler: { [weak self] req in
                guard let self else { return (500, Data("{\"error\": \"Server unavailable\"}".utf8)) }
                guard self.allowRemoteEdit else { return Self.editRefusal }
                if let handler = self.onRemoteSettings {
                    return handler(req)
                }
                return (501, Data("{\"error\": \"Settings handler not configured\"}".utf8))
            },
            sampleHandler: { [weak self] request in
                guard let self else { return (500, Data("{\"error\": \"Server unavailable\"}".utf8)) }
                // Sampling pauses and reads another process, so it sits behind
                // the same opt-in as quit and tame.
                guard self.allowRemoteQuit else { return Self.processControlRefusal }
                guard self.onRemoteSample != nil else {
                    return (501, Data("{\"error\": \"Sample handler not configured\"}".utf8))
                }
                guard let target = CompanionTargets.resolve(request, in: self.targets) else {
                    let res = CompanionSampleResponse(status: "changed", name: "", message: nil, error: CompanionTargets.unresolvedMessage(for: request))
                    return (400, (try? JSONEncoder().encode(res)) ?? Data())
                }
                sampleRequested = target
                // Placeholder: never sent.  `startSample` answers later.
                return (202, Data())
            },
            maintainHandler: { [weak self] kind in
                guard let self else { return (500, Data("{\"error\": \"Server unavailable\"}".utf8)) }
                guard self.allowRemoteMaintain else { return Self.maintainRefusal }
                guard let handler = self.onRemoteMaintainRun else {
                    return (501, Data("{\"error\": \"Maintain handler not configured\"}".utf8))
                }
                // Requests are handled one at a time on this queue, so the
                // check and the set below cannot interleave with another phone
                // request.
                guard !self.maintainRunningFlag.value else { return Self.maintainBusyReply }
                self.maintainRunningFlag.value = true
                let reply = handler(kind)
                if !(200..<300).contains(reply.status) { self.maintainRunningFlag.value = false }
                return reply
            },
            serverControlGate: { [weak self] in
                guard let self else { return (500, Data("{\"error\": \"Server unavailable\"}".utf8)) }
                let refusal = self.serverControlRefusal(for: peer)
                if let refusal {
                    let path = CompanionHTTP.requestPath(buffer) ?? "server control"
                    self.onServerControlRefused?(authenticatedDevice, path, refusal.outcome)
                }
                return refusal.map { ($0.status, $0.body) }
            },
            serverActionHandler: { [weak self] request in
                guard let self else { return (500, Data("{\"error\": \"Server unavailable\"}".utf8)) }
                guard self.onRemoteServerAction != nil else {
                    return (501, Data("{\"error\": \"Server action handler not configured\"}".utf8))
                }
                // Requests are handled one at a time on this queue, so this
                // check and set cannot interleave with another phone's.
                guard !self.serverActionBusyFlag.value else { return Self.serverActionBusyReply }
                if request.isMaintenance, self.maintainRunningFlag.value { return Self.serverActionBusyReply }
                self.serverActionBusyFlag.value = true
                serverActionRequested = request
                // Placeholder: never sent.  `startServerAction` answers later.
                return (202, Data())
            },
            peerTrusted: peer.isTrusted,
            deviceAuthenticator: { [devices] presented in
                let matched = devices.authenticate(presented, now: now)
                if matched { authenticatedDevice = devices.deviceName(for: presented) ?? "" }
                return matched
            }
        )
        // 401 is a wrong credential.  404 never got as far as checking one.
        // Anything else means the credential was accepted.
        let status = CompanionHTTP.statusCode(of: response)
        if status == 401 {
            throttle.recordFailure(peer: peer.key, now: now, countsTowardGlobal: !peer.isTrusted)
        } else if status != 404 {
            throttle.recordSuccess(peer: peer.key)
        }
        if let cleanRequested { return .startClean(cleanRequested) }
        if let scanRequested { return .startCleanScan(scanRequested) }
        if reportRequested { return .startCleanReport }
        if let sampleRequested { return .startSample(sampleRequested) }
        if let serverActionRequested { return .startServerAction(serverActionRequested, device: authenticatedDevice) }
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
        if let wait = throttle.retryAfter(for: peer.key, now: now, appliesGlobal: !peer.isTrusted) {
            return CompanionHTTP.throttledReply(retryAfter: wait)
        }
        guard peer.isTrusted else {
            return CompanionHTTP.untrustedNetworkReply()
        }
        guard CompanionToken.matches(code, token) else {
            throttle.recordFailure(peer: peer.key, now: now, countsTowardGlobal: !peer.isTrusted)
            return CompanionHTTP.enrollRejectedReply()
        }
        throttle.recordSuccess(peer: peer.key)
        if let last = lastEnrollSuccess[peer.key], now.timeIntervalSince(last) < Self.enrollSuccessCooldown {
            let wait = Int((Self.enrollSuccessCooldown - now.timeIntervalSince(last)).rounded(.up))
            return CompanionHTTP.throttledReply(retryAfter: wait)
        }
        lastEnrollSuccess[peer.key] = now
        lastEnrollSuccess = lastEnrollSuccess.filter { now.timeIntervalSince($0.value) < Self.enrollSuccessCooldown }
        let issued = devices.issue(name: deviceName, now: now)
        return CompanionHTTP.enrollResponse(token: issued.token, deviceId: issued.device.id)
    }

    /// The answer to an exclusions, view or settings change while the owner
    /// has not allowed phone edits.
    static var editRefusal: Reply {
        let res = ["status": "forbidden", "error": "Changing cleaner exclusions, the panel view or Mac settings from iPhone is off.\u{00A0} Turn on Allow iPhone to Change Exclusions & View in Hog Hunter Settings > iPhone on the Mac."]
        return (403, (try? JSONSerialization.data(withJSONObject: res)) ?? Data())
    }

    /// The answer to any disk cleaner route while the owner has not allowed
    /// the phone to run it.
    static var cleanOptInRefusal: Reply {
        let res = ["status": "forbidden", "error": "Running the disk cleaner from iPhone is off.\u{00A0} Turn on Allow iPhone to Run Disk Cleaner in Hog Hunter Settings on the Mac."]
        return (403, (try? JSONSerialization.data(withJSONObject: res)) ?? Data())
    }

    /// The answer to a process action (sample) while the owner has not
    /// allowed phone control of processes.
    static var processControlRefusal: Reply {
        let res = ["status": "forbidden", "error": "Acting on apps and processes from iPhone is off.\u{00A0} Turn on Allow iPhone to Quit or Tame Apps & Processes in Hog Hunter Settings > iPhone on the Mac."]
        return (403, (try? JSONSerialization.data(withJSONObject: res)) ?? Data())
    }

    /// The answer to a Maintain run while the owner has not allowed it.
    static var maintainRefusal: Reply {
        let res = ["status": "forbidden", "error": "Running maintenance from iPhone is off.\u{00A0} Turn on Allow iPhone to Run Maintenance in Hog Hunter Settings > iPhone on the Mac."]
        return (403, (try? JSONSerialization.data(withJSONObject: res)) ?? Data())
    }

    /// The answer to a Maintain run while one is already going.
    static var maintainBusyReply: Reply {
        let body = #"{"status":"busy","error":"A Maintain run is already going on this Mac.\u00a0 Watch its progress in the app."}"#
        return (409, Data(body.utf8))
    }

    /// Why a server control request stops at the gate, or nil.  The opt-in is
    /// first, then the stricter network rule.  The peer's address class never
    /// decides this alone: see `CompanionPeer.provingTailscaleArrival`.
    private func serverControlRefusal(for peer: CompanionPeer) -> (status: Int, body: Data, outcome: String)? {
        guard allowRemoteServerControl else {
            let reply = Self.serverControlOptInRefusal
            return (reply.status, reply.body, "refused: opt-in off")
        }
        guard peer.arrivedOverTailscale else {
            let reply = Self.serverControlTailscaleRefusal
            return (reply.status, reply.body, "refused: not on Tailscale")
        }
        return nil
    }

    static var serverControlOptInRefusal: Reply {
        (403, encodeServerReply(CompanionServerActionResponse(status: "forbidden", error: CompanionServerControl.optInNote)))
    }

    static var serverControlTailscaleRefusal: Reply {
        (403, encodeServerReply(CompanionServerActionResponse(status: "tailscaleRequired", error: CompanionServerControl.tailscaleOnlyNote)))
    }

    static var serverActionBusyReply: Reply {
        (409, encodeServerReply(CompanionServerActionResponse(status: "busy", error: "Another server action is already running.\u{00A0} Wait for it to finish, then try again.")))
    }

    static func encodeServerReply(_ response: CompanionServerActionResponse) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data()
    }

    /// How long a server action's connection is held.  Past the 30 seconds
    /// `ServerControl` gives SSH and the 105 seconds `MaintenanceSSH` gives a
    /// maintenance run, so the Mac's answer is the one the phone hears.
    static let serverActionReplyDeadline: TimeInterval = 40
    static let serverMaintenanceReplyDeadline: TimeInterval = 115

    /// Runs a request the router accepted, and frees the one-at-a-time slot when
    /// it actually ends, which can be after the phone stopped waiting.
    func runServerAction(_ request: CompanionServerActionRequest, device: String, completion: @escaping @Sendable (Reply) -> Void) {
        let busy = serverActionBusyFlag
        guard let handler = onRemoteServerAction else {
            busy.value = false
            completion((501, Data("{\"error\": \"Server action handler not configured\"}".utf8)))
            return
        }
        handler(request, device) { reply in
            busy.value = false
            completion(reply)
        }
    }

    private func startServerAction(_ request: CompanionServerActionRequest, device: String, on connection: NWConnection) {
        let body = Self.encodeServerReply(CompanionServerActionResponse(status: "failed", error: "The server has not answered, so the outcome is not known.\u{00A0} Check the server before trying again."))
        let deadline = request.isMaintenance ? Self.serverMaintenanceReplyDeadline : Self.serverActionReplyDeadline
        hold(connection, deadline: deadline, timeout: (504, body)) { done in
            runServerAction(request, device: device, completion: done)
        }
    }

    /// How long the connection of an unfinished sample is held.  The report
    /// takes three seconds plus the time `sample` needs to symbolicate it.
    static let sampleReplyDeadline: TimeInterval = 45

    /// How long a scan start or a report fetch may take to be answered.  Both
    /// are answered from the main actor in a moment.  Shorter than the phone's
    /// own 8 second limit, so the Mac's answer is the one it hears.
    static let quickReplyDeadline: TimeInterval = 6

    /// How long the connection of an unfinished clean is held before the
    /// phone is told to watch the progress instead.
    static let cleanReplyDeadline: TimeInterval = 15 * 60

    /// Holds `connection` until `begin` calls back, off the router.  Whichever
    /// comes first, the callback or the deadline, is the one reply sent.
    private func hold(
        _ connection: NWConnection,
        deadline: TimeInterval,
        timeout: (status: Int, body: Data),
        begin: (@escaping @Sendable (Reply) -> Void) -> Void
    ) {
        let once = CompanionOneShotReply { data in
            connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
        }
        queue.asyncAfter(deadline: .now() + deadline) {
            once.send(CompanionHTTP.jsonReply(status: timeout.status, body: timeout.body))
        }
        begin { reply in
            once.send(CompanionHTTP.jsonReply(status: reply.status, body: reply.body))
        }
    }

    private func notConfigured(_ what: String, on connection: NWConnection) {
        connection.send(content: CompanionHTTP.jsonReply(status: 501, body: Data("{\"error\": \"\(what) handler not configured\"}".utf8)), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func startSample(_ target: CompanionTarget, on connection: NWConnection) {
        guard let handler = onRemoteSample else { return notConfigured("Sample", on: connection) }
        let body = Data(#"{"status":"failed","name":"","error":"The sample took too long.\u00a0 Try again."}"#.utf8)
        hold(connection, deadline: Self.sampleReplyDeadline, timeout: (504, body)) { done in handler(target, done) }
    }

    private func startClean(_ request: CompanionCleanRequest?, on connection: NWConnection) {
        guard let handler = onRemoteClean else { return notConfigured("Clean", on: connection) }
        let body = Data(#"{"status":"running","error":"The clean is still running on the Mac.\u00a0 Watch its progress in the app."}"#.utf8)
        hold(connection, deadline: Self.cleanReplyDeadline, timeout: (504, body)) { done in handler(request, done) }
    }

    private func startCleanScan(_ request: CompanionCleanScanRequest, on connection: NWConnection) {
        guard let handler = onRemoteCleanScan else { return notConfigured("Scan", on: connection) }
        let body = Data(#"{"status":"failed","error":"The Mac did not start the scan in time.\u00a0 Try again."}"#.utf8)
        hold(connection, deadline: Self.quickReplyDeadline, timeout: (504, body)) { done in handler(request, done) }
    }

    private func startCleanReport(on connection: NWConnection) {
        guard let handler = onRemoteCleanReport else { return notConfigured("Report", on: connection) }
        let body = Data(#"{"status":"failed","error":"The Mac did not answer in time.\u00a0 Try again."}"#.utf8)
        hold(connection, deadline: Self.quickReplyDeadline, timeout: (504, body)) { done in handler(done) }
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

    /// Reads and changes the value as one step, for a check-then-set that two
    /// threads must not both win.
    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&stored)
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
