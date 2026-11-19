import Foundation

/// User settings, stored in the app's defaults domain. Until there is a settings
/// window, change them with `defaults write local.QuickAsk <key> <value>`:
///   provider        agent CLI to use (default "claude")
///   hotkey          e.g. "option+space", "ctrl+shift+k" (restart the app after changing)
///   reopenMinutes   keep the last chat if reopened within this many minutes (default 10)
///   instructions    extra instructions added to the system prompt
///   launchAtLogin   open at login (default true; also in the menu-bar menu)
///   model.<id>      model for provider <id> (the popup's ⌘1–⌘3 also set this)
///   executable.<id> full path to provider <id>'s CLI, if not found automatically
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            "provider": "claude",
            "hotkey": "option+space",
            "reopenMinutes": 10.0,
            "instructions": "",
            "launchAtLogin": true,
        ])
    }

    /// Open Quick Ask at login (toggle in the menu-bar menu).
    var launchAtLogin: Bool {
        get { defaults.bool(forKey: "launchAtLogin") }
        set { defaults.set(newValue, forKey: "launchAtLogin") }
    }

    var providerID: String { defaults.string(forKey: "provider") ?? "claude" }
    var hotkey: String { defaults.string(forKey: "hotkey") ?? "option+space" }
    var reopenMinutes: Double { defaults.double(forKey: "reopenMinutes") }
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
}
