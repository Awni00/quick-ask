import AppKit

/// Where a provider can continue a conversation: links that open a new chat
/// with text filled in, in order of preference (e.g. desktop app, then web).
struct HandoffTarget {
    struct Link {
        let maxCharacters: Int
        let makeURL: (String) -> URL?
    }

    let appName: String  // "Open in <appName>"
    let links: [Link]

    /// The conversation as a URL for the first link that an installed app (or
    /// the browser) can open, sized to that link's limit.
    func resolve(_ messages: [ChatMessage]) -> (url: URL, text: Handoff.Text)? {
        for link in links {
            let text = Handoff.text(for: messages, assistantName: appName, limit: link.maxCharacters)
            if let url = link.makeURL(text.text), NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                return (url, text)
            }
        }
        return nil
    }

    /// Query string with `+`, `&`, `=` and `#` percent-encoded too, so the text
    /// survives URLSearchParams parsing unchanged.
    static func query(_ items: [(String, String)]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=#?")
        return items
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }
}

enum Handoff {
    struct Text {
        let text: String
        let truncated: Bool
        let full: String
    }

    /// The conversation as a message to paste into a new chat. When it is too
    /// long, the oldest turns are left out (the newest are kept).
    static func text(for messages: [ChatMessage], assistantName: String, limit: Int) -> Text {
        let header = "Continuing a conversation I started in a quick-question popup:"
        let turns = messages.map { m -> String in
            let who = m.role == .user ? "**Me:**" : "**\(assistantName):**"
            var quote = ""
            if let context = m.context {
                let from = context.source.map { " (from \($0))" } ?? ""
                quote = "\n> _Selected text\(from):_\n" + context.text
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> \($0)" }
                    .joined(separator: "\n") + "\n\n"
            }
            return "\(who)\(quote.isEmpty ? " " : quote)\(m.content)\(m.stopped ? " _(stopped)_" : "")"
        }
        let full = ([header] + turns).joined(separator: "\n\n") + "\n\n"
        if full.count <= limit { return Text(text: full, truncated: false, full: full) }

        let note = "_(Earlier messages left out for length.)_"
        var kept: [String] = []
        var size = header.count + note.count + 8
        for turn in turns.reversed() {
            if size + turn.count + 2 > limit { break }
            kept.insert(turn, at: 0)
            size += turn.count + 2
        }
        if kept.isEmpty, let last = turns.last {
            // A single very long turn: keep its end.
            kept = [String(last.suffix(max(0, limit - size)))]
        }
        let text = ([header, note] + kept).joined(separator: "\n\n") + "\n\n"
        return Text(text: text, truncated: true, full: full)
    }
}
