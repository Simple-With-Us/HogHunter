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

    func start(name: String, peerID: String, token: String, onStatus: @escaping @Sendable (String) -> Void) {
        queue.async {
            self.token = token
            self.onStatus = onStatus
            if self.listener != nil {
                onStatus("Sharing on this Wi-Fi")
                return
            }
            do {
                let listener = try NWListener(using: .tcp, on: .any)
                var service = NWListener.Service(name: Self.serviceName(from: name), type: CompanionService.type)
                service.txtRecordObject = NWTXTRecord(["ver": "1", "id": peerID])
                listener.service = service
                listener.stateUpdateHandler = { [weak self] state in
                    self?.queue.async {
                        switch state {
                        case .ready:
                            self?.onStatus?("Sharing on this Wi-Fi")
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
                let response = CompanionHTTP.response(request: buffer, body: self.payload, token: self.token) { [weak self] _ in
                    self?.handleRemoteClean() ?? (status: 500, body: Data("{}".utf8))
                }
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func handleRemoteClean() -> (status: Int, body: Data) {
        let cleaner = DiskCleaner()
        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data = Data("{}".utf8)
        Task {
            let scanReport = await cleaner.scan(tier: .standard)
            let itemsToClean = scanReport.categories.flatMap { $0.items }.filter(\.isSelected)
            let cleanResult = await cleaner.clean(items: itemsToClean, tier: .standard, createSnapshot: true)
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
}
