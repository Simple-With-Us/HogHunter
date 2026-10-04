import re
with open('ios/Sources/CompanionConnection.swift', 'r') as f:
    content = f.read()

new_content = content.replace(
    '''    static func fetch(endpoint: NWEndpoint, token: String) async throws -> CompanionSnapshot {''',
    '''    static func requestPair(endpoint: NWEndpoint, deviceName: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NWConnection(to: endpoint, using: .tcp)
            let reader = PairResponseReader()
            reader.continuation = continuation

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let req = CompanionHTTP.request(method: "POST", path: CompanionService.pairPath, token: "", body: Data(deviceName.utf8))
                    connection.send(content: req, completion: .contentProcessed { error in
                        if let error {
                            reader.fail(error)
                            connection.cancel()
                        } else {
                            receivePair(connection, reader: reader, buffer: Data())
                        }
                    })
                case .failed(let error):
                    reader.fail(error)
                case .cancelled:
                    reader.fail(CompanionClientError.timedOut)
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }

    private static func receivePair(_ connection: NWConnection, reader: PairResponseReader, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let parsed = CompanionHTTP.parseResponse(buffer) {
                switch parsed.status {
                case 200:
                    if let res = try? JSONSerialization.jsonObject(with: parsed.body) as? [String: String], let token = res["token"] {
                        reader.succeed(token)
                    } else {
                        reader.fail(CompanionClientError.badResponse)
                    }
                case 403:
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
            receivePair(connection, reader: reader, buffer: buffer)
        }
    }

    static func fetch(endpoint: NWEndpoint, token: String) async throws -> CompanionSnapshot {'''
)

new_content += '''
private final class PairResponseReader: @unchecked Sendable {
    var continuation: CheckedContinuation<String, Error>?
    private let lock = NSLock()

    func succeed(_ response: String) {
        resume(.success(response))
    }

    func fail(_ error: Error) {
        resume(.failure(error))
    }

    private func resume(_ result: Result<String, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
'''

with open('ios/Sources/CompanionConnection.swift', 'w') as f:
    f.write(new_content)
