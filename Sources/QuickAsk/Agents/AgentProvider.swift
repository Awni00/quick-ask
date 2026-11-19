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

/// Providers list their models from fastest to most capable; the popup's
/// speed dial shows them in that order.
struct ModelOption {
    let id: String     // value passed to the CLI
    let label: String  // shown in the popup
    var hint: String = ""  // a few words for the tooltip, e.g. "fastest"
}

/// For providers with sessions: start a new one (the prompt is the whole
/// conversation so far) or resume one (the prompt is just the new message).
enum SessionMode: Equatable {
    case start(id: String)
    case resume(id: String)
}

struct AgentRequest {
    var messages: [ChatMessage]
    var model: String?
    var instructions: String
    /// The conversation's folder (see ScratchSpace).
    var workingDirectory: URL
    /// Whether the agent may search the web and fetch pages.
    var allowWeb = true
    /// nil for providers without sessions: every request is self-contained.
    var session: SessionMode? = nil
    /// A display name for a new session (shown in the provider's app after ⌘O).
    var title: String? = nil
}

/// Whether the CLI is signed in, for the settings window.
struct SignInStatus {
    var signedIn: Bool
    var expires: Date?
}

enum AgentEvent {
    case text(String)      // a streamed piece of the answer
    case status(String)    // what the agent is doing, e.g. "Searching the web: …"
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

    /// Continuing a conversation as a new chat in the provider's app, with the
    /// transcript filled in (⇧⌘O). nil if the provider has no such app.
    var handoff: HandoffTarget? { get }

    /// Whether the CLI keeps sessions that can be resumed and handed off. If
    /// so, follow-ups resume the session and ⌘O continues that same session in
    /// the provider's app.
    var supportsSessions: Bool { get }
    /// The app ⌘O continues a session in (e.g. "Claude Code"), and the link that
    /// opens a session there. nil if sessions can't be handed off.
    var sessionHandoff: SessionHandoff? { get }
    /// Deletes the CLI's saved sessions with these ids (in `workingDirectory`).
    func removeSessions(ids: [String], workingDirectory: URL)
    /// Deletes every saved session in `workingDirectory` except the kept ids.
    func removeSessions(workingDirectory: URL, except keep: Set<String>)
    /// Earlier layout (one working directory per conversation): deletes saved
    /// sessions for every folder under `root` except the named ones.
    func removeSessions(under root: URL, except keep: Set<String>)

    func arguments(for request: AgentRequest) -> [String]
    /// Asks the CLI whether it's signed in (blocking; call off the main thread).
    /// nil if the provider can't tell.
    func signInStatus(executable: String) -> SignInStatus?
    /// Text written to the CLI's stdin (the prompt).
    func standardInput(for request: AgentRequest) -> String
    func makeParser() -> AgentOutputParser
}

extension AgentProvider {
    var removedEnvironmentPrefixes: [String] { [] }
    var handoff: HandoffTarget? { nil }
    var supportsSessions: Bool { false }
    var sessionHandoff: SessionHandoff? { nil }
    func removeSessions(ids: [String], workingDirectory: URL) {}
    func removeSessions(workingDirectory: URL, except keep: Set<String>) {}
    func removeSessions(under root: URL, except keep: Set<String>) {}
    func signInStatus(executable: String) -> SignInStatus? { nil }

    func standardInput(for request: AgentRequest) -> String {
        if case .resume = request.session, let last = request.messages.last {
            return last.fullText  // the session already has the rest
        }
        return Prompt.transcript(request.messages)
    }
}

struct SessionHandoff {
    let appName: String  // "Continue in <appName>"
    let makeURL: (_ sessionID: String) -> URL?
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
        $...$ for inline and $$...$$ for display math.
        """

    static let webInstructions = """
        You can search the web and fetch pages. Use them when the question needs current, \
        specific or checkable information, not for things you reliably know. When you use \
        the web, end with the sources as Markdown links.
        """

    static let noWebInstructions = """
        You can't access the web; answer from what you know and say when something may \
        be out of date.
        """

    static func scratchInstructions(notesFolder: String?) -> String {
        guard let notesFolder else {
            return """
                Your working directory is a scratch folder for this conversation: you may keep \
                notes or files there across follow-ups. It is deleted when the conversation ends. \
                You cannot run code or access other files.
                """
        }
        return """
            Keep any notes or files for this conversation in the folder `\(notesFolder)/` in \
            your working directory, across follow-ups; it is deleted when the conversation \
            ends. Other folders there belong to other conversations: leave them alone. You \
            cannot run code or access files outside the working directory.
            """
    }

    static func instructions(extra: String, web: Bool = true, notesFolder: String? = nil) -> String {
        let extra = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        return [baseInstructions, web ? webInstructions : noWebInstructions,
                scratchInstructions(notesFolder: notesFolder), extra]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
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
