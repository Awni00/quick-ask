import AppKit
import Carbon.HIToolbox

/// A global hotkey via Carbon's RegisterEventHotKey, which needs no
/// Accessibility or Input Monitoring permission.
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var installed = false

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// `spec` looks like "option+space" or "ctrl+shift+k".
    init?(spec: String, handler: @escaping () -> Void) {
        guard let (keyCode, modifiers) = HotKey.parse(spec) else { return nil }
        HotKey.installHandlerOnce()
        id = HotKey.nextID
        HotKey.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x5141_534B), id: id)  // 'QASK'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
        HotKey.handlers[id] = handler
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.handlers[id] = nil
    }

    private static func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            HotKey.handlers[hotKeyID.id]?()
            return noErr
        }, 1, &eventType, nil, nil)
    }

    /// A spec ("ctrl+option+k") from a key press, for the settings window's
    /// recorder. Needs ⌘, ⌥ or ⌃ (⇧ alone isn't enough) and a supported key.
    static func spec(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
        guard let key = keyCodes.first(where: { $0.value == UInt32(keyCode) })?.key else { return nil }
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("option") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        guard parts.contains(where: { $0 != "shift" }) else { return nil }
        return (parts + [key]).joined(separator: "+")
    }

    /// "option+space" → "⌥Space", with modifiers in the standard ⌃⌥⇧⌘ order.
    static func displayLabel(_ spec: String) -> String {
        let parts = spec.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        let symbols: [(Set<String>, String)] = [
            (["ctrl", "control"], "⌃"), (["opt", "option", "alt"], "⌥"),
            (["shift"], "⇧"), (["cmd", "command"], "⌘"),
        ]
        var label = symbols.filter { names, _ in parts.contains { names.contains($0) } }.map(\.1).joined()
        let modifierNames = symbols.reduce(Set<String>()) { $0.union($1.0) }
        if let key = parts.last(where: { !modifierNames.contains($0) }) {
            let names = ["space": "Space", "return": "↩", "tab": "⇥", "escape": "⎋"]
            label += names[key] ?? key.uppercased()
        }
        return label
    }

    static func parse(_ spec: String) -> (UInt32, UInt32)? {
        var modifiers: UInt32 = 0
        var key: UInt32?
        for part in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            case "opt", "option", "alt": modifiers |= UInt32(optionKey)
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            case "shift": modifiers |= UInt32(shiftKey)
            default: key = keyCodes[part]
            }
        }
        guard let key, modifiers != 0 else { return nil }
        return (key, modifiers)
    }

    private static let keyCodes: [String: UInt32] = [
        "space": 49, "return": 36, "tab": 48, "escape": 53,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
        "`": 50, ",": 43, ".": 47, "/": 44, ";": 41, "'": 39,
    ]
}
