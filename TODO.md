# TODO

## Next

- [ ] **Continue the same session in the full app (⌘O).** Today ⌘O opens a *new*
  Claude chat with the transcript filled in. That's because:
  - Quick Ask runs `claude -p --no-session-persistence`, so there's no saved
    session to resume.
  - The `claude://claude.ai/new?q=…` link only fills in a new chat's message box;
    there's no known way to create a claude.ai chat with prior turns.

  Options to explore:
  - Save the session (drop `--no-session-persistence` for conversations that get
    handed off, or always, and delete the session file afterwards) and hand off to
    a Claude Code session: `claude --resume <id>` in a terminal, or a
    `claude://code/...` link in the desktop app, if one can open a specific session.
  - Check whether claude.ai or the desktop app gains a way to import a conversation.
- [ ] **Settings window** for the hotkey, model, reopen timeout and extra
  instructions (today: `defaults write local.QuickAsk …`, see `Settings.swift`).
- [ ] **Second provider (e.g. Codex).** Write a provider in `Sources/QuickAsk/Agents/`
  and register it in `ProviderRegistry`; add a way to choose the provider.

## Later / ideas

- [ ] Show a clear message when the CLI is logged out ("run `claude auth login`")
  instead of the CLI's raw error.
- [ ] Remember the panel position if it's dragged.
- [ ] Stable code signature (e.g. a local self-signed certificate) so rebuilds
  don't reset the Accessibility permission.
- [ ] Optional permission-free alternatives for selected text: a Services menu
  item, or a clipboard shortcut.

## Done

- [x] Redesign (layout A): send/stop button in the prompt row; toolbar with the
  model picker, open-in-Claude and new chat; copy/retry under answers; shortcuts
  shown while holding ⌘ (replaces the hint bar)
- [x] Selected text as context: on the hotkey, read the frontmost app's selection
  (Accessibility API, falling back to ⌘C with the clipboard restored); shown as
  a removable card and quoted in the message
- [x] Name: keep "Quick Ask"
- [x] Icon: "interlock", a white "?" whose stem is an amber ⚡ (quick + ask), plus a
  matching menu-bar glyph. Sources in `Resources/Icon/`; other concepts in
  `design/icon-concepts/`.
- [x] Native popup (Swift + web view) on ⌥Space, streaming answers, follow-ups
- [x] Markdown, KaTeX math, highlighted code with copy buttons
- [x] Copy answer, retry, stop, new chat, model switch (⌘1–3)
- [x] Keep the conversation for 10 minutes after closing; ⌘N for a new one
- [x] No Documents prompt: clean CLI environment, no user settings or plugins
- [x] Open at login
- [x] ⌘O: continue in the Claude app (new chat with the transcript)
