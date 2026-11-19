import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PanelController!
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem!
    private var askMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = Settings.shared
        let provider = ProviderRegistry.provider(id: settings.providerID)
        // Leftovers from a crash; handed-off conversations are kept.
        ScratchSpace.cleanUp(keepingConversations: settings.handedOffConversations,
                             sessions: settings.handedOffSessions, provider: provider)
        controller = PanelController(store: ConversationStore(provider: provider, settings: settings), settings: settings)

        installEditMenu()
        installStatusItem()
        LoginItem.apply()
        registerHotKey()

        let center = NotificationCenter.default
        center.addObserver(forName: .quickAskHotkeyChanged, object: nil, queue: .main) { [weak self] _ in
            self?.registerHotKey()
        }
        // While the settings window records a new hotkey, the current one must
        // not fire (it would toggle the popup instead of being recorded).
        center.addObserver(forName: .quickAskSuspendHotkey, object: nil, queue: .main) { [weak self] note in
            if note.object as? Bool == true { self?.hotKey = nil } else { self?.registerHotKey() }
        }

        // For testing: `open -a "Quick Ask" --args --show` opens the panel on launch,
        // `--ask "question"` also sends a question, and `--settings` opens settings.
        let args = CommandLine.arguments
        if args.contains("--show") || args.contains("--ask") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.controller.show()
                if let i = args.firstIndex(of: "--ask"), i + 1 < args.count {
                    self?.controller.ask(args[i + 1])
                }
            }
        }
        if args.contains("--settings") { SettingsWindowController.shared.show() }
        // For testing: `--ax-status path` writes whether macOS trusts this app for
        // Accessibility (only meaningful when launched via `open`, not a shell).
        if let i = args.firstIndex(of: "--ax-status"), i + 1 < args.count {
            try? "trusted=\(SelectionCapture.isTrusted)\n".write(toFile: args[i + 1], atomically: true, encoding: .utf8)
        }
        // For testing: `--snapshot path` writes the web view's pixels after 10 s.
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.controller.snapshotWebView(to: args[i + 1])
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let settings = Settings.shared
        ScratchSpace.cleanUp(keepingConversations: settings.handedOffConversations,
                             sessions: settings.handedOffSessions,
                             provider: ProviderRegistry.provider(id: settings.providerID))
    }

    private func registerHotKey() {
        let spec = Settings.shared.hotkey
        hotKey = nil  // unregister the old one first
        hotKey = HotKey(spec: spec) { [weak self] in self?.controller.toggleFromHotkey() }
        if hotKey == nil { NSLog("QuickAsk: couldn't register hotkey \"\(spec)\"") }
        askMenuItem?.title = "Ask… (\(HotKey.displayLabel(spec)))"
    }

    /// Standard text-editing shortcuts (⌘C, ⌘V, ⌘A, ⌘Z) only work in the web
    /// view and the settings window when the app has an Edit menu, even though
    /// it's never shown.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarIcon()

        let menu = NSMenu()
        askMenuItem = NSMenuItem(title: "Ask…", action: #selector(showPanel), keyEquivalent: "")
        askMenuItem.target = self
        menu.addItem(askMenuItem)
        let new = NSMenuItem(title: "New Chat", action: #selector(newChat), keyEquivalent: "")
        new.target = self
        menu.addItem(new)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Quick Ask", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    /// The "?"-with-a-bolt glyph as a template image, so macOS tints it for
    /// light and dark menu bars. Falls back to a system symbol.
    private static func menuBarIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            image.accessibilityDescription = "Quick Ask"
            return image
        }
        return NSImage(systemSymbolName: "questionmark", accessibilityDescription: "Quick Ask")
    }

    @objc private func showPanel() { controller.show() }

    @objc private func newChat() {
        controller.newChat()
        controller.show()
    }

    @objc private func openSettings() { SettingsWindowController.shared.show() }
}
