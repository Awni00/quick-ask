# TODO

## Next

- [ ] **Optional code execution** (Bash in the scratch folder), only with proper
  sandboxing (no access outside the folder); off by default.

- [ ] Optionally delete handed-off conversations (folder + session) after N days.
- [ ] **Second provider (e.g. Codex).** Write a provider in `Sources/QuickAsk/Agents/`
  and register it in `ProviderRegistry`; add a way to choose the provider.

## Later / ideas

- [ ] Thinner scrollbars in the popup (thread and prompt), e.g. a slim overlay
  thumb instead of the default thick one.
- [ ] Show a clear message when the CLI is logged out ("run `claude auth login`")
  instead of the CLI's raw error.
- [ ] Remember the panel position if it's dragged.
- [ ] Optional permission-free alternatives for selected text: a Services menu
  item, or a clipboard shortcut.

## Done

- [x] Redesign (layout A): send/stop button in the prompt row; toolbar with the
  model picker, open-in-Claude and new chat; copy/retry under answers; shortcuts
  shown while holding ⌘ (replaces the hint bar)
- [x] Selected text as context: on the hotkey, read the frontmost app's selection
  (Accessibility API, falling back to ⌘C with the clipboard restored); shown as
  a removable card and quoted in the message
- [x] Tools: web search, page fetching, and file tools confined to a
  per-conversation scratch folder (CLI restricted mode; no code execution);
  tool activity shown as a status line
- [x] Layout: no clipped toolbar on long chats; no resize jumps while streaming
- [x] Model selector: speed dial (dots from fastest to most capable, active one
  filled and named; hover previews, tooltips give a hint and the shortcut)
- [x] Settings window (⌘, or the menu-bar menu): hotkey recorder, open at login,
  keep-conversation duration, default model, web search, CLI path and sign-in
  status, extra instructions, Accessibility status
- [x] Accessibility nudge redesigned as a feature card ("Ask about selected text")
- [x] Permissions survive rebuilds: builds are signed with a fixed designated
  requirement (`identifier "local.QuickAsk"`); checked across two rebuilds with
  different code hashes
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
- [x] ⌘O continues the same session in the desktop app's Code tab
  (`claude://resume?session=<id>`); ⇧⌘O opens a new chat with the transcript.
  Conversations are CLI sessions (follow-ups resume them); deleted with the
  conversation unless handed off. Checked with `QuickAsk --session-test`.
- [x] Handed-off sessions are grouped under one "Quick Ask" project (shared
  working folder, per-conversation notes subfolders) and titled with the first
  question (`--name`)
