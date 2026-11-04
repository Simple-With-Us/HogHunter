import Foundation

/// The one SSH connection every server reading and action shares.
///
/// Before this type existed, each call site spawned `/usr/bin/ssh` with no
/// connection options of its own, so multiplexing came from the user's own
/// ssh configuration — and when that master connection died, the app had no
/// name for its socket, no way to throw it away, and no recovery: every poll
/// and every Retry failed against the same dead socket forever.  That is
/// exactly what happened on 2026-11-04, when the server's connection died
/// during a period of host IO saturation and the panel kept painting the
/// last good reading (a full /mnt/fleet-extra, hours after the space was
/// freed) as if it were live, because nothing could ever read the server
/// again.
///
/// The fix has three parts, all in this file:
///
/// 1. The app owns its control socket.  `connectionOptions` points every
///    ssh invocation at one socket per host under the app's own Application
///    Support directory, so the socket has a known path the app can manage.
/// 2. Dead-socket failures are classified as what they are (`isDeadSocketFailure`),
///    distinct from "server unreachable": the server may be perfectly
///    healthy; it is the local end of the connection that is gone.
/// 3. On that classification the dead master is discarded *before* any new
///    attempt: `invalidate` exits the old master and removes the socket
///    file, and only then does `retryingOnceOnDeadSocket` run the attempt
///    again, over a connection ssh creates fresh.  No poll, retry, or
///    reconnect is ever issued over the dead socket or its path.
enum SSHConnection {

    // MARK: - Control socket location

    /// Directory holding the app's SSH control sockets, one file per host.
    static func controlDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HogHunter").appendingPathComponent("SSH")
    }

    /// The socket file name for a host.  Derived from the host string with a
    /// stable hash so the name is filesystem-safe (no `@`, `:`, or `/` from
    /// the host string can leak into a path) and the same host always maps
    /// to the same socket while different hosts never collide.
    static func socketFileName(forHost host: String) -> String {
        // FNV-1a, 64-bit.  Not a security hash — it only has to be stable
        // across launches and distinct across hosts.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in host.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return "mux-" + String(hash, radix: 16)
    }

    static func controlSocketURL(forHost host: String, in directory: URL) -> URL {
        directory.appendingPathComponent(socketFileName(forHost: host))
    }

    static func controlSocketURL(forHost host: String) -> URL {
        controlSocketURL(forHost: host, in: controlDirectory())
    }

    // MARK: - Connection options

    /// The ssh options that route a call through the app-owned master for
    /// `host`, creating the socket directory on first use.  `ControlMaster=auto`
    /// reuses the live master when there is one and creates it when there is
    /// not; `ControlPersist` lets the master outlive any single call so the
    /// 60-second poll does not pay a full connection setup each time, while
    /// still exiting after ten idle minutes.
    static func connectionOptions(forHost host: String) -> [String] {
        ensureControlDirectory()
        return [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlSocketURL(forHost: host).path)",
            "-o", "ControlPersist=600",
        ]
    }

    private static func ensureControlDirectory() {
        try? FileManager.default.createDirectory(
            at: controlDirectory(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    // MARK: - Failure classification

    /// Whether an ssh failure's text marks a dead local control connection
    /// rather than a server or network problem.  Every signature here is a
    /// local artifact: the mux client reporting its master gone, or the
    /// control socket itself refusing.  Plain failures — connection refused,
    /// timeouts, authentication, name resolution — return false: the remedy
    /// for those is not discarding a socket, and callers must keep
    /// reporting them as the server being unreachable.
    static func isDeadSocketFailure(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("mux_client")
            || lower.contains("read from master failed")
            || lower.contains("control socket")
            || lower.contains("broken pipe")
    }

    static func isDeadSocketFailure(_ error: Error) -> Bool {
        isDeadSocketFailure(error.localizedDescription)
    }

    // MARK: - Invalidation

    /// Discards the master connection for `host`: asks the master to exit
    /// (`ssh -O exit` against the app's control path) and removes the socket
    /// file if anything still has it there.  Both steps ignore failure — the
    /// master may already be gone, which is the usual case — because the
    /// point is the guarantee that follows: after this returns, no attempt
    /// can be issued over the old socket or its path, so the next ssh call
    /// creates a brand-new master first and runs over that fresh connection
    /// only.
    static func invalidate(host: String) async {
        let socket = controlSocketURL(forHost: host)
        await Task.detached(priority: .utility) {
            exitMaster(host: host, socket: socket)
            try? FileManager.default.removeItem(at: socket)
        }.value
    }

    private static func exitMaster(host: String, socket: URL) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=3",
            "-o", "ControlPath=\(socket.path)",
            "-O", "exit",
            host,
        ]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in done.signal() }
        do {
            try proc.run()
        } catch {
            return
        }
        if done.wait(timeout: .now() + 5) == .timedOut, proc.isRunning {
            proc.terminate()
        }
    }

    // MARK: - Recovery

    /// Runs `attempt`; if it fails with a dead-socket error, discards the
    /// connection via `discard` and runs `attempt` exactly once more, over
    /// the fresh connection the retry creates.  Any other error propagates
    /// untouched, and a second failure of any kind propagates too — recovery
    /// is one discard and one fresh attempt, never a loop against a socket
    /// that may still be the dead one.
    static func retryingOnceOnDeadSocket<T>(
        attempt: () async throws -> T,
        discard: () async -> Void
    ) async throws -> T {
        do {
            return try await attempt()
        } catch {
            guard isDeadSocketFailure(error) else { throw error }
            await discard()
            return try await attempt()
        }
    }
}
