import Foundation

/// The conversation shown in the popup.
///
/// On disk it has a folder (the CLI's working directory) and, for providers
/// with sessions, the CLI's saved session. Follow-ups resume that session.
/// Both are deleted when the conversation ends, unless it was handed off to
/// the provider's app with ⌘O.
/// All methods are called on the main thread.
final class ConversationStore {
    private(set) var messages: [ChatMessage] = []
    private(set) var pending: String?  // streaming answer; nil when idle
    private(set) var status: String?   // current tool activity, while streaming
    private(set) var error: String?
    private(set) var model: String
    let provider: AgentProvider

    var onChange: (() -> Void)?

    private var folder: URL?
    /// The CLI session holding this conversation, and whether it matches
    /// `messages` (false after a failed or stopped answer, or while answering).
    private var sessionID: String?
    private var sessionInSync = false

    private let settings: Settings
    private let runner = AgentRunner()
    private var generation = 0  // ignores callbacks from superseded requests

    init(provider: AgentProvider, settings: Settings) {
        self.provider = provider
        self.settings = settings
        self.model = settings.model(for: provider)
    }

    var isLoading: Bool { pending != nil }
    var isEmpty: Bool { messages.isEmpty && pending == nil && error == nil }
    var lastAnswer: String? { messages.last { $0.role == .assistant }?.content }

    /// Whether ⌘O can continue this conversation's session in the provider's app.
    var canHandOffSession: Bool {
        provider.sessionHandoff != nil && sessionInSync && sessionID != nil && !isLoading
    }

    /// Returns whether the question was sent.
    @discardableResult
    func send(_ text: String, context: AttachedContext? = nil) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return false }
        run(messages + [ChatMessage(role: .user, content: text, context: context)], fresh: false)
        return true
    }

    /// Asks the last question again (with the current model). Sessions can't be
    /// rewound, so this starts a new session from the conversation so far.
    func retry() {
        guard !isLoading, let last = messages.lastIndex(where: { $0.role == .user }) else { return }
        run(Array(messages[...last]), fresh: true)
    }

    func stop() {
        guard isLoading else { return }
        runner.cancel()
    }

    func setModel(_ id: String) {
        guard provider.models.contains(where: { $0.id == id }) else { return }
        model = id
        settings.setModel(id, for: provider)
        onChange?()
    }

    /// Picks up a default model changed in the settings window.
    func reloadModel() {
        let saved = settings.model(for: provider)
        guard saved != model else { return }
        model = saved
        onChange?()
    }

    /// The link that continues this conversation's session in the provider's
    /// app. Marks the conversation as handed off (its files are kept) and
    /// starts a fresh one here, so the two don't both write to the session.
    func handOffSession() -> URL? {
        guard canHandOffSession, let handoff = provider.sessionHandoff, let sessionID, let folder,
              let url = handoff.makeURL(sessionID) else { return nil }
        settings.handedOffConversations.insert(folder.lastPathComponent)
        settings.handedOffSessions.insert(sessionID)
        reset()
        return url
    }

    /// The session's display name: the first question, on one line, shortened.
    static func title(for messages: [ChatMessage]) -> String? {
        guard let first = messages.first(where: { $0.role == .user }) else { return nil }
        let line = first.content.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        return line.count > 60 ? String(line.prefix(59)).trimmingCharacters(in: .whitespaces) + "…" : line
    }

    func reset() {
        generation += 1
        runner.cancel()
        messages = []
        pending = nil
        status = nil
        error = nil
        if let folder, !settings.handedOffConversations.contains(folder.lastPathComponent) {
            ScratchSpace.removeConversation(folder)
            if let sessionID { provider.removeSessions(ids: [sessionID], workingDirectory: ScratchSpace.workspace) }
        }
        folder = nil
        sessionID = nil
        sessionInSync = false
        onChange?()
    }

    /// Answers the last user message in `history`. With sessions: resumes the
    /// session if it's in sync, otherwise (or when `fresh`) starts a new one
    /// whose first prompt is the whole conversation so far.
    private func run(_ history: [ChatMessage], fresh: Bool) {
        generation += 1
        let current = generation
        messages = history
        pending = ""
        status = nil
        error = nil
        onChange?()

        if folder == nil { folder = ScratchSpace.makeConversation() }
        var session: SessionMode?
        if provider.supportsSessions {
            if !fresh, sessionInSync, let sessionID {
                session = .resume(id: sessionID)
            } else {
                // The previous session (if any) is superseded; delete it now.
                if let old = sessionID { provider.removeSessions(ids: [old], workingDirectory: ScratchSpace.workspace) }
                let id = UUID().uuidString.lowercased()
                sessionID = id
                session = .start(id: id)
            }
            sessionInSync = false
        }
        let request = AgentRequest(
            messages: history,
            model: model,
            instructions: Prompt.instructions(extra: settings.instructions, web: settings.webSearch,
                                              notesFolder: folder!.lastPathComponent),
            workingDirectory: ScratchSpace.workspace,
            allowWeb: settings.webSearch,
            session: session,
            title: Self.title(for: history)
        )
        let executable = Executable.resolve(
            override: settings.executableOverride(for: provider),
            candidates: provider.executableCandidates
        )

        runner.run(
            provider: provider,
            executable: executable,
            request: request,
            onText: { [weak self] piece in
                guard let self, current == self.generation else { return }
                self.pending = (self.pending ?? "") + piece
                if !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.status = nil }
                self.onChange?()
            },
            onStatus: { [weak self] status in
                guard let self, current == self.generation else { return }
                self.status = status
                self.onChange?()
            },
            completion: { [weak self] outcome in
                guard let self, current == self.generation else { return }
                let partial = self.pending ?? ""
                self.pending = nil
                self.status = nil
                switch outcome {
                case .success(let text):
                    self.messages.append(ChatMessage(role: .assistant, content: text))
                    self.sessionInSync = true
                case .failure(let message):
                    self.error = message
                case .cancelled:
                    if !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.messages.append(ChatMessage(role: .assistant, content: partial, stopped: true))
                    }
                }
                self.onChange?()
            }
        )
    }
}
