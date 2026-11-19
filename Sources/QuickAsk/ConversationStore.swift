import Foundation

/// The conversation shown in the popup. Kept in memory only, and each request
/// runs an unsaved CLI session; the only thing on disk is the conversation's
/// scratch folder, which is deleted with the conversation.
/// All methods are called on the main thread.
final class ConversationStore {
    private(set) var messages: [ChatMessage] = []
    private(set) var pending: String?  // streaming answer; nil when idle
    private(set) var status: String?   // current tool activity, while streaming
    private(set) var error: String?
    private var scratch: URL?
    private(set) var model: String
    let provider: AgentProvider

    var onChange: (() -> Void)?

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

    /// Returns whether the question was sent.
    @discardableResult
    func send(_ text: String, context: AttachedContext? = nil) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return false }
        run(messages + [ChatMessage(role: .user, content: text, context: context)])
        return true
    }

    /// Asks the last question again (with the current model).
    func retry() {
        guard !isLoading, let last = messages.lastIndex(where: { $0.role == .user }) else { return }
        run(Array(messages[...last]))
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

    func reset() {
        generation += 1
        runner.cancel()
        messages = []
        pending = nil
        status = nil
        error = nil
        ScratchSpace.remove(scratch)
        scratch = nil
        onChange?()
    }

    private func run(_ history: [ChatMessage]) {
        generation += 1
        let current = generation
        messages = history
        pending = ""
        status = nil
        error = nil
        onChange?()

        if scratch == nil { scratch = ScratchSpace.make() }
        let request = AgentRequest(
            messages: history,
            model: model,
            instructions: Prompt.instructions(extra: settings.instructions, web: settings.webSearch),
            workingDirectory: scratch!,
            allowWeb: settings.webSearch
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
