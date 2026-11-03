import XCTest
@testable import HogHunter

/// Covers the answer the server gives when the owner asks it to stop
/// something: the JSON contract, and the refusal that is not a success.
@MainActor
final class ServerControlTests: XCTestCase {
    func testASuccessfulAnswerIsRecognised() {
        XCTAssertEqual(ServerControl.parse("{\"ok\":true}"), true)
    }

    func testARefusalIsNotASuccess() {
        XCTAssertEqual(ServerControl.parse("{\"ok\":false,\"reason\":\"docker refused\"}"), false)
    }

    func testAnAnswerThatIsNotJSONIsNotASuccess() {
        /// The control script is the only thing that may say "done".  Output
        /// that is not its JSON is treated as a refusal, never as a success.
        XCTAssertNil(ServerControl.parse("permission denied"))
        XCTAssertNil(ServerControl.parse(""))
    }

    func testInvalidShapesAndNumericBooleansCannotReportActed() async {
        for output in ["", "permission denied", "[]", "null", "{}", "{\"ok\":1}",
                       "{\"ok\":0}", "{\"ok\":\"true\"}", "{\"ok\":null}",
                       "{\"ok\":[]}", "{\"ok\":true} trailing"] {
            XCTAssertNil(ServerControl.parse(output), output)
            XCTAssertFalse(SSHCommand.isControlAnswer(output), output)
            let control = ServerControl(runner: { _, _ in output })
            await control.stop(process: fixtureProcess(), host: "server.example")
            guard case .failed = control.lastOutcome else {
                XCTFail("Invalid response must fail: \(output)")
                continue
            }
        }
    }

    func testConcurrentActionIsRefusedWhileFirstRunnerIsSuspended() async {
        let gate = ControlGate()
        let control = ServerControl(runner: { _, _ in
            await gate.wait()
            return "{\"ok\":true}"
        })
        let first = Task { await control.stop(process: fixtureProcess(name: "first"), host: "server.example") }
        while !control.isWorking { await Task.yield() }
        await control.stop(process: fixtureProcess(name: "second"), host: "server.example")
        XCTAssertEqual(control.lastOutcome, .refused("Another server action is already running."))
        await gate.release()
        await first.value
        let count = await gate.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(control.lastOutcome, .acted("Asked first to quit"))
    }

    func testTheReasonIsReadFromTheAnswer() {
        XCTAssertEqual(ServerControl.reason(from: "{\"ok\":false,\"reason\":\"that process changed since it was sampled\"}"),
                       "that process changed since it was sampled")
        XCTAssertNil(ServerControl.reason(from: "{\"ok\":true}"))
    }

    func testStoppingAProcessNamesItByItsIdentity() async {
        /// The command carries the pid and the start time, so a pid that was
        /// recycled between the reading and the click is refused by the server.
        let recorder = CommandRecorder()
        let control = ServerControl(runner: { host, arguments in
            await recorder.record(host: host, arguments: arguments)
            return "{\"ok\":true}"
        })
        let process = VPSProcess(pid: 4242, name: "next-server", startTime: 99887766,
                                 owner: "root", container: nil, cpuPercent: 120, memoryBytes: nil, bootID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                                 allowedActions: ["quit", "force-quit", "tame", "untame", "sample"])
        await control.stop(process: process, host: "fleet-hetzner-nbg1")

        let command = await recorder.command
        XCTAssertEqual(command.host, "fleet-hetzner-nbg1")
        XCTAssertTrue(command.arguments.contains("/usr/local/sbin/hoghunter-control"))
        XCTAssertTrue(command.arguments.contains("stop-process"))
        XCTAssertTrue(command.arguments.contains("--pid"))
        XCTAssertTrue(command.arguments.contains("4242"))
        XCTAssertTrue(command.arguments.contains("--start-time"))
        XCTAssertTrue(command.arguments.contains("99887766"))
        XCTAssertTrue(command.arguments.contains("--confirm"))
        XCTAssertEqual(control.lastOutcome, .acted("Asked next-server to quit"))
    }

    func testARefusalFromTheServerIsReportedAsARefusal() async {
        let control = ServerControl(runner: { _, _ in
            "{\"ok\":false,\"reason\":\"that process changed since it was sampled\"}"
        })
        let process = VPSProcess(pid: 4242, name: "next-server", startTime: 1,
                                 owner: "root", container: nil, cpuPercent: 1, memoryBytes: nil, bootID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                                 allowedActions: ["quit", "force-quit", "tame", "untame", "sample"])
        await control.stop(process: process, host: "server")
        XCTAssertEqual(control.lastOutcome, .refused("that process changed since it was sampled"))
    }

    func testNoHostIsAFailureRatherThanASilentNothing() async {
        let control = ServerControl(runner: { _, _ in "{\"ok\":true}" })
        let process = VPSProcess(pid: 1, name: "x", startTime: 1, owner: "root",
                                 container: nil, cpuPercent: 0, memoryBytes: nil, bootID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                                 allowedActions: ["quit", "force-quit", "tame", "untame", "sample"])
        await control.stop(process: process, host: "   ")
        guard case .failed = control.lastOutcome else {
            return XCTFail("An empty host must fail, not quietly do nothing")
        }
    }

    func testStoppingACoolifyWorkloadNamesTheWorkload() async {
        let recorder = CommandRecorder()
        let control = ServerControl(runner: { host, arguments in
            await recorder.record(host: host, arguments: arguments)
            return "{\"ok\":true}"
        })
        let resource = VPSCoolifyResource(uuid: "workload", name: "Example / Worker", container: "worker-box",
                                         type: "application", status: "running", cpuPercent: nil, memoryBytes: nil,
                                         image: nil, startedAt: "2026-11-03T00:00:00Z", containerID: String(repeating: "a", count: 64),
                                         allowedActions: ["stop", "restart"])
        await control.stop(resource: resource, host: "server", allowWorkloadInterruption: true)
        let command = await recorder.command
        XCTAssertTrue(command.arguments.contains("stop-container"))
        XCTAssertTrue(command.arguments.contains("worker-box"))
        XCTAssertTrue(command.arguments.contains("--container-id"))
        XCTAssertTrue(command.arguments.contains("--started-at"))
        XCTAssertTrue(command.arguments.contains("--allow-workload-interruption"))
        XCTAssertTrue(command.arguments.contains("--confirm"))
    }

    private func fixtureProcess(name: String = "worker") -> VPSProcess {
        VPSProcess(pid: 4242, name: name, startTime: 999, owner: "root", container: nil,
                   cpuPercent: 10, memoryBytes: nil, bootID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                   allowedActions: ["quit", "force-quit", "tame", "untame", "sample"])
    }

    func testForceTameUntameAndSampleUseFixedVerbsAndIdentity() async {
        let recorder = CommandRecorder()
        let control = ServerControl(runner: { host, arguments in
            await recorder.record(host: host, arguments: arguments)
            return "{\"ok\":true}"
        })
        let process = fixtureProcess()
        await control.stop(process: process, host: "server", force: true)
        var command = await recorder.command
        XCTAssertEqual(Array(command.arguments.prefix(3)), ["sudo", "-n", "/usr/local/sbin/hoghunter-control"])
        XCTAssertTrue(command.arguments.contains("--force"))
        XCTAssertTrue(command.arguments.contains("--boot-id"))
        await control.tame(process: process, host: "server")
        command = await recorder.command
        XCTAssertTrue(command.arguments.contains("tame-process"))
        await control.untame(process: process, host: "server")
        command = await recorder.command
        XCTAssertTrue(command.arguments.contains("untame-process"))
        await control.sample(process: process, host: "server")
        command = await recorder.command
        XCTAssertTrue(command.arguments.contains("sample-process"))
        guard case .failed = control.lastOutcome else { return XCTFail("Missing sample report must fail") }
    }

    func testLegacyIdentitiesAndUnacknowledgedWorkloadsNeverReachRunner() async {
        let control = ServerControl(runner: { _, _ in XCTFail("Unsafe request reached runner"); return "" })
        await control.stopContainer(named: "legacy", host: "server")
        let old = VPSProcess(pid: 4242, name: "worker", startTime: 999, owner: "root", container: nil,
                             cpuPercent: 0, memoryBytes: nil)
        await control.stop(process: old, host: "server")
        guard case .refused = control.lastOutcome else { return XCTFail("Legacy process must refuse") }
        let resource = VPSCoolifyResource(uuid: "worker", name: "Worker", container: "worker", type: "application",
                                         status: "running", cpuPercent: nil, memoryBytes: nil, image: nil,
                                         startedAt: "2026-11-03T00:00:00Z", containerID: String(repeating: "a", count: 64),
                                         allowedActions: ["stop", "restart"])
        await control.restart(resource: resource, host: "server")
        guard case .refused = control.lastOutcome else { return XCTFail("Workload interruption needs acknowledgement") }
    }

    func testRemoteArgumentsCarryingSpacesAreQuotedForSSH() {
        /// ssh joins the remote command with spaces, so a display name would
        /// otherwise split into several arguments on the server.
        XCTAssertEqual(SSHCommand.shellQuote("/usr/local/sbin/hoghunter-control"),
                       "/usr/local/sbin/hoghunter-control")
        XCTAssertEqual(SSHCommand.shellQuote("--name"), "--name")
        XCTAssertEqual(SSHCommand.shellQuote("fleet-infra / um-appworker"),
                       "'fleet-infra / um-appworker'")
        XCTAssertEqual(SSHCommand.shellQuote(""), "''")
    }

    func testAControlAnswerOnStdoutIsRecognised() {
        XCTAssertTrue(SSHCommand.isControlAnswer("{\"ok\":false,\"reason\":\"that workload is not running on this host\"}"))
        XCTAssertTrue(SSHCommand.isControlAnswer("{\"ok\":true}"))
        XCTAssertFalse(SSHCommand.isControlAnswer(""))
        XCTAssertFalse(SSHCommand.isControlAnswer("SSH connection failed"))
        XCTAssertFalse(SSHCommand.isControlAnswer("{\"ok\":true}", refusalOnly: true))
        XCTAssertTrue(SSHCommand.isControlAnswer("{\"ok\":false}", refusalOnly: true))
    }
}

/// Records the command the control path would have run.
private actor CommandRecorder {
    struct Command {
        let host: String
        let arguments: [String]
    }

    private(set) var command = Command(host: "", arguments: [])

    func record(host: String, arguments: [String]) {
        command = Command(host: host, arguments: arguments)
    }
}

private actor ControlGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var count = 0

    func wait() async {
        count += 1
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
