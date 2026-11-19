import AppKit
import SwiftUI

/// Opens (and keeps) the settings window. The app has no Dock icon, so it
/// activates itself to bring the window to the front.
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "Quick Ask Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            self.window = window
        }
        guard let window else { return }
        if !window.isVisible { place(window) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// On the screen with the mouse pointer (where the popup appears), centred
    /// horizontally with its top in the upper part of the screen.
    private func place(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return window.center() }
        window.layoutIfNeeded()
        let visible = screen.visibleFrame
        let size = window.frame.size
        let top = visible.maxY - visible.height * 0.12
        let y = max(visible.minY, top - size.height)
        window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: y))
    }
}

/// One page, three groups: General, Assistant, Permissions. Values are stored
/// with @AppStorage under the same keys `Settings` reads, so changes apply to
/// the next question; the hotkey and default model notify the app directly.
struct SettingsView: View {
    @AppStorage("hotkey") private var hotkey = "option+space"
    @AppStorage("reopenMinutes") private var reopenMinutes = 10.0
    @AppStorage("webSearch") private var webSearch = true
    @AppStorage("instructions") private var instructions = ""
    @AppStorage("launchAtLogin") private var launchAtLogin = true
    @AppStorage("provider") private var providerID = "claude"

    @State private var accessibilityAllowed = SelectionCapture.isTrusted
    @State private var cliStatus = CLIStatusView.Model.loading
    @State private var loginNeedsApproval = LoginItem.needsApproval

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var provider: AgentProvider { ProviderRegistry.provider(id: providerID) }

    var body: some View {
        Form {
            Section("General") {
                LabeledContent("Hotkey") { HotkeyRecorder(spec: $hotkey) }
                Toggle(isOn: $launchAtLogin) {
                    Text("Open at login")
                    if !LoginItem.isInstalledCopy {
                        Text("Only for the copy installed in Applications")
                    } else if loginNeedsApproval {
                        Text("Approve Quick Ask in System Settings → General → Login Items")
                    }
                }
                .onChange(of: launchAtLogin) { _, on in LoginItem.set(on) }
                Picker(selection: $reopenMinutes) {
                    Text("Don't keep").tag(0.0)
                    Text("5 minutes").tag(5.0)
                    Text("10 minutes").tag(10.0)
                    Text("30 minutes").tag(30.0)
                    Text("Until ⌘N").tag(-1.0)
                } label: {
                    Text("Keep the conversation")
                    Text("After closing the popup")
                }
            }

            Section("Assistant") {
                Picker("Agent", selection: $providerID) {
                    ForEach(ProviderRegistry.all, id: \.id) { p in
                        Text(p.id == "claude" ? "Claude Code" : p.displayName).tag(p.id)
                    }
                }
                .disabled(ProviderRegistry.all.count < 2)
                LabeledContent("Default model") { ModelDial(provider: provider) }
                Toggle(isOn: $webSearch) {
                    Text("Web search")
                    Text("Search the web and read pages when a question needs it")
                }
                CLIStatusView(provider: provider, model: $cliStatus)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Extra instructions")
                    TextEditor(text: $instructions)
                        .font(.body)
                        .frame(minHeight: 60, maxHeight: 90)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                    Text("Added to the system prompt, e.g. “Prefer metric units.”")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Permissions") {
                LabeledContent {
                    if accessibilityAllowed {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Enable…") { SelectionCapture.requestPermission() }
                    }
                } label: {
                    Text("Accessibility")
                    Text("To ask about text selected in other apps")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(poll) { _ in
            accessibilityAllowed = SelectionCapture.isTrusted
            loginNeedsApproval = LoginItem.needsApproval
        }
    }
}

/// Click, then press the new shortcut; Esc cancels. Needs ⌘, ⌥ or ⌃.
struct HotkeyRecorder: View {
    @Binding var spec: String
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            if recording {
                Text("Press a shortcut, or Esc to cancel")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(recording ? "Recording…" : HotKey.displayLabel(spec)) {
                recording ? stop() : start()
            }
            .frame(minWidth: 90)
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        NotificationCenter.default.post(name: .quickAskSuspendHotkey, object: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // Esc
                stop()
            } else if let new = HotKey.spec(keyCode: event.keyCode, modifiers: event.modifierFlags) {
                spec = new
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        // Resuming re-registers the hotkey from the (possibly new) setting.
        NotificationCenter.default.post(name: .quickAskSuspendHotkey, object: false)
    }
}

/// The popup's speed dial: dots from fastest to most capable.
struct ModelDial: View {
    let provider: AgentProvider
    @State private var selected = ""
    @State private var hovered: String?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(provider.models, id: \.id) { m in
                Circle()
                    .strokeBorder(Color.primary.opacity(m.id == selected ? 0 : 0.5), lineWidth: 1.25)
                    .background(Circle().fill(m.id == selected ? Color.primary : .clear))
                    .frame(width: 9, height: 9)
                    .padding(3)
                    .contentShape(Rectangle())
                    .onTapGesture { choose(m.id) }
                    .onHover { hovered = $0 ? m.id : (hovered == m.id ? nil : hovered) }
                    .help("\(m.label)\(m.hint.isEmpty ? "" : " · \(m.hint)")")
            }
            Text(label).foregroundStyle(hovered != nil && hovered != selected ? .primary : .secondary)
                .frame(minWidth: 56, alignment: .leading)
        }
        .onAppear { selected = Settings.shared.model(for: provider) }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            selected = Settings.shared.model(for: provider)  // e.g. ⌘1–3 in the popup
        }
    }

    private var label: String {
        let id = hovered ?? selected
        return provider.models.first { $0.id == id }?.label ?? id
    }

    private func choose(_ id: String) {
        selected = id
        Settings.shared.setModel(id, for: provider)
        NotificationCenter.default.post(name: .quickAskModelChanged, object: nil)
    }
}

/// Where the CLI is, and whether it's signed in (and until when).
struct CLIStatusView: View {
    enum Model { case loading, loaded(path: String, found: Bool, status: SignInStatus?) }

    let provider: AgentProvider
    @Binding var model: Model

    var body: some View {
        LabeledContent {
            HStack {
                if Settings.shared.executableOverride(for: provider) != nil {
                    Button("Use default") {
                        Settings.shared.setExecutableOverride(nil, for: provider)
                        refresh()
                    }
                }
                Button("Change…") { choose() }
            }
        } label: {
            Text("\(provider.id == "claude" ? "Claude Code" : provider.displayName) CLI")
            summary
        }
        .task(id: provider.id) { refresh() }
    }

    @ViewBuilder private var summary: some View {
        switch model {
        case .loading:
            Text("Checking…")
        case let .loaded(path, found, status):
            let shortPath = (path as NSString).abbreviatingWithTildeInPath
            if !found {
                Text("Not found at \(shortPath)").foregroundStyle(.red)
            } else if let status, !status.signedIn {
                Text("\(shortPath) · not signed in: run “claude auth login” in Terminal").foregroundStyle(.orange)
            } else if let status, let expires = status.expires {
                let soon = expires.timeIntervalSinceNow < 10 * 24 * 3600
                Text("\(shortPath) · signed in · sign-in expires around \(expires.formatted(.dateTime.day().month()))"
                     + (soon ? ": renew with “claude auth login”" : ""))
                    .foregroundStyle(soon ? .orange : .secondary)
            } else {
                Text("\(shortPath)\(status?.signedIn == true ? " · signed in" : "")")
            }
        }
    }

    private func refresh() {
        let path = Executable.resolve(override: Settings.shared.executableOverride(for: provider),
                                      candidates: provider.executableCandidates)
        model = .loading
        let provider = self.provider
        DispatchQueue.global().async {
            let found = FileManager.default.isExecutableFile(atPath: path)
            let status = found ? provider.signInStatus(executable: path) : nil
            DispatchQueue.main.async { model = .loaded(path: path, found: found, status: status) }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose the \(provider.displayName) CLI"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin")
        if panel.runModal() == .OK, let url = panel.url {
            Settings.shared.setExecutableOverride(url.path, for: provider)
            refresh()
        }
    }
}
