import Foundation

/// Claude Code CLI (`claude -p`), using the user's claude.ai subscription.
/// Sessions are not saved; tools, MCP servers and user settings are turned off.
struct ClaudeCodeProvider: AgentProvider {
    let id = "claude"
    let displayName = "Claude"
    let models = [
        ModelOption(id: "haiku", label: "Haiku"),
        ModelOption(id: "sonnet", label: "Sonnet"),
        ModelOption(id: "opus", label: "Opus"),
    ]
    let defaultModel = "sonnet"
    let executableCandidates = ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    // If Quick Ask was started from inside a Claude Code session, its CLAUDE_CODE_*
    // variables would make this CLI act as that session's child (plugins, auth
    // hand-off), and an ANTHROPIC_API_KEY would bill the API instead of the
    // subscription.
    let removedEnvironmentPrefixes = ["CLAUDE", "ANTHROPIC_"]

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

    func arguments(for request: AgentRequest) -> [String] {
        var args = [
            "-p",
            "--no-session-persistence",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--tools=",
            "--strict-mcp-config",
            // Skip user/project settings: their plugins and hooks don't belong in a
            // quick question, and loading them can touch protected folders
            // (macOS then asks Quick Ask for Documents access).
            "--setting-sources=",
            "--system-prompt", request.instructions,
        ]
        if let model = request.model { args += ["--model", model] }
        return args
    }

    func makeParser() -> AgentOutputParser { Parser() }

    /// Parses `--output-format stream-json` lines.
    final class Parser: AgentOutputParser {
        func consume(line: String) -> [AgentEvent] {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String
            else { return [] }

            switch type {
            case "stream_event":
                guard let event = obj["event"] as? [String: Any],
                      event["type"] as? String == "content_block_delta",
                      let delta = event["delta"] as? [String: Any],
                      delta["type"] as? String == "text_delta",
                      let text = delta["text"] as? String
                else { return [] }
                return [.text(text)]
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
    }
}
