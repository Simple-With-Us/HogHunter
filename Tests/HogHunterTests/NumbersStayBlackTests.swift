import XCTest

/// Jay (iMessage, 2026-11-21) wants every number to read in black.  Severity
/// color belongs on bars, badges and pills.  A number that takes a severity
/// color through `foregroundStyle` or `foregroundColor` fails this scan, so a
/// new list or widget cannot bring the hard-to-read yellow back.
final class NumbersStayBlackTests: XCTestCase {

    private let forbidden = [
        "severityColor(",
        "driveSeverityColor(",
        "rowColor(",
        "ServerFormat.color(",
        "Percent >= 100 ?",
        "Percent > 90 ?",
        "Percent > 75 ?",
        "Percent > 80 ?",
    ]

    func testNoNumberTakesASeverityColor() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var offenders: [String] = []
        var scanned = 0
        for dir in ["Sources/UI", "ios/Sources", "ios/Widgets"] {
            let base = root.appendingPathComponent(dir)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                scanned += 1
                let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
                for (index, line) in lines.enumerated() {
                    guard line.contains(".foregroundStyle(") || line.contains(".foregroundColor(") else { continue }
                    if forbidden.contains(where: { line.contains($0) }) {
                        offenders.append("\(dir)/\(url.lastPathComponent):\(index + 1)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(scanned, 20, "the scan found no source files, so it proves nothing")
        XCTAssertEqual(offenders, [], "numbers must use the primary color; keep severity color on bars, badges and pills")
    }
}
