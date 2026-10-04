import Foundation

/// One network connection row as reported by `lsof`.  We do not try to compute
/// per-process byte counters — macOS exposes those only through private
/// `NetworkStatistics` APIs — but we do report the open-socket count and the
/// list of remote hosts the process is currently talking to.  That is enough
/// to flag an analytics-heavy app or a chatty updater without dragging in a
/// kernel extension.
struct NetworkConnectionSample: Equatable, Hashable, Sendable {
    var protocolName: String     // "TCP", "UDP"
    var state: String?           // "ESTABLISHED", "LISTEN", "CLOSE_WAIT" — TCP only
    /// `host:port` form (lsof's `-P` keeps numeric ports so we can split
    /// them reliably).  Nil if the entry is a listen socket.
    var localEndpoint: String?
    var remoteEndpoint: String?
    /// Remote hostname or IP.  Always the part after `→` in lsof output.
    /// Stripped of the port by `parser`.
    var remoteHost: String?
    /// Remote port extracted from `remoteEndpoint`.
    var remotePort: Int?
}

/// One process aggregated across its current open sockets.  Carried into
/// the UI by `NetworkScanner.snapshot()`.
struct NetworkUsage: Identifiable, Equatable, Hashable, Sendable {
    var pid: pid_t
    var bundleId: String?
    var name: String
    var isRunning: Bool
    var openSockets: Int
    var establishedSockets: Int
    var remoteHostCount: Int
    /// Top remote hosts by appearance; capped so the UI row stays compact.
    var topRemoteHosts: [String]

    var id: pid_t { pid }
}

/// Outcome of a single `lsof` run.  `unavailable` is returned when the
/// binary was not found at `/usr/sbin/lsof` (which is the only path the
/// system ships; we never `which`).
enum NetworkSnapshot {
    case unavailable(reason: String)
    case snapshot(at: Date, usages: [NetworkUsage])
}

/// Wraps `/usr/sbin/lsof` for HogHunter.  Pure: callers pass the bundle-id
/// resolver and the lsof binary path, and the scanner stays testable on any
/// CI runner that does not have lsof.
final class NetworkScanner: @unchecked Sendable {

    enum LsofError: Error, CustomStringConvertible {
        case binaryMissing(String)
        case denied(String)
        case exit(Int32, String)
        case parseFailure(String)

        var description: String {
            switch self {
            case .binaryMissing(let p): return "lsof binary missing at \(p)"
            case .denied(let m): return "lsof denied: \(m)"
            case .exit(let c, let m): return "lsof exit \(c): \(m)"
            case .parseFailure(let m): return "lsof parse failure: \(m)"
            }
        }
    }

    let binaryPath: String
    let process: ProcessRunner

    init(binaryPath: String = "/usr/sbin/lsof",
         process: ProcessRunner = .live) {
        self.binaryPath = binaryPath
        self.process = process
    }

    /// Runs one `lsof -nP -i -F nPTi` snapshot.  Returns `.unavailable`
    /// when lsof is missing or denied, otherwise `.snapshot` with the
    /// bucket per pid.
    func snapshot(bundleResolver: @escaping (pid_t) -> (bundleId: String?, name: String)) -> NetworkSnapshot {
        do {
            let raw = try runLsof()
            return .snapshot(at: Date(), usages: Self.parse(rawOutput: raw, bundleResolver: bundleResolver))
        } catch LsofError.binaryMissing(let path) {
            return .unavailable(reason: "lsof binary missing at \(path).")
        } catch LsofError.denied(let message) {
            return .unavailable(reason: "lsof denied: \(message). Grant Full Disk Access to Hog Hunter.")
        } catch {
            return .unavailable(reason: "\(error)")
        }
    }

    func runLsof() throws -> String {
        if !FileManager.default.isExecutableFile(atPath: binaryPath) {
            throw LsofError.binaryMissing(binaryPath)
        }
        let result = try process.run([binaryPath, "-nP", "-i", "-F", "nPTi"])
        if result.exit != 0 {
            // `lsof -i` returns exit 1 + empty stderr + empty stdout when
            // there are no sockets — that's a successful empty snapshot, not
            // an error.
            let lower = result.stderr.lowercased()
            if result.exit == 1, result.stdout.isEmpty, result.stderr.isEmpty {
                return ""
            }
            if lower.contains("permission denied") || lower.contains("operation not permitted") {
                throw LsofError.denied(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            throw LsofError.exit(result.exit, result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }

    /// Parses one `-F` block into per-pid `NetworkUsage`.  Public for tests.
///
/// lsof's `-F` format is line-oriented:
/// ```
/// p<pid>
/// P<proto>
/// T<state>       (state may appear multiple times)
/// n<endpoint>
/// n<endpoint>    (next socket on the same pid)
/// ```
/// `P` and `T` lines are "sticky" — they describe the socket that the
/// next `n` line emits.  Multiple `T` lines can appear before a single `n`
/// (e.g. `TIPv4` + `TCPSOCKET` + `TESTABLISHED`), in which case all three
/// belong to the socket that the next `n` describes.  This parser keeps
/// the most recent sticky values until an `n` consumes them, then keeps
/// them around for the next `n` until a new `T` (or `P`) line updates
/// them.  This matches real lsof output.
static func parse(rawOutput: String,
                  bundleResolver: (pid_t) -> (bundleId: String?, name: String)) -> [NetworkUsage] {
    var byPid: [pid_t: (info: (bundleId: String?, name: String), samples: [NetworkConnectionSample])] = [:]
    var currentPid: pid_t?
    var pendingProto: String = ""
    var pendingState: String?
    var stuckProto: String = ""
    var stuckState: String?

    func newSample() -> NetworkConnectionSample {
        NetworkConnectionSample(
            protocolName: pendingProto,
            state: pendingState,
            localEndpoint: nil,
            remoteEndpoint: nil,
            remoteHost: nil,
            remotePort: nil
        )
    }

    func append(sample: NetworkConnectionSample) {
        guard let pid = currentPid, !sample.protocolName.isEmpty else { return }
        if var entry = byPid[pid] {
            entry.samples.append(sample)
            byPid[pid] = entry
        } else {
            let info = bundleResolver(pid)
            byPid[pid] = (info, [sample])
        }
    }

    for line in rawOutput.split(separator: "\n") {
        guard let first = line.first else { continue }
        let rest = String(line.dropFirst())
        switch first {
        case "p":
            currentPid = pid_t(rest.trimmingCharacters(in: .whitespaces))
        case "P":
            stuckProto = rest
            pendingProto = rest
        case "T":
            stuckState = rest
            pendingState = rest
        case "n":
            // Construct the sample from the sticky header fields.
            var sample = newSample()
            // lsof -i name format examples:
            //   "TCP 127.0.0.1:8080->192.168.1.2:443"
            //   "TCP6 [::1]:8080"
            //   "UDP *:1234"
            let protoSpace = rest.firstIndex(of: " ") ?? rest.endIndex
            let protoInLine = String(rest[..<protoSpace])
            let endpoints = protoSpace == rest.endIndex ? String(rest) : String(rest[rest.index(after: protoSpace)...])
            // First preference: the proto the `P` line declared.  Fall
            // back to the inline token when no `P` line preceded this
            // socket (real lsof always emits `P`, but tests sometimes
            // skip it).
            if pendingProto.isEmpty, !protoInLine.isEmpty { sample.protocolName = protoInLine }
            if let arrow = endpoints.firstIndex(of: ">") {
                let local = String(endpoints[..<arrow])
                let remote = String(endpoints[endpoints.index(after: arrow)...])
                sample.localEndpoint = local
                sample.remoteEndpoint = remote
                // Split host and port.  IPv6 addresses contain `:` chars,
                // so we cannot simply split on the first `:`.  Look for
                // the closing `]` of the bracketed IPv6 form first; if
                // missing, fall back to the LAST `:` (works for IPv4 and
                // for hostnames).
                if remote.hasPrefix("["),
                   let closeBracket = remote.firstIndex(of: "]") {
                    let host = String(remote[remote.index(after: remote.startIndex)..<closeBracket])
                    let after = remote[remote.index(after: closeBracket)...]
                    if after.first == ":" {
                        sample.remoteHost = host
                        sample.remotePort = Int(after.dropFirst())
                    } else {
                        sample.remoteHost = host
                    }
                } else if let colon = remote.lastIndex(of: ":") {
                    sample.remoteHost = String(remote[..<colon])
                    sample.remotePort = Int(remote[remote.index(after: colon)...])
                } else {
                    sample.remoteHost = remote
                }
            } else {
                // Listen / unconnected socket — no remote.
                sample.localEndpoint = endpoints
            }
            append(sample: sample)
            // After consuming the sticky state/proto, restore them so the
            // next socket (without its own P/T) still inherits them.  Real
            // lsof re-emits P/T for every socket, but tests sometimes
            // collapse them; the realistic assumption is "sticky until
            // changed".
            pendingProto = stuckProto
            pendingState = stuckState
        default:
            continue
        }
    }

    return byPid.map { pid, entry in
        let samples = entry.samples
        let established = samples.filter { $0.state == "ESTABLISHED" }.count
        var hostCounts: [String: Int] = [:]
        for sample in samples {
            guard let host = sample.remoteHost, !host.isEmpty else { continue }
            if sample.state == "ESTABLISHED" || sample.state == "CLOSE_WAIT" {
                hostCounts[host, default: 0] += 1
            }
        }
        let topHosts = hostCounts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(5)
            .map(\.key)
        return NetworkUsage(
            pid: pid,
            bundleId: entry.info.bundleId,
            name: entry.info.name,
            isRunning: true,
            openSockets: samples.count,
            establishedSockets: established,
            remoteHostCount: hostCounts.count,
            topRemoteHosts: topHosts
        )
    }
    .sorted { lhs, rhs in
        if lhs.establishedSockets != rhs.establishedSockets {
            return lhs.establishedSockets > rhs.establishedSockets
        }
        return lhs.remoteHostCount > rhs.remoteHostCount
    }
}
}

/// Tiny abstraction over `Process()` so tests can pre-record a fake stdout
/// without forking the real lsof binary.
struct ProcessRunner {
    var run: ([String]) throws -> (exit: Int32, stdout: String, stderr: String)

    static let live: ProcessRunner = .init { arguments in
        try liveRun(arguments)
    }
}

/// Concrete implementation that shells out to `/usr/sbin/lsof` via `Process`.
private func liveRun(_ arguments: [String]) throws -> (exit: Int32, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: arguments[0])
    process.arguments = Array(arguments.dropFirst())
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    try process.run()
    process.waitUntilExit()
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    return (
        exit: process.terminationStatus,
        stdout: String(data: outData, encoding: .utf8) ?? "",
        stderr: String(data: errData, encoding: .utf8) ?? ""
    )
}
