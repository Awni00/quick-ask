# Quick Ask

A macOS menu-bar app: press ⌥Space, ask a quick question, and read the answer in a
floating popup. Answers come from an agent CLI (currently Claude Code, on your
subscription). Each conversation is a CLI session working in a shared folder,
`~/Library/Application Support/Quick Ask/Quick Ask`, with its own notes subfolder.
Both are kept only while the conversation lasts (by default 10 minutes after
closing, or until ⌘N), then deleted, unless you continued it in the desktop app
with ⌘O.

## Build and install

```bash
./build.sh --install
```

This builds `build/Quick Ask.app`, signs it ad hoc, copies it to `~/Applications`
and starts it. Requires the Xcode command line tools and a logged-in `claude` CLI.

The installed app opens at login (toggle "Open at Login" in the ✦ menu-bar menu;
it's listed in System Settings → General → Login Items).

## Keys

| Key | Action |
|---|---|
| ⌥Space | Show or hide |
| ↵ / ⇧↵ | Send / new line |
| ⌘C (nothing selected) | Copy the last answer |
| ⌘R | Retry the last question |
| ⌘. | Stop the answer |
| ⌘N | New chat |
| ⌘O | Continue this same session in the Claude desktop app's Code tab (`claude://resume`), under a "Quick Ask" project, titled with the first question |
| ⇧⌘O | Open as a new Claude chat with the conversation filled in (if it's too long, older turns are left out and the full text is copied) |
| ⌘1–⌘3 | Haiku / Sonnet / Opus |
| ⌘, | Settings |
| Esc | Hide |
| Hold ⌘ | Show the shortcuts that apply |

## Settings

Open Settings from the ✦ menu-bar menu or with ⌘, in the popup: hotkey, open at
login, how long to keep a conversation, default model, web search, the CLI's path
and sign-in status, extra instructions, and the Accessibility permission.
The values live in the `local.QuickAsk` defaults domain (keys in
`Sources/QuickAsk/Settings.swift`).

## Layout

- `Sources/QuickAsk/Agents/`: the provider layer. Everything specific to one CLI
  is in a provider (`ClaudeCodeProvider.swift`); add another CLI by writing a
  provider and registering it in `ProviderRegistry`.
- `Sources/QuickAsk/`: hotkey, panel, conversation state, settings.
- `Resources/Icon/`: app icon and menu-bar glyph. Edit the SVGs; `build.sh`
  regenerates `AppIcon.icns` and `MenuBarIcon.png` from them
  (`tools/render-icons.swift`, using macOS's own SVG renderer).
- `design/`: icon concepts explored along the way.
- `Resources/web/`: the chat UI (markdown-it, KaTeX, highlight.js bundled in
  `vendor/`, see `vendor/VERSIONS.txt`).

Test the provider layer without the UI:

```bash
.build/release/QuickAsk --selftest --model haiku "What is 2+2?"
```
