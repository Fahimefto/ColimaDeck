import Foundation

struct CommandResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String

    var ok: Bool { status == 0 }

    /// Best human-readable explanation of a failure.
    var message: String {
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Thread-safe byte buffer used to collect pipe output.
private final class Buffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
    }

    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

enum Shell {
    /// GUI apps don't inherit the login shell PATH, so look in the usual Homebrew spots too.
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let inherited = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        env["PATH"] = (searchPaths + inherited).filter { seen.insert($0).inserted }.joined(separator: ":")
        return env
    }

    static func locate(_ tool: String) -> String? {
        let dirs = environment["PATH"]?.split(separator: ":").map(String.init) ?? searchPaths
        return dirs
            .map { "\($0)/\(tool)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs a command-line tool and returns its output once it exits.
    /// `onOutput` receives stdout/stderr chunks as they arrive, for long operations like `colima start`.
    static func run(
        _ tool: String,
        _ args: [String],
        env extra: [String: String] = [:],
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let path = locate(tool) else {
                    continuation.resume(returning: CommandResult(
                        status: 127, stdout: "",
                        stderr: "Couldn't find `\(tool)`. Install it with `brew install \(tool)`."
                    ))
                    return
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                var env = environment
                // An empty value removes the variable, e.g. to stop DOCKER_CONTEXT overriding DOCKER_HOST.
                for (key, value) in extra { env[key] = value.isEmpty ? nil : value }
                process.environment = env
                process.standardInput = FileHandle.nullDevice

                let outPipe = Pipe(), errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                let out = Buffer(), err = Buffer()
                let drained = DispatchGroup()
                for (pipe, buffer) in [(outPipe, out), (errPipe, err)] {
                    drained.enter()
                    pipe.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        if chunk.isEmpty {
                            handle.readabilityHandler = nil
                            drained.leave()
                            return
                        }
                        buffer.append(chunk)
                        onOutput?(String(decoding: chunk, as: UTF8.self))
                    }
                }

                do {
                    try process.run()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: CommandResult(status: 126, stdout: "", stderr: error.localizedDescription))
                    return
                }

                process.waitUntilExit()
                // Background daemons (e.g. Lima's host agent) can inherit the pipes and keep them
                // open, so don't wait forever for EOF once the command itself has exited.
                _ = drained.wait(timeout: .now() + 2)

                continuation.resume(returning: CommandResult(
                    status: process.terminationStatus,
                    stdout: out.string,
                    stderr: err.string
                ))
            }
        }
    }
}
