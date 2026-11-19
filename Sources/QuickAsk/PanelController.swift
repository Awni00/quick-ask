import AppKit
import WebKit

/// Avoids the retain cycle WKUserContentController would create with the controller.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// A borderless floating panel that can take keyboard focus without
/// activating the app (like Spotlight).
final class PopupPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 56),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Shows the popup and connects the conversation to the web UI
/// (Resources/web). Swift → JS: `QA.setState(...)`, `QA.focus()`.
/// JS → Swift: messages posted to the `qa` handler.
final class PanelController: NSObject, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    private let panel = PopupPanel()
    private let webView: WKWebView
    private let store: ConversationStore
    private let settings: Settings

    private let width: CGFloat = 640
    private var contentHeight: CGFloat = 56
    private var lastHidden: Date?
    private var webReady = false
    /// Selected text waiting to be attached to the next question.
    private var pendingContext: AttachedContext?
    private var lastCapturedText: String?

    init(store: ConversationStore, settings: Settings) {
        self.store = store
        self.settings = settings
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        config.userContentController = contentController
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        contentController.add(WeakMessageHandler(self), name: "qa")
        // Transparent web view, so the blurred panel shows through.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.navigationDelegate = self

        // The blur ignores layer corner rounding when it samples what's behind
        // the window; a mask image is what actually rounds it.
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: 16)
        panel.contentView = background

        webView.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            webView.topAnchor.constraint(equalTo: background.topAnchor),
            webView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        panel.delegate = self
        store.onChange = { [weak self] in self?.pushState() }
        NotificationCenter.default.addObserver(forName: .quickAskModelChanged, object: nil, queue: .main) { [weak self] _ in
            self?.store.reloadModel()
        }
        NotificationCenter.default.addObserver(forName: .quickAskHotkeyChanged, object: nil, queue: .main) { [weak self] _ in
            self?.pushState()  // the hint shows the hotkey
        }
        loadPage()
    }

    /// A stretchable rounded-rectangle mask for NSVisualEffectView.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let size = NSSize(width: radius * 2 + 1, height: radius * 2 + 1)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// For testing: writes a PNG of the web view's own pixels (no blur behind),
    /// to check that its background is transparent.
    func snapshotWebView(to path: String) {
        webView.takeSnapshot(with: nil) { image, _ in
            guard let tiff = image?.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: Showing and hiding

    var isVisible: Bool { panel.isVisible }

    func toggle() { panel.isVisible ? hide() : show() }

    /// The hotkey: hides the popup, or reads the current selection in the
    /// frontmost app (before the popup takes focus) and shows the popup with it.
    func toggleFromHotkey() {
        if panel.isVisible { return hide() }
        SelectionCapture.capture { [weak self] selection in
            self?.show(selection: selection)
        }
    }

    /// `selection` is attached to the next question, unless it's the same text
    /// that was captured last time (so reopening doesn't re-attach it).
    func show(selection: AttachedContext? = nil) {
        // reopenMinutes: < 0 keeps the conversation until ⌘N; 0 never keeps it.
        let keep = settings.reopenMinutes
        if let lastHidden, !store.isLoading, keep >= 0,
           Date().timeIntervalSince(lastHidden) > keep * 60 {
            store.reset()
            pendingContext = nil
        }
        if let selection, selection.text != lastCapturedText {
            pendingContext = selection
        }
        if let selection { lastCapturedText = selection.text }
        layout()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(webView)
        pushState()
        js("QA.focus()")
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        lastHidden = Date()
    }

    func ask(_ question: String) { send(question) }

    private func send(_ text: String) {
        if store.send(text, context: pendingContext) {
            pendingContext = nil
            pushState()
        }
    }

    func newChat() {
        store.reset()
        js("QA.clearInput()")
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    // MARK: Layout: centred, top edge in the upper part of the screen, grows downward

    private var screen: NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private var maxHeight: CGFloat { (screen.visibleFrame.height * 0.7).rounded() }

    private func layout() {
        let visible = screen.visibleFrame
        let top = panel.isVisible ? panel.frame.maxY : visible.maxY - visible.height * 0.2
        let height = min(max(contentHeight, 48), maxHeight)
        let x = panel.isVisible ? panel.frame.minX : visible.midX - width / 2
        panel.setFrame(NSRect(x: x, y: top - height, width: width, height: height), display: true)
    }

    // MARK: Web view

    private func loadPage() {
        let dir: URL
        if let override = ProcessInfo.processInfo.environment["QUICKASK_WEB_DIR"] {
            dir = URL(fileURLWithPath: override)
        } else {
            dir = Bundle.main.resourceURL!.appendingPathComponent("web")
        }
        webReady = false
        webView.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
    }

    private func js(_ script: String) {
        guard webReady else { return }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func pushState() {
        var messages: [[String: Any]] = []
        for m in store.messages {
            var message: [String: Any] = ["role": m.role.rawValue, "content": m.content, "stopped": m.stopped]
            if let context = m.context { message["context"] = Self.preview(context) }
            messages.append(message)
        }
        let state: [String: Any] = [
            "messages": messages,
            "context": pendingContext.map(Self.preview) as Any? ?? NSNull(),
            "axHint": !SelectionCapture.isTrusted && !settings.axHintDismissed,
            "pending": store.pending as Any? ?? NSNull(),
            "status": store.status as Any? ?? NSNull(),
            "error": store.error as Any? ?? NSNull(),
            "model": store.model,
            "models": store.provider.models.map { ["id": $0.id, "label": $0.label, "hint": $0.hint] },
            "provider": store.provider.displayName,
            "handoff": store.provider.handoff?.appName as Any? ?? NSNull(),
            "showCmdHint": !settings.cmdHintSeen,
            "hotkeyLabel": HotKey.displayLabel(settings.hotkey),
            "maxHeight": maxHeight,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state),
              let json = String(data: data, encoding: .utf8) else { return }
        js("QA.setState(\(json))")
    }

    /// What the page needs to show a selection: the start of the text, where it
    /// came from and how long it is (the full text stays on the Swift side).
    private static func preview(_ context: AttachedContext) -> [String: Any] {
        [
            "text": String(context.text.prefix(400)),
            "source": context.source as Any? ?? NSNull(),
            "lines": context.text.split(separator: "\n", omittingEmptySubsequences: false).count,
            "truncated": context.truncated,
        ]
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            webReady = true
            pushState()
            if panel.isVisible { js("QA.focus()") }
        case "height":
            if let value = body["value"] as? Double {
                let height = CGFloat(value)
                // While an answer streams, only grow: re-rendering markdown and
                // math can briefly lower the height, which made the panel jump.
                // The exact height is applied when the answer is done.
                let streaming = body["streaming"] as? Bool ?? false
                contentHeight = streaming ? max(contentHeight, height) : height
                if panel.isVisible { layout() }
            }
        case "send": send(body["text"] as? String ?? "")
        case "clearContext":
            pendingContext = nil
            pushState()
        case "openAXSettings":
            hide()
            SelectionCapture.requestPermission()
        case "dismissAXHint":
            settings.axHintDismissed = true
            pushState()
        case "retry": store.retry()
        case "stop": store.stop()
        case "newChat": newChat()
        case "model": store.setModel(body["id"] as? String ?? "")
        case "copy": copy(body["text"] as? String)
        case "copyAnswer": copy(store.lastAnswer)
        case "close": hide()
        case "handoff": handOff()
        case "settings":
            hide()
            SettingsWindowController.shared.show()
        case "cmdHintSeen": settings.cmdHintSeen = true
        case "open":
            if let s = body["url"] as? String, let url = URL(string: s) { openExternally(url) }
        default: break
        }
    }

    /// Continues the conversation in the provider's app (⌘O). If it had to be
    /// shortened, the full conversation is also put on the clipboard.
    func handOff() {
        guard let target = store.provider.handoff, !store.messages.isEmpty else { return }
        guard let (url, text) = target.resolve(store.messages) else {
            NSSound.beep()
            return
        }
        if text.truncated { copy(text.full) }
        hide()
        NSWorkspace.shared.open(url)
    }

    private func copy(_ text: String?) {
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func openExternally(_ url: URL) {
        guard ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
        hide()
        NSWorkspace.shared.open(url)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        if action.navigationType == .linkActivated, let url {
            openExternally(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(url?.isFileURL == true ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadPage()
    }
}
