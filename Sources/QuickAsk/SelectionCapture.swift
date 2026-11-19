import AppKit
import ApplicationServices

/// Text selected in another app, attached to the next question.
struct AttachedContext: Equatable {
    let text: String
    let source: String?  // app name, e.g. "Safari"
    let truncated: Bool
}

/// Reads the frontmost app's selected text when the hotkey is pressed (never
/// in the background). Needs the Accessibility permission.
///
/// 1. Ask the focused UI element for its selected text (Accessibility API).
///    If the element supports that, its answer is final, even if empty.
/// 2. Otherwise (common in browsers and Electron apps), send ⌘C, read the
///    clipboard, and put the previous clipboard contents back.
enum SelectionCapture {
    static let maxCharacters = 20_000

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt and opens the Accessibility settings page.
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Calls `completion` on the main queue with the selection, or nil.
    static func capture(completion: @escaping (AttachedContext?) -> Void) {
        guard isTrusted,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return completion(nil) }
        let source = app.localizedName

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let element = focused as! AXUIElement
            if stringAttribute(element, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) {
                return completion(nil)  // never read password fields
            }
            var selected: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success {
                // Supported: trust the answer, so an empty selection doesn't fall
                // through to ⌘C (some editors copy the whole line when nothing is selected).
                return completion((selected as? String).flatMap { make($0, source: source) })
            }
        }
        copyFallback(source: source, completion: completion)
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func make(_ raw: String, source: String?) -> AttachedContext? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.count > maxCharacters {
            return AttachedContext(text: String(text.prefix(maxCharacters)), source: source, truncated: true)
        }
        return AttachedContext(text: text, source: source, truncated: false)
    }

    // MARK: ⌘C fallback

    private typealias SavedItem = [(NSPasteboard.PasteboardType, Data)]

    private static func copyFallback(source: String?, completion: @escaping (AttachedContext?) -> Void) {
        let pasteboard = NSPasteboard.general
        let saved: [SavedItem] = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let before = pasteboard.changeCount

        // A private event source, with only ⌘ set, so modifiers still held from
        // the hotkey (⌥) don't turn this into a different shortcut.
        let eventSource = CGEventSource(stateID: .privateState)
        let keyC: CGKeyCode = 8
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: eventSource, virtualKey: keyC, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }

        let start = Date()
        func poll() {
            if pasteboard.changeCount != before {
                let text = pasteboard.string(forType: .string)
                restore(saved, to: pasteboard)
                completion(text.flatMap { make($0, source: source) })
            } else if Date().timeIntervalSince(start) > 0.3 {
                completion(nil)  // nothing was copied: no selection
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: poll)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: poll)
    }

    /// Puts the previous clipboard contents back, marked so clipboard managers
    /// (nspasteboard.org convention) don't record the round trip.
    private static func restore(_ items: [SavedItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        restored[0].setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.writeObjects(restored)
    }
}
