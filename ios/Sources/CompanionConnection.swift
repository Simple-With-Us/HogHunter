import Foundation
import Network

/// One HTTP GET over the Bonjour endpoint the browser already resolved.
enum CompanionConnection {
    static func fetch(endpoint: NWEndpoint, token: String) async throws -> CompanionSnapshot {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let reader = ResponseReader()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reader.continuation = continuation
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        let request = CompanionHTTP.request(token: token)
                        connection.send(content: request, completion: .contentProcessed { error in
                            if let error { reader.fail(error) }
                        })
                    case .failed(let error):
                        reader.fail(error)
                    default:
                        break
                    }
                }
                receive(connection, reader: reader, buffer: Data())
                connection.start(queue: .global(qos: .utility))
            }
        } onCancel: {
            connection.cancel()
            reader.fail(CancellationError())
        }
    }

    static func triggerClean(endpoint: NWEndpoint, token: String) async throws -> CompanionCleanResponse {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let reader = CleanResponseReader()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reader.continuation = continuation
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        let request = CompanionHTTP.cleanRequest(token: token)
                        connection.send(content: request, completion: .contentProcessed { error in
                            if let error { reader.fail(error) }
                        })
                    case .failed(let error):
                        reader.fail(error)
                    default:
                        break
                    }
                }
                receiveClean(connection, reader: reader, buffer: Data())
                connection.start(queue: .global(qos: .utility))
            }
        } onCancel: {
            connection.cancel()
            reader.fail(CancellationError())
        }
    }

    static func triggerQuit(endpoint: NWEndpoint, token: String, pid: Int32, force: Bool = false) async throws -> CompanionQuitResponse {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let reader = QuitResponseReader()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reader.continuation = continuation
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        let request = CompanionHTTP.quitRequest(token: token, pid: pid, force: force)
                        connection.send(content: request, completion: .contentProcessed { error in
                            if let error { reader.fail(error) }
                        })
                    case .failed(let error):
                        reader.fail(error)
                    default:
                        break
                    }
                }
                receiveQuit(connection, reader: reader, buffer: Data())
                connection.start(queue: .global(qos: .utility))
            }
        } onCancel: {
            connection.cancel()
            reader.fail(CancellationError())
        }
    }

    private static func receive(_ connection: NWConnection, reader: ResponseReader, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let parsed = CompanionHTTP.parseResponse(buffer) {
                switch parsed.status {
                case 200:
                    if let snapshot = try? CompanionJSON.decode(parsed.body) {
                        reader.succeed(snapshot)
                    } else {
                        reader.fail(CompanionClientError.badResponse)
                    }
                case 401:
                    reader.fail(CompanionClientError.unauthorized)
                default:
                    reader.fail(CompanionClientError.badResponse)
                }
                connection.cancel()
                return
            }
            if isComplete || error != nil {
                reader.fail(error ?? CompanionClientError.badResponse)
                connection.cancel()
                return
            }
            receive(connection, reader: reader, buffer: buffer)
        }
    }

    private static func receiveClean(_ connection: NWConnection, reader: CleanResponseReader, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let parsed = CompanionHTTP.parseResponse(buffer) {
                switch parsed.status {
                case 200:
                    if let res = try? JSONDecoder().decode(CompanionCleanResponse.self, from: parsed.body) {
                        reader.succeed(res)
                    } else {
                        reader.fail(CompanionClientError.badResponse)
                    }
                case 401:
                    reader.fail(CompanionClientError.unauthorized)
                default:
                    reader.fail(CompanionClientError.badResponse)
                }
                connection.cancel()
                return
            }
            if isComplete || error != nil {
                reader.fail(error ?? CompanionClientError.badResponse)
                connection.cancel()
                return
            }
            receiveClean(connection, reader: reader, buffer: buffer)
        }
    }

    private static func receiveQuit(_ connection: NWConnection, reader: QuitResponseReader, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let parsed = CompanionHTTP.parseResponse(buffer) {
                switch parsed.status {
                case 200, 400, 403:
                    if let res = try? JSONDecoder().decode(CompanionQuitResponse.self, from: parsed.body) {
                        reader.succeed(res)
                    } else if let errJson = try? JSONSerialization.jsonObject(with: parsed.body) as? [String: Any],
                              let err = errJson["error"] as? String {
                        reader.succeed(CompanionQuitResponse(status: "error", pid: 0, name: "", message: nil, error: err))
                    } else {
                        reader.fail(CompanionClientError.badResponse)
                    }
                case 401:
                    reader.fail(CompanionClientError.unauthorized)
                default:
                    reader.fail(CompanionClientError.badResponse)
                }
                connection.cancel()
                return
            }
            if isComplete || error != nil {
                reader.fail(error ?? CompanionClientError.badResponse)
                connection.cancel()
                return
            }
            receiveQuit(connection, reader: reader, buffer: buffer)
        }
    }
}

private final class CleanResponseReader: @unchecked Sendable {
    var continuation: CheckedContinuation<CompanionCleanResponse, Error>?
    private let lock = NSLock()

    func succeed(_ response: CompanionCleanResponse) {
        resume(.success(response))
    }

    func fail(_ error: Error) {
        resume(.failure(error))
    }

    private func resume(_ result: Result<CompanionCleanResponse, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class QuitResponseReader: @unchecked Sendable {
    var continuation: CheckedContinuation<CompanionQuitResponse, Error>?
    private let lock = NSLock()

    func succeed(_ response: CompanionQuitResponse) {
        resume(.success(response))
    }

    func fail(_ error: Error) {
        resume(.failure(error))
    }

    private func resume(_ result: Result<CompanionQuitResponse, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// Resumes the fetch continuation once.  A cancel and a late packet can both arrive.
private final class ResponseReader: @unchecked Sendable {
    var continuation: CheckedContinuation<CompanionSnapshot, Error>?
    private let lock = NSLock()

    func succeed(_ snapshot: CompanionSnapshot) {
        resume(.success(snapshot))
    }

    func fail(_ error: Error) {
        resume(.failure(error))
    }

    private func resume(_ result: Result<CompanionSnapshot, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
