import Foundation

/// Claude Code CLI (`claude -p`), using the user's claude.ai subscription.
///
/// Runs in the CLI's restricted mode with a small tool set: web search, fetching
/// pages, and file tools confined to the conversation's folder. No tool can run
/// code. MCP servers and user settings are off. Each conversation is a CLI
/// session (deleted with the conversation unless it's handed off with ⌘O).
struct ClaudeCodeProvider: AgentProvider {
    let id = "claude"
    let displayName = "Claude"
    let models = [
        ModelOption(id: "haiku", label: "Haiku", hint: "fastest"),
        ModelOption(id: "sonnet", label: "Sonnet", hint: "balanced"),
        ModelOption(id: "opus", label: "Opus", hint: "most capable"),
    ]
    let defaultModel = "sonnet"
    let executableCandidates = ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    // If Quick Ask was started from inside a Claude Code session, its CLAUDE_CODE_*
    // variables would make this CLI act as that session's child (plugins, auth
    // hand-off), and an ANTHROPIC_API_KEY would bill the API instead of the
    // subscription.
    let removedEnvironmentPrefixes = ["CLAUDE", "ANTHROPIC_"]

    /// The only tools the agent gets. `--restricted` confines the file tools to
    /// the working directory (the scratch folder).
    static let tools = ["WebSearch", "WebFetch", "Read", "Write", "Edit", "Glob", "Grep"]

    // The Claude desktop app opens claude://claude.ai/new?q=... as a new chat with
    // the text filled in (it keeps at most 14,336 characters). Without the app,
    // claude.ai does the same in the browser; long URLs are risky there, so its
    // limit is lower.
    let handoff: HandoffTarget? = HandoffTarget(appName: "Claude", links: [
        .init(maxCharacters: 14_000) { text in
            URL(string: "claude://claude.ai/new?" + HandoffTarget.query([("q", text), ("surface", "chat")]))
        },
        .init(maxCharacters: 6_000) { text in
            URL(string: "https://claude.ai/new?" + HandoffTarget.query([("q", text)]))
        },
    ])

    // Sessions: the CLI saves each session under ~/.claude/projects/<folder>/,
    // where <folder> is the working directory with every character other than
    // ASCII letters and digits replaced by "-". The desktop app imports a saved
    // session with claude://resume?session=<id> and opens it in its Code tab.
    let supportsSessions = true
    let sessionHandoff: SessionHandoff? = SessionHandoff(appName: "Claude Code") { id in
        URL(string: "claude://resume?session=\(id)")
    }

    static var projectsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects", isDirectory: true)
    }

    static func projectFolderName(for directory: URL) -> String {
        // The CLI uses the real path (symlinks resolved) of its working directory.
        String(directory.resolvingSymlinksInPath().path.unicodeScalars.map {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) ? Character($0) : "-"
        })
    }

    func removeSessions(workingDirectory: URL) {
        let folder = Self.projectFolderName(for: workingDirectory)
        guard !folder.isEmpty else { return }
        try? FileManager.default.removeItem(at: Self.projectsDirectory.appendingPathComponent(folder))
    }

    func removeSessions(under root: URL, except keep: Set<String>) {
        // Only folders named after `root/<conversation id>`.
        let prefix = Self.projectFolderName(for: root) + "-"
        let keepNames = Set(keep.map { Self.projectFolderName(for: root.appendingPathComponent($0)) })
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.projectsDirectory.path)) ?? []
        for name in names where name.hasPrefix(prefix) && !keepNames.contains(name) {
            try? FileManager.default.removeItem(at: Self.projectsDirectory.appendingPathComponent(name))
        }
    }

    func arguments(for request: AgentRequest) -> [String] {
        let webTools: Set = ["WebSearch", "WebFetch"]
        let tools = Self.tools.filter { request.allowWeb || !webTools.contains($0) }.joined(separator: ",")
        var session: [String]
        switch request.session {
        case .start(let id): session = ["--session-id", id]
        case .resume(let id): session = ["--resume", id]
        case nil: session = ["--no-session-persistence"]
        }
        var args = ["-p"] + session + [
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            // Restricted mode: no code-running tools, file tools confined to the
            // working directory, settings files ignored.
            "--restricted",
            "--tools", tools,
            "--allowedTools", tools,
            // Anything outside the allowed tools is refused, not left waiting
            // for a permission prompt nobody can answer.
            "--permission-prompts", "none",
            "--strict-mcp-config",
            // Also skip settings explicitly: their plugins and hooks don't belong
            // in a quick question, and loading them can touch protected folders.
            "--setting-sources=",
            "--system-prompt", request.instructions,
        ]
        if let model = request.model { args += ["--model", model] }
        return args
    }

    /// `claude auth status` prints JSON with `loggedIn` and `loginExpiresAt`.
    func signInStatus(executable: String) -> SignInStatus? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["auth", "status"]
        process.environment = Executable.environment(removingPrefixes: removedEnvironmentPrefixes)
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expires = (json["loginExpiresAt"] as? String).flatMap { formatter.date(from: $0) }
        return SignInStatus(signedIn: json["loggedIn"] as? Bool ?? false, expires: expires)
    }

    func makeParser() -> AgentOutputParser { Parser() }

    /// Parses `--output-format stream-json` lines.
    final class Parser: AgentOutputParser {
        private var sawText = false
        private var toolSinceText = false

        func consume(line: String) -> [AgentEvent] {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String
            else { return [] }

            switch type {
            case "stream_event":
                guard let event = obj["event"] as? [String: Any] else { return [] }
                // Text after a tool call starts a new paragraph.
                if event["type"] as? String == "content_block_start",
                   (event["content_block"] as? [String: Any])?["type"] as? String == "text",
                   sawText, toolSinceText {
                    toolSinceText = false
                    return [.text("\n\n")]
                }
                guard event["type"] as? String == "content_block_delta",
                      let delta = event["delta"] as? [String: Any],
                      delta["type"] as? String == "text_delta",
                      let text = delta["text"] as? String
                else { return [] }
                sawText = true
                return [.text(text)]
            case "assistant":
                // A finished assistant message; its tool calls carry full inputs.
                let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                return content.compactMap { block in
                    guard block["type"] as? String == "tool_use", let name = block["name"] as? String else { return nil }
                    toolSinceText = true
                    return .status(Self.describe(tool: name, input: block["input"] as? [String: Any] ?? [:]))
                }
            case "result":
                let text = obj["result"] as? String ?? ""
                if obj["is_error"] as? Bool == true {
                    return [.failure(text.isEmpty ? "Claude returned an error." : text)]
                }
                return [.result(text)]
            default:
                return []
            }
        }

        /// A short, human description of a tool call for the popup.
        static func describe(tool: String, input: [String: Any]) -> String {
            func file(_ key: String) -> String {
                ((input[key] as? String).map { ($0 as NSString).lastPathComponent }) ?? "a file"
            }
            switch tool {
            case "WebSearch":
                return "Searching the web: " + (input["query"] as? String ?? "")
            case "WebFetch":
                let url = (input["url"] as? String).flatMap(URL.init(string:))
                return "Reading " + (url?.host ?? "a web page")
            case "Read": return "Reading notes: " + file("file_path")
            case "Write", "Edit": return "Writing notes: " + file("file_path")
            case "Glob", "Grep": return "Searching notes"
            default: return "Using \(tool)"
            }
        }
    }
}
