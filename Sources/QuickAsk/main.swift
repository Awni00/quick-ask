import AppKit
import ServiceManagement
import SwiftUI

// Writing a prompt to a CLI that has already exited must not kill the app.
signal(SIGPIPE, SIG_IGN)

let arguments = CommandLine.arguments

if let index = arguments.firstIndex(of: "--settings-snapshot"), index + 1 < arguments.count {
    // QuickAsk --settings-snapshot out.png [dark]: renders the settings window's
    // content offscreen (for checking the layout without a screen capture).
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    if arguments.contains("dark") { app.appearance = NSAppearance(named: .darkAqua) }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 800),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let host = NSHostingView(rootView: SettingsView())
    window.contentView = host
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
        let size = host.fittingSize
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arguments[index + 1]))
        print("wrote \(arguments[index + 1]) \(Int(size.width))×\(Int(size.height))")
        exit(0)
    }
    app.run()
} else if arguments.contains("--login-status") {
    // QuickAsk --login-status: prints the login item's state (run the copy in Applications).
    let names = [0: "notRegistered", 1: "enabled", 2: "requiresApproval", 3: "notFound"]
    let status = SMAppService.mainApp.status
    print("login item: \(names[status.rawValue] ?? "\(status.rawValue)"), setting: \(Settings.shared.launchAtLogin), installed copy: \(LoginItem.isInstalledCopy)")
    exit(0)
} else if arguments.contains("--handoff-test") {
    // QuickAsk --handoff-test: builds hand-off URLs for sample conversations
    // (without opening them) and checks the text decodes back unchanged.
    let provider = ProviderRegistry.provider(id: Settings.shared.providerID)
    guard let target = provider.handoff else { print("no hand-off for \(provider.id)"); exit(1) }
    let tricky = "Is 1+1=2 & a#b? 100% sure: $x^2$, \\frac{a}{b}, ünïcödé, emoji 🙂\nnew line"
    let cases: [(String, [ChatMessage])] = [
        ("short", [ChatMessage(role: .user, content: tricky), ChatMessage(role: .assistant, content: "Yes. " + tricky)]),
        ("long", (0..<40).map { i in
            ChatMessage(role: i % 2 == 0 ? .user : .assistant, content: "Turn \(i): " + String(repeating: "lorem ipsum ", count: 60))
        }),
    ]
    for (name, messages) in cases {
        guard let (url, text) = target.resolve(messages) else { print("\(name): no app can open it"); continue }
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
        print("\(name): \(url.scheme ?? "")://\(url.host ?? "")\(url.path), url length \(url.absoluteString.count), "
              + "text \(text.text.count) chars, truncated \(text.truncated), round-trip \(q == text.text ? "ok" : "MISMATCH")")
        if name == "long" { print("  starts: \(text.text.prefix(120).replacingOccurrences(of: "\n", with: "⏎"))") }
    }
    exit(0)
} else if arguments.contains("--session-test") {
    // QuickAsk --session-test: a real two-turn conversation through the store,
    // checking that follow-ups resume the session, retry starts a new one,
    // hand-off keeps the files and a normal reset deletes them. Doesn't open
    // any app (the hand-off link is only built).
    let settings = Settings.shared
    let provider = ProviderRegistry.provider(id: settings.providerID)
    let store = ConversationStore(provider: provider, settings: settings)
    let savedHandedOff = (settings.handedOffConversations, settings.handedOffSessions)
    var step = 0
    func check(_ ok: Bool, _ what: String) { print("\(ok ? "PASS" : "FAIL")  \(what)") }
    let project = ClaudeCodeProvider.projectsDirectory
        .appendingPathComponent(ClaudeCodeProvider.projectFolderName(for: ScratchSpace.workspace))
    func sessionFiles() -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: project.path)) ?? []).filter { $0.hasSuffix(".jsonl") })
    }
    func conversationFolders() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: ScratchSpace.workspace.path)) ?? [])
    }
    func title(ofSession file: String) -> String? {
        guard let text = try? String(contentsOf: project.appendingPathComponent(file), encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               obj["type"] as? String == "custom-title" { return obj["customTitle"] as? String }
        }
        return nil
    }
    let before = (sessions: sessionFiles(), folders: conversationFolders())
    print("project folder: \(project.lastPathComponent)")
    let savedModel = settings.model(for: provider)
    store.setModel("haiku")
    var waiting = false  // true while an answer we asked for is pending
    func ask(_ action: () -> Void) { waiting = true; action() }
    store.onChange = {
        guard waiting, !store.isLoading else { return }
        waiting = false
        if let error = store.error { print("FAIL  CLI error: \(error)"); exit(1) }
        step += 1
        switch step {
        case 1:
            check(store.lastAnswer != nil, "turn 1 answered")
            check(store.canHandOffSession, "session can be handed off after turn 1")
            ask { store.send("What number did I ask you to remember? Reply with just the number.") }
        case 2:
            check(store.lastAnswer?.contains("4817") == true, "turn 2 resumed the session (answer: \(store.lastAnswer ?? "-"))")
            let new = sessionFiles().subtracting(before.sessions)
            check(new.count == 1, "one session file in the shared project folder")
            let title = new.first.flatMap(title(ofSession:))
            check(title == "Remember the number 4817. Reply with just OK.", "session title is the first question (\(title ?? "-"))")
            ask { store.retry() }
        case 3:
            check(store.lastAnswer?.contains("4817") == true, "retry answered from a fresh session (answer: \(store.lastAnswer ?? "-"))")
            check(sessionFiles().subtracting(before.sessions).count == 1, "retry deleted the superseded session")
            let url = store.handOffSession()
            check(url?.absoluteString.hasPrefix("claude://resume?session=") == true, "hand-off link: \(url?.absoluteString ?? "-")")
            let keptSessions = sessionFiles().subtracting(before.sessions)
            let keptFolders = conversationFolders().subtracting(before.folders)
            check(keptSessions.count == 1 && keptFolders.count == 1, "handed-off conversation kept its folder and session")
            // Clean up the test's handed-off conversation.
            (settings.handedOffConversations, settings.handedOffSessions) = savedHandedOff
            for name in keptFolders { ScratchSpace.removeConversation(ScratchSpace.workspace.appendingPathComponent(name)) }
            provider.removeSessions(ids: keptSessions.map { String($0.dropLast(6)) }, workingDirectory: ScratchSpace.workspace)
            // Now a normal conversation, which reset must delete.
            ask { store.send("Say OK.") }
        case 4:
            check(sessionFiles().subtracting(before.sessions).count == 1, "second conversation has a session")
            store.reset()
            check(sessionFiles() == before.sessions && conversationFolders() == before.folders,
                  "reset deleted the conversation's folder and session")
            settings.setModel(savedModel, for: provider)
            exit(0)
        default: break
        }
    }
    ask { store.send("Remember the number 4817. Reply with just OK.") }
    dispatchMain()
} else if let index = arguments.firstIndex(of: "--selftest") {
    // QuickAsk --selftest [--model m] question...
    // Runs one request through the provider layer and prints the stream.
    var rest = Array(arguments[(index + 1)...])
    var model: String?
    if rest.first == "--model", rest.count > 1 {
        model = rest[1]
        rest.removeFirst(2)
    }
    let settings = Settings.shared
    let provider = ProviderRegistry.provider(id: settings.providerID)
    let executable = Executable.resolve(override: settings.executableOverride(for: provider),
                                        candidates: provider.executableCandidates)
    let request = AgentRequest(
        messages: [ChatMessage(role: .user, content: rest.joined(separator: " "))],
        model: model ?? settings.model(for: provider),
        instructions: Prompt.instructions(extra: settings.instructions),
        workingDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickAsk-selftest-\(UUID().uuidString)", isDirectory: true)
    )
    try? FileManager.default.createDirectory(at: request.workingDirectory, withIntermediateDirectories: true)
    let start = Date()
    var firstText: TimeInterval?
    let runner = AgentRunner()
    print("provider: \(provider.id), executable: \(executable), model: \(request.model ?? "-")")
    runner.run(provider: provider, executable: executable, request: request, onText: { piece in
        if firstText == nil { firstText = Date().timeIntervalSince(start) }
        FileHandle.standardOutput.write(Data(piece.utf8))
    }, onStatus: { status in
        FileHandle.standardOutput.write(Data("\n[\(status)]\n".utf8))
    }, completion: { outcome in
        let files = (try? FileManager.default.contentsOfDirectory(atPath: request.workingDirectory.path)) ?? []
        print("\n--- scratch files: \(files)")
        try? FileManager.default.removeItem(at: request.workingDirectory)  // no session was saved
        let total = Date().timeIntervalSince(start)
        switch outcome {
        case .success: print(String(format: "\n--- ok: first text %.2fs, total %.2fs", firstText ?? -1, total))
        case .failure(let message): print("\n--- failure: \(message)")
        case .cancelled: print("\n--- cancelled")
        }
        exit(0)
    })
    dispatchMain()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
