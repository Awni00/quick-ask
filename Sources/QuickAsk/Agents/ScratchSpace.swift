import Foundation

/// A folder per conversation: the CLI's working directory, where it may keep
/// notes and files (its file tools are confined to it), and what its saved
/// session belongs to.
///
/// Folders live in ~/Library/Application Support/Quick Ask/Conversations/<id>.
/// They're deleted when their conversation ends, except conversations handed
/// off to the provider's app with ⌘O: those keep their folder (it becomes the
/// working folder of the session in that app). Leftovers are cleaned up at
/// launch and quit.
enum ScratchSpace {
    static var root: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Quick Ask/Conversations", isDirectory: true)
    }

    /// Before conversations could be handed off, folders were temporary.
    private static var legacyRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("QuickAsk", isDirectory: true)
    }

    static func make(id: String = UUID().uuidString.lowercased()) -> URL {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Deletes one conversation's folder and the provider's saved sessions for it.
    static func remove(_ dir: URL?, provider: AgentProvider) {
        guard let dir, dir.path.hasPrefix(root.path + "/") else { return }
        provider.removeSessions(workingDirectory: dir)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Deletes every conversation folder and saved session except the handed-off ones.
    static func removeAll(except keep: Set<String>, provider: AgentProvider) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where !keep.contains(name) {
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
        provider.removeSessions(under: root, except: keep)
        try? fm.removeItem(at: legacyRoot)
    }
}
