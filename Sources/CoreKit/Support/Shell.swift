import Foundation

/// Minimal helper for shelling out to optional external tools (brew, docker,
/// launchctl). Everything degrades gracefully: missing tool → nil, never a
/// throw. PATH is not consulted — tools are looked up in the standard
/// locations so behavior doesn't depend on the user's shell config.
public enum Shell {
    public struct Output: Sendable {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
        public var succeeded: Bool { exitCode == 0 }
    }

    public static func run(_ executablePath: String, _ arguments: [String]) -> Output? {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return nil }
        // Drain pipes before waiting so a chatty tool can't deadlock us.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    public static func find(_ name: String) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
