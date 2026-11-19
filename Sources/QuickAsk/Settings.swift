import Foundation

extension Notification.Name {
    /// The hotkey setting changed; re-register it.
    static let quickAskHotkeyChanged = Notification.Name("QuickAskHotkeyChanged")
    /// Pause (object: true) or resume (false) the global hotkey, while recording a new one.
    static let quickAskSuspendHotkey = Notification.Name("QuickAskSuspendHotkey")
    /// The default model changed in the settings window.
    static let quickAskModelChanged = Notification.Name("QuickAskModelChanged")
}

/// User settings, stored in the app's defaults domain (`local.QuickAsk`) and
/// edited in the settings window. Keys:
///   provider        agent CLI to use (default "claude")
///   hotkey          e.g. "option+space", "ctrl+shift+k"
///   reopenMinutes   keep the last chat if reopened within this many minutes
///                   (default 10; 0 = don't keep, -1 = until ⌘N)
///   webSearch       let the agent search the web and fetch pages (default true)
///   instructions    extra instructions added to the system prompt
///   launchAtLogin   open at login (default true)
///   model.<id>      model for provider <id> (the popup's ⌘1–⌘3 also set this)
///   executable.<id> full path to provider <id>'s CLI, if not found automatically
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    static let defaultValues: [String: Any] = [
        "provider": "claude",
        "hotkey": "option+space",
        "reopenMinutes": 10.0,
        "webSearch": true,
        "instructions": "",
        "launchAtLogin": true,
    ]

    private init() {
        defaults.register(defaults: Self.defaultValues)
    }

    /// Set once the user has held ⌘ to see the shortcuts; hides the hint.
    var cmdHintSeen: Bool {
        get { defaults.bool(forKey: "cmdHintSeen") }
        set { defaults.set(newValue, forKey: "cmdHintSeen") }
    }

    /// Set when the user closes the "allow Accessibility" note in the popup.
    var axHintDismissed: Bool {
        get { defaults.bool(forKey: "axHintDismissed") }
        set { defaults.set(newValue, forKey: "axHintDismissed") }
    }

    /// Open Quick Ask at login.
    var launchAtLogin: Bool {
        get { defaults.bool(forKey: "launchAtLogin") }
        set { defaults.set(newValue, forKey: "launchAtLogin") }
    }

    var providerID: String { defaults.string(forKey: "provider") ?? "claude" }
    var hotkey: String { defaults.string(forKey: "hotkey") ?? "option+space" }
    var reopenMinutes: Double { defaults.double(forKey: "reopenMinutes") }
    var webSearch: Bool { defaults.bool(forKey: "webSearch") }
    var instructions: String { defaults.string(forKey: "instructions") ?? "" }

    func model(for provider: AgentProvider) -> String {
        let saved = defaults.string(forKey: "model.\(provider.id)")
        return provider.models.contains { $0.id == saved } ? saved! : provider.defaultModel
    }

    func setModel(_ model: String, for provider: AgentProvider) {
        defaults.set(model, forKey: "model.\(provider.id)")
    }

    func executableOverride(for provider: AgentProvider) -> String? {
        defaults.string(forKey: "executable.\(provider.id)")
    }

    func setExecutableOverride(_ path: String?, for provider: AgentProvider) {
        defaults.set(path, forKey: "executable.\(provider.id)")
    }
}
