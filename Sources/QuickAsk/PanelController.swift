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

    func show() {
        if let lastHidden, !store.isLoading,
           Date().timeIntervalSince(lastHidden) > settings.reopenMinutes * 60 {
            store.reset()
        }
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

    func ask(_ question: String) { store.send(question) }

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
            messages.append(["role": m.role.rawValue, "content": m.content, "stopped": m.stopped])
        }
        let state: [String: Any] = [
            "messages": messages,
            "pending": store.pending as Any? ?? NSNull(),
            "error": store.error as Any? ?? NSNull(),
            "model": store.model,
            "models": store.provider.models.map { ["id": $0.id, "label": $0.label] },
            "provider": store.provider.displayName,
            "handoff": store.provider.handoff?.appName as Any? ?? NSNull(),
            "maxHeight": maxHeight,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state),
              let json = String(data: data, encoding: .utf8) else { return }
        js("QA.setState(\(json))")
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
                contentHeight = CGFloat(value)
                if panel.isVisible { layout() }
            }
        case "send": store.send(body["text"] as? String ?? "")
        case "retry": store.retry()
        case "stop": store.stop()
        case "newChat": newChat()
        case "model": store.setModel(body["id"] as? String ?? "")
        case "copy": copy(body["text"] as? String)
        case "copyAnswer": copy(store.lastAnswer)
        case "close": hide()
        case "handoff": handOff()
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
