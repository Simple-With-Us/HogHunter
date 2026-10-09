import Foundation
import Network

/// Talks to the Mac's companion server.  Every call is one TCP connection, one
/// HTTP request and one reply, and every call is bounded in time: a Mac that
/// is asleep, off the network, or showing a dialog must end in an error the
/// person can read, never in a spinner that does not stop.
enum CompanionConnection {
    /// How long a quick control call (quit, tame, exclusions, view) waits.
    static let defaultTimeout: TimeInterval = 8
    /// A snapshot poll.  The caller adds its own, shorter limit on top.
    static let snapshotTimeout: TimeInterval = 5
    /// Sample for 3 Seconds answers when the report is written.  Longer than
    /// the Mac's own 45 second deadline for it.
    static let sampleTimeout: TimeInterval = 50
    /// A clean answers when the Mac has finished, which can take minutes.
    /// Longer than the Mac's own 15 minute reply deadline.
    static let cleanTimeout: TimeInterval = 16 * 60
    /// Pairing waits on a person at the Mac.  Longer than the 90 seconds the
    /// model allows for that person to answer.
    static let pairTimeout: TimeInterval = 100

    // MARK: - Calls

    /// Asks the Mac to approve this phone.  The Mac shows an alert, so the
    /// reply can take as long as the person takes; the caller sets the limit.
    /// Returns the pairing code the Mac hands back on Allow.
    static func requestPair(endpoint: NWEndpoint, deviceName: String) async throws -> String {
        let reply = try await exchange(
            endpoint: endpoint,
            request: CompanionHTTP.pairRequest(deviceName: deviceName),
            timeout: pairTimeout,
            qos: .userInitiated
        )
        let json = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any]
        switch reply.status {
        case 200:
            if let token = json?["token"] as? String, !token.isEmpty { return token }
            throw CompanionClientError.badResponse
        case 403:
            throw CompanionClientError.forbidden(json?["error"] as? String ?? "The Mac did not allow this iPhone.")
        case 429:
            throw CompanionClientError.busy
        case 404:
            throw CompanionClientError.forbidden("This Mac's copy of Hog Hunter is too old to approve phones.\u{00A0} Update it, or type the code from Settings.")
        default:
            throw CompanionClientError.badResponse
        }
    }

    /// Trades the Mac's pairing code for a token of this phone's own.  A Mac
    /// that predates per-phone tokens answers 404 (`tooOld`).
    static func enroll(endpoint: NWEndpoint, code: String, deviceName: String) async throws -> String {
        let reply = try await exchange(
            endpoint: endpoint,
            request: CompanionHTTP.enrollRequest(code: code, deviceName: deviceName),
            timeout: defaultTimeout
        )
        let json = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any]
        switch reply.status {
        case 200:
            if let token = json?["token"] as? String, CompanionToken.isDeviceToken(token) { return token }
            throw CompanionClientError.badResponse
        case 401:
            throw CompanionClientError.unauthorized
        case 403:
            if json?["reason"] as? String == "untrusted-network" {
                throw CompanionClientError.untrustedNetwork
            }
            throw CompanionClientError.forbidden(json?["error"] as? String ?? "The Mac did not allow this iPhone to pair.")
        case 404:
            throw CompanionClientError.tooOld
        case 429:
            throw CompanionClientError.throttled(retryAfter: (json?["retryAfter"] as? Int) ?? 0)
        default:
            throw CompanionClientError.badResponse
        }
    }

    static func fetch(endpoint: NWEndpoint, token: String) async throws -> CompanionSnapshot {
        let reply = try await exchange(
            endpoint: endpoint,
            request: CompanionHTTP.request(token: token),
            timeout: snapshotTimeout
        )
        return try decode(CompanionSnapshot.self, from: reply, decoder: CompanionJSON.decoder())
    }

    /// Starts a Standard clean and waits for the Mac to finish it.  The Mac
    /// answers 409 when a clean is already running.
    static func triggerClean(endpoint: NWEndpoint, token: String) async throws -> CompanionCleanResponse {
        let reply = try await exchange(
            endpoint: endpoint,
            request: CompanionHTTP.cleanRequest(token: token),
            timeout: cleanTimeout
        )
        return try decode(CompanionCleanResponse.self, from: reply)
    }

    static func triggerQuit(endpoint: NWEndpoint, token: String, pid: Int32, rowId: String? = nil, force: Bool = false) async throws -> CompanionQuitResponse {
        let reply = try await exchange(
            endpoint: endpoint,
            request: CompanionHTTP.quitRequest(token: token, pid: pid, rowId: rowId, force: force),
            timeout: defaultTimeout
        )
        return try decode(CompanionQuitResponse.self, from: reply)
    }

    static func triggerTame(endpoint: NWEndpoint, token: String, pid: Int32, rowId: String? = nil, action: String = "tame") async throws -> CompanionTameResponse {
        let reply = try await exchange(
            endpoint: endpoint,
            request: CompanionHTTP.tameRequest(token: token, pid: pid, rowId: rowId, action: action),
            timeout: defaultTimeout
        )
        return try decode(CompanionTameResponse.self, from: reply)
    }

    static func triggerExclusionsUpdate(
        endpoint: NWEndpoint,
        token: String,
        toggleCategory: String? = nil,
        addPath: String? = nil,
        removePath: String? = nil
    ) async throws -> CompanionExclusionsUpdateResponse {
        let reply = try await exchange(
            endpoint: endpoint,
            request: CompanionHTTP.exclusionsRequest(token: token, toggleCategory: toggleCategory, addPath: addPath, removePath: removePath),
            timeout: defaultTimeout
        )
        return try decode(CompanionExclusionsUpdateResponse.self, from: reply)
    }

    static func triggerViewUpdate(
        endpoint: NWEndpoint,
        token: String,
        window: String? = nil,
        grouping: String? = nil,
        cpuScale: String? = nil
    ) async throws -> CompanionViewUpdateResponse {
        let reply = try await exchange(
            endpoint: endpoint,
            request: CompanionHTTP.viewRequest(token: token, window: window, grouping: grouping, cpuScale: cpuScale),
            timeout: defaultTimeout
        )
        return try decode(CompanionViewUpdateResponse.self, from: reply)
    }

    /// Changes the refresh interval, alerts or webhook on the Mac.  The Mac
    /// checks every value and answers 400 with the reason when one is out of range.
    static func triggerSettingsUpdate(
        endpoint: NWEndpoint,
        token: String,
        update: CompanionSettingsUpdateRequest
    ) async throws -> CompanionSettingsUpdateResponse {
        let reply = try await exchange(
            endpoint: endpoint,
            request: CompanionHTTP.settingsRequest(token: token, update: update),
            timeout: defaultTimeout
        )
        return try decode(CompanionSettingsUpdateResponse.self, from: reply)
    }

    /// Runs Sample for 3 Seconds on a row.  The Mac answers once the report
    /// is written, a few seconds later.
    static func triggerSample(endpoint: NWEndpoint, token: String, rowId: String) async throws -> CompanionSampleResponse {
        let reply = try await exchange(
            endpoint: endpoint,
            request: CompanionHTTP.sampleRequest(token: token, rowId: rowId),
            timeout: sampleTimeout
        )
        return try decode(CompanionSampleResponse.self, from: reply)
    }

    // MARK: - Reply handling

    /// Turns one reply into a value or a readable error.  A typed body wins
    /// whatever the status, because the Mac answers a refused quit or tame
    /// with a typed body that carries the reason; only the statuses that
    /// mean "not allowed" or "slow down" are errors before decoding.
    static func decode<T: Decodable>(_ type: T.Type, from reply: CompanionReply, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        let json = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any]
        let message = json?["error"] as? String
        switch reply.status {
        case 401:
            throw CompanionClientError.unauthorized
        case 403:
            throw CompanionClientError.forbidden(message ?? "The Mac does not allow that from this iPhone.")
        case 404:
            // A Mac that predates the route answers 404 with plain text.
            throw CompanionClientError.tooOld
        case 429:
            throw CompanionClientError.throttled(retryAfter: (json?["retryAfter"] as? Int) ?? 0)
        default:
            break
        }
        if let value = try? decoder.decode(T.self, from: reply.body) {
            return value
        }
        if let message {
            throw CompanionClientError.rejected(message)
        }
        throw CompanionClientError.badResponse
    }

    // MARK: - Transport

    /// Sends one request and returns the complete reply.  Ends with a
    /// `CompanionClientError.timedOut` after `timeout` seconds if the Mac has
    /// not finished answering, whatever state the connection is stuck in
    /// (`.waiting` for a missing route, a half-open socket, a silent Mac).
    static func exchange(
        endpoint: NWEndpoint,
        request: Data,
        timeout: TimeInterval,
        qos: DispatchQoS.QoSClass = .utility
    ) async throws -> CompanionReply {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let exchange = CompanionExchange(connection: connection)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                exchange.install(continuation)
                exchange.armTimeout(after: timeout)
                connection.stateUpdateHandler = { [weak exchange] state in
                    switch state {
                    case .ready:
                        connection.send(content: request, completion: .contentProcessed { error in
                            if let error { exchange?.finish(.failure(error)) }
                        })
                    case .failed(let error):
                        exchange?.finish(.failure(error))
                    case .cancelled:
                        exchange?.finish(.failure(CancellationError()))
                    default:
                        // `.waiting` has no route yet.  The timeout decides.
                        break
                    }
                }
                exchange.receive(buffer: Data())
                connection.start(queue: .global(qos: qos))
            }
        } onCancel: {
            exchange.finish(.failure(CancellationError()))
        }
    }
}

/// One complete HTTP reply.
typealias CompanionReply = (status: Int, body: Data)

/// Resumes the caller exactly once.  A reply, a failure, the timeout and a
/// cancel can all arrive, in any order and from different threads; the first
/// wins and the rest are ignored.  An outcome that lands before the
/// continuation is installed is held and delivered on install.
private final class CompanionExchange: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NWConnection
    private var continuation: CheckedContinuation<CompanionReply, Error>?
    private var early: Result<CompanionReply, Error>?
    private var finished = false
    private var timer: DispatchWorkItem?

    init(connection: NWConnection) {
        self.connection = connection
    }

    func install(_ continuation: CheckedContinuation<CompanionReply, Error>) {
        lock.lock()
        if let early {
            self.early = nil
            lock.unlock()
            continuation.resume(with: early)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func armTimeout(after seconds: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in
            self?.finish(.failure(CompanionClientError.timedOut))
        }
        lock.lock()
        timer = item
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func receive(buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let parsed = CompanionHTTP.parseResponse(buffer) {
                finish(.success(parsed))
                return
            }
            if isComplete || error != nil {
                finish(.failure(error ?? CompanionClientError.badResponse))
                return
            }
            receive(buffer: buffer)
        }
    }

    func finish(_ result: Result<CompanionReply, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        timer?.cancel()
        timer = nil
        let waiting = continuation
        continuation = nil
        if waiting == nil { early = result }
        lock.unlock()
        connection.cancel()
        waiting?.resume(with: result)
    }
}
