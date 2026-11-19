import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: PanelController!
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem!
    private var loginMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = Settings.shared
        let provider = ProviderRegistry.provider(id: settings.providerID)
        controller = PanelController(store: ConversationStore(provider: provider, settings: settings), settings: settings)

        installEditMenu()
        installStatusItem(hotkey: settings.hotkey)
        LoginItem.apply()

        hotKey = HotKey(spec: settings.hotkey) { [weak self] in self?.controller.toggleFromHotkey() }
        if hotKey == nil {
            NSLog("QuickAsk: couldn't register hotkey \"\(settings.hotkey)\"")
        }

        // For testing: `open -a "Quick Ask" --args --show` opens the panel on launch,
        // and `--ask "question"` also sends a question.
        let args = CommandLine.arguments
        if args.contains("--show") || args.contains("--ask") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.controller.show()
                if let i = args.firstIndex(of: "--ask"), i + 1 < args.count {
                    self?.controller.ask(args[i + 1])
                }
            }
        }
        // For testing: `--snapshot path` writes the web view's pixels after 10 s.
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.controller.snapshotWebView(to: args[i + 1])
            }
        }
    }

    /// Standard text-editing shortcuts (⌘C, ⌘V, ⌘A, ⌘Z) only work in the web
    /// view when the app has an Edit menu, even though it's never shown.
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
        NSApp.mainMenu = main
    }

    private func installStatusItem(hotkey: String) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarIcon()

        let menu = NSMenu()
        let ask = NSMenuItem(title: "Ask… (\(hotkey))", action: #selector(showPanel), keyEquivalent: "")
        ask.target = self
        menu.addItem(ask)
        let new = NSMenuItem(title: "New Chat", action: #selector(newChat), keyEquivalent: "")
        new.target = self
        menu.addItem(new)
        menu.addItem(.separator())
        loginMenuItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginMenuItem.target = self
        menu.addItem(loginMenuItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Quick Ask", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.delegate = self
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

    /// Shows the login item's real state each time the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if !LoginItem.isInstalledCopy {
            loginMenuItem.title = "Open at Login (install to Applications first)"
            loginMenuItem.state = .off
            loginMenuItem.isEnabled = false
        } else if LoginItem.needsApproval {
            loginMenuItem.title = "Open at Login (approve in System Settings)"
            loginMenuItem.state = .mixed
        } else {
            loginMenuItem.title = "Open at Login"
            loginMenuItem.state = LoginItem.isEnabled ? .on : .off
        }
    }

    @objc private func toggleLoginItem() {
        if LoginItem.needsApproval {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        LoginItem.set(!LoginItem.isEnabled)
    }

    @objc private func showPanel() { controller.show() }

    @objc private func newChat() {
        controller.newChat()
        controller.show()
    }
}
