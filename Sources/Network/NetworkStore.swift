import Foundation
import SwiftUI

/// Wraps `NetworkScanner` for SwiftUI: snapshots lsof on a utility queue,
/// debounces the manual refresh, and exposes the result as `@Published`.
@MainActor
final class NetworkStore: ObservableObject {
    enum State: Equatable {
        case idle
        case scanning
        case unavailable(String)
        case completed(at: Date)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var usages: [NetworkUsage] = []

    let scanner: NetworkScanner
    private let bundleResolver: (pid_t) -> (bundleId: String?, name: String)
    private let queue = DispatchQueue(label: "hoghunter.network", qos: .utility)
    private var inflight = false

    init(scanner: NetworkScanner = NetworkScanner(),
         bundleResolver: @escaping (pid_t) -> (bundleId: String?, name: String)) {
        self.scanner = scanner
        self.bundleResolver = bundleResolver
    }

    func refresh() {
        guard ApplicationRunMode.current != .uiHarness, !inflight else { return }
        inflight = true
        state = .scanning
        let scanner = self.scanner
        let resolver = self.bundleResolver

        queue.async { [weak self] in
            let snapshot = scanner.snapshot(bundleResolver: resolver)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inflight = false
                switch snapshot {
                case .snapshot(let at, let usages):
                    self.usages = usages
                    self.state = .completed(at: at)
                case .unavailable(let reason):
                    self.state = .unavailable(reason)
                }
            }
        }
    }
}
