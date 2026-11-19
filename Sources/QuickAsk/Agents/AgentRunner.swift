import Foundation

enum AgentOutcome {
    case success(String)
    case failure(String)
    case cancelled
}

enum Executable {
    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// The user's override if set, else the first candidate that exists.
    static func resolve(override: String?, candidates: [String]) -> String {
        if let override, !override.isEmpty { return expand(override) }
        let expanded = candidates.map(expand)
        return expanded.first { FileManager.default.isExecutableFile(atPath: $0) } ?? expanded[0]
    }

    /// Apps launched from Finder get a minimal environment. CLIs need HOME and
    /// USER to read their login from the Keychain, and a PATH that includes the
    /// usual install folders (e.g. for CLIs that run on Node).
    static func environment(removingPrefixes prefixes: [String] = []) -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { key, _ in
            !prefixes.contains { key.hasPrefix($0) }
        }
        let home = NSHomeDirectory()
        let user = NSUserName()
        env["HOME"] = env["HOME"] ?? home
        env["USER"] = env["USER"] ?? user
        env["LOGNAME"] = env["LOGNAME"] ?? user
        let base = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", base].joined(separator: ":")
        return env
    }
}

/// Runs one CLI request at a time and streams its answer.
/// Callbacks are delivered on the main queue.
final class AgentRunner {
    private final class Run {
        let process: Process
        var cancelled = false
        init(process: Process) { self.process = process }
    }

    private var current: Run?

    func cancel() {
        guard let run = current else { return }
        run.cancelled = true
        if run.process.isRunning { run.process.terminate() }
        current = nil
    }

    func run(
        provider: AgentProvider,
        executable: String,
        request: AgentRequest,
        onText: @escaping (String) -> Void,
        onStatus: @escaping (String) -> Void = { _ in },
        completion: @escaping (AgentOutcome) -> Void
    ) {
        cancel()

        guard FileManager.default.isExecutableFile(atPath: executable) else {
            completion(.failure("\(provider.displayName) CLI not found at \(executable)."))
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = provider.arguments(for: request)
        process.environment = Executable.environment(removingPrefixes: provider.removedEnvironmentPrefixes)
        // The conversation's scratch folder: no project's instructions or settings
        // get picked up, and the agent's file tools are confined to it.
        process.currentDirectoryURL = request.workingDirectory

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            completion(.failure("Couldn't start \(executable): \(error.localizedDescription)"))
            return
        }
        let run = Run(process: process)
        current = run

        let input = Data(provider.standardInput(for: request).utf8)
        DispatchQueue.global().async {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }

        var errorOutput = Data()
        let stderrDone = DispatchGroup()
        stderrDone.enter()
        DispatchQueue.global().async {
            errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
            stderrDone.leave()
        }

        let parser = provider.makeParser()
        DispatchQueue.global().async {
            var answer = ""
            var finalText: String?
            var failure: String?

            func handle(_ lineData: Data) {
                guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { return }
                for event in parser.consume(line: line) {
                    switch event {
                    case .text(let piece):
                        answer += piece
                        DispatchQueue.main.async { onText(piece) }
                    case .status(let status):
                        DispatchQueue.main.async { onStatus(status) }
                    case .result(let text): finalText = text
                    case .failure(let message): failure = message
                    }
                }
            }

            let handle_ = stdout.fileHandleForReading
            var buffer = Data()
            while true {
                let chunk = handle_.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    handle(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
            }
            if !buffer.isEmpty { handle(buffer) }
            process.waitUntilExit()
            stderrDone.wait()

            let status = process.terminationStatus
            let stderrText = String(data: errorOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            DispatchQueue.main.async {
                if run.cancelled { return completion(.cancelled) }
                if let failure { return completion(.failure(failure)) }
                if finalText == nil && status != 0 {
                    return completion(.failure(stderrText.isEmpty ? "\(provider.displayName) CLI exited with status \(status)." : stderrText))
                }
                completion(.success(answer.isEmpty ? (finalText ?? "") : answer))
            }
        }
    }
}
