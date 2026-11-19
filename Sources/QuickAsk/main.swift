import AppKit
import ServiceManagement

// Writing a prompt to a CLI that has already exited must not kill the app.
signal(SIGPIPE, SIG_IGN)

let arguments = CommandLine.arguments

if arguments.contains("--login-status") {
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
        workingDirectory: ScratchSpace.make()
    )
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
        ScratchSpace.remove(request.workingDirectory)
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
