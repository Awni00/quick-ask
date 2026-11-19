import Foundation

/// A temporary folder per conversation: the CLI's working directory, where it
/// may keep notes and files (its file tools are confined to it). Deleted when
/// the conversation ends, and all of them at launch and quit.
enum ScratchSpace {
    static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("QuickAsk", isDirectory: true)
    }

    static func make() -> URL {
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func remove(_ dir: URL?) {
        guard let dir, dir.path.hasPrefix(root.path + "/") else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }
}
