import Foundation

/// Where conversations live on disk.
///
/// All conversations share one working directory, ~/Library/Application
/// Support/QuickAsk/QuickAsk, so sessions handed off to the desktop app are
/// grouped under one "QuickAsk" project there (the app names projects after
/// the working folder). Each conversation keeps its notes in its own subfolder,
/// <workspace>/<conversation id>.
///
/// A conversation's subfolder and CLI session are deleted when it ends, except
/// conversations handed off with ⌘O. Leftovers are cleaned up at launch and quit.
enum ScratchSpace {
    static var base: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("QuickAsk", isDirectory: true)
    }

    /// The shared working directory (its name is the desktop app's project name).
    static var workspace: URL { base.appendingPathComponent("QuickAsk", isDirectory: true) }

    /// Earlier layouts: one working directory per conversation, and before
    /// that, temporary folders.
    private static var legacyRoot: URL { base.appendingPathComponent("Conversations", isDirectory: true) }
    private static var legacyTempRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("QuickAsk", isDirectory: true)
    }

    /// Creates a conversation's notes subfolder (and the workspace).
    static func makeConversation(id: String = UUID().uuidString.lowercased()) -> URL {
        let dir = workspace.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Deletes one conversation's notes subfolder.
    static func removeConversation(_ dir: URL?) {
        guard let dir, dir.deletingLastPathComponent().standardizedFileURL == workspace.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Deletes every conversation subfolder and CLI session except the
    /// handed-off ones, plus leftovers from earlier layouts.
    static func cleanUp(keepingConversations keepFolders: Set<String>, sessions keepSessions: Set<String>,
                        provider: AgentProvider) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: workspace.path)) ?? [] where !keepFolders.contains(name) {
            try? fm.removeItem(at: workspace.appendingPathComponent(name))
        }
        provider.removeSessions(workingDirectory: workspace, except: keepSessions)

        for name in (try? fm.contentsOfDirectory(atPath: legacyRoot.path)) ?? [] where !keepFolders.contains(name) {
            try? fm.removeItem(at: legacyRoot.appendingPathComponent(name))
        }
        provider.removeSessions(under: legacyRoot, except: keepFolders)
        try? fm.removeItem(at: legacyTempRoot)
    }
}
