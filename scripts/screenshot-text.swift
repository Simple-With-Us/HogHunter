// Read actual screenshot text with the system OCR engine; no app or simulator launch.
import Foundation
import Vision

do {
    guard CommandLine.arguments.count == 2 else { throw NSError(domain: "ScreenshotText", code: 1) }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(url: URL(fileURLWithPath: CommandLine.arguments[1]), options: [:]).perform([request])
    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    let data = try JSONSerialization.data(withJSONObject: lines)
    FileHandle.standardOutput.write(data)
} catch {
    FileHandle.standardError.write(Data("Screenshot OCR failed: \(error)\n".utf8))
    exit(1)
}
