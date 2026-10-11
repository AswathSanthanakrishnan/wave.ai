import Foundation

/// Only fixed executable paths are available. No shell is ever invoked.
enum MacCommand {
    enum Program: String { case script = "/usr/bin/osascript", power = "/usr/bin/pmset", disk = "/usr/bin/hdiutil", gatekeeper = "/usr/sbin/spctl", ditto = "/usr/bin/ditto" }
    struct Result { let status: Int32; let output: Data }
    static func run(_ program: Program, _ arguments: [String], timeout: Double = 30) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: program.rawValue)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            deadline.cancel()
            return Result(status: process.terminationStatus, output: output)
        }.value
    }
    static func appleScript(_ source: String) async throws {
        let result = try await run(.script, ["-e", source])
        guard result.status == 0 else {
            throw ActionError.failed(String(data: result.output, encoding: .utf8) ?? "Automation failed")
        }
    }
    static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
