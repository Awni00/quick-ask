import Foundation

// The provider layer: everything specific to one agent CLI (Claude Code,
// Codex, ...) lives in a type conforming to `AgentProvider`. The rest of the
// app only sees messages in and text deltas out.
//
// To add a CLI: write a provider (see ClaudeCodeProvider.swift) and add it to
// `ProviderRegistry.all`.

struct ChatMessage: Equatable {
    enum Role: String { case user, assistant }
    var role: Role
    var content: String
    var stopped = false  // answer cut short by the user
    var context: AttachedContext? = nil  // selected text attached to a question

    /// The message as the model sees it: the attached selection, then the question.
    var fullText: String {
        guard let context else { return content }
        let from = context.source.map { " (from \($0))" } ?? ""
        let cut = context.truncated ? "\n[selection truncated]" : ""
        return "Selected text\(from):\n<selection>\n\(context.text)\(cut)\n</selection>\n\n\(content)"
    }
}

struct ModelOption {
    let id: String     // value passed to the CLI
    let label: String  // shown in the popup
}

struct AgentRequest {
    var messages: [ChatMessage]
    var model: String?
    var instructions: String
}

enum AgentEvent {
    case text(String)      // a streamed piece of the answer
    case result(String)    // the CLI reported the final answer
    case failure(String)   // the CLI reported an error
}

/// Turns the CLI's stdout, one line at a time, into events.
protocol AgentOutputParser: AnyObject {
    func consume(line: String) -> [AgentEvent]
}

protocol AgentProvider {
    var id: String { get }
    var displayName: String { get }
    var models: [ModelOption] { get }
    var defaultModel: String { get }
    /// Where to look for the CLI, in order. `~` is expanded.
    var executableCandidates: [String] { get }

    /// Environment variables (by prefix) not passed on to the CLI, e.g. ones a
    /// parent agent session left behind that would change how the CLI runs.
    var removedEnvironmentPrefixes: [String] { get }

    /// Continuing a conversation in the provider's full app ("Open in Claude").
    /// nil if the provider has no app to hand off to.
    var handoff: HandoffTarget? { get }

    func arguments(for request: AgentRequest) -> [String]
    /// Text written to the CLI's stdin (the prompt).
    func standardInput(for request: AgentRequest) -> String
    func makeParser() -> AgentOutputParser
}

extension AgentProvider {
    var removedEnvironmentPrefixes: [String] { [] }
    var handoff: HandoffTarget? { nil }

    func standardInput(for request: AgentRequest) -> String {
        Prompt.transcript(request.messages)
    }
}

enum ProviderRegistry {
    static let all: [AgentProvider] = [ClaudeCodeProvider()]

    static func provider(id: String) -> AgentProvider {
        all.first { $0.id == id } ?? all[0]
    }
}

enum Prompt {
    static let baseInstructions = """
        You answer quick questions asked from a desktop popup. Be concise and direct. \
        Answer in Markdown; use fenced code blocks for code. Write math in LaTeX with \
        $...$ for inline and $$...$$ for display math. You have no tools.
        """

    static func instructions(extra: String) -> String {
        let extra = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        return extra.isEmpty ? baseInstructions : baseInstructions + "\n\n" + extra
    }

    /// A single question is sent as-is; a longer conversation becomes a transcript,
    /// since each request starts a fresh, unsaved CLI session.
    static func transcript(_ messages: [ChatMessage]) -> String {
        if messages.count == 1 { return messages[0].fullText }
        let turns = messages
            .map { "<\($0.role.rawValue)>\n\($0.fullText)\n</\($0.role.rawValue)>" }
            .joined(separator: "\n\n")
        return "Here is our conversation so far. Reply to the last user message.\n\n" + turns
    }
}
