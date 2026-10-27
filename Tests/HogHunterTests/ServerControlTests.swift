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
                                 owner: "root", container: nil, cpuPercent: 120, memoryBytes: nil)
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
        XCTAssertEqual(control.lastOutcome, .acted("Stopped next-server"))
    }

    func testARefusalFromTheServerIsReportedAsARefusal() async {
        let control = ServerControl(runner: { _, _ in
            "{\"ok\":false,\"reason\":\"that process changed since it was sampled\"}"
        })
        let process = VPSProcess(pid: 4242, name: "next-server", startTime: 1,
                                 owner: "root", container: nil, cpuPercent: 1, memoryBytes: nil)
        await control.stop(process: process, host: "server")
        XCTAssertEqual(control.lastOutcome, .refused("that process changed since it was sampled"))
    }

    func testNoHostIsAFailureRatherThanASilentNothing() async {
        let control = ServerControl(runner: { _, _ in "{\"ok\":true}" })
        let process = VPSProcess(pid: 1, name: "x", startTime: 1, owner: "root",
                                 container: nil, cpuPercent: 0, memoryBytes: nil)
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
        await control.stopContainer(named: "fleet-infra / um-appworker", host: "server")
        let command = await recorder.command
        XCTAssertTrue(command.arguments.contains("stop-container"))
        XCTAssertTrue(command.arguments.contains("fleet-infra / um-appworker"))
        XCTAssertTrue(command.arguments.contains("--confirm"))
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
