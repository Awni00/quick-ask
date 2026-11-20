// What the demo shows over time. render.swift loads stage.html (which loads
// this file), calls scenes[name].frame(t) for each frame, and applies the
// returned popup description to the real popup UI (Resources/web).
//
// Both answers were produced by Quick Ask's own CLI call
// (`QuickAsk --selftest --model …`) and are pasted here verbatim.

const KELLY_QUESTION = "Why the logarithm? Quick example?";
const KELLY_ANSWER = String.raw`**Why the logarithm:** Wealth compounds multiplicatively, so over many repeated bets your final wealth is a *product* of returns. Taking the log turns that product into a sum, so the long-run growth rate is the average of log-returns (law of large numbers). Maximizing $E[\log W]$ therefore maximizes the long-run compound growth rate and, asymptotically, beats any other strategy with probability 1. It also avoids ruin, since $\log 0 = -\infty$ means you never bet everything on a risky wager.

**Quick example:** A coin lands heads with $p = 0.6$ and pays even odds ($b = 1$, $q = 0.4$).

$$f^* = p - \frac{q}{b} = 0.6 - 0.4 = 0.2$$

So bet 20% of your bankroll each time.

Expected log growth per bet for fraction $f$:

$$g(f) = 0.6\ln(1+f) + 0.4\ln(1-f)$$

- $f = 0.2$: $g \approx 0.6(0.1823) + 0.4(-0.2231) \approx 0.0201$ (about 2% growth per bet)
- $f = 0.5$: $g \approx 0.6(0.4055) + 0.4(-0.6931) \approx -0.034$ (negative, so you go broke in the long run despite having an edge)
- $f = 1$: a single loss wipes you out.

Betting too much destroys wealth even with a positive edge. Kelly picks the peak of $g(f)$.`;

const CODE_QUESTION = "zsh one-liner to list the 10 largest files under ~/Downloads, with sizes";
const CODE_ANSWER = String.raw`~~~zsh
find ~/Downloads -type f -print0 | xargs -0 du -h | sort -rh | head -n 10
~~~

This shows disk usage (allocated blocks), which can differ slightly from logical file size. For exact byte counts:

~~~zsh
find ~/Downloads -type f -exec stat -f '%z\t%N' {} + | sort -rn | head -n 10
~~~`;

// The state the app pushes (PanelController.pushState), minus per-frame parts.
const BASE = {
  messages: [], pending: null, status: null, error: null, context: null, axHint: false,
  model: "sonnet",
  models: [
    { id: "haiku", label: "Haiku", hint: "fastest" },
    { id: "sonnet", label: "Sonnet", hint: "balanced" },
    { id: "opus", label: "Opus", hint: "most capable" },
  ],
  provider: "Claude", handoff: "Claude", sessionHandoff: null,
  showCmdHint: false, hotkeyLabel: "⌥Space", maxHeight: 557,
};

const clamp = (x) => Math.min(1, Math.max(0, x));
const ease = (x) => (x = clamp(x), x * x * (3 - 2 * x));
const lerp = (a, b, x) => a + (b - a) * x;
// Streams text up to a fraction of its length, cut at a word boundary.
const streamed = (text, x) => {
  const n = Math.floor(clamp(x) * text.length);
  if (n >= text.length) return text;
  const cut = text.lastIndexOf(" ", n);
  return text.slice(0, Math.max(cut, 0));
};

const SELECTION = { text: stage.sentence, source: "Preview", lines: 1, truncated: false };

window.scenes = {
  // Select a sentence, press ⌥Space, ask about it, read the streamed answer.
  demo: {
    duration: 14,
    dark: false,
    frame(t) {
      // Cursor: glide to the sentence, then drag across it.
      const start = stage.wordPoint(0.02, "start");
      const end = stage.wordPoint(1, "end");
      const selectX = clamp((t - 0.9) / 1.5);
      stage.select(t < 0.9 ? 0 : selectX);
      let p;
      if (t < 0.9) {
        const k = ease(t / 0.8);
        p = { x: lerp(1040, start.x, k), y: lerp(780, start.y, k) };
      } else {
        p = stage.wordPoint(Math.max(selectX, 0.02), selectX === 0 ? "start" : "end");
      }
      stage.cursor(p.x - 2, p.y - 4, t < 2.9);

      // The hotkey, shown as keycaps.
      stage.keys(t < 2.5 ? 0 : t < 2.6 ? (t - 2.5) / 0.1 : t < 3.6 ? 1 : clamp(1 - (t - 3.6) / 0.25));

      if (t < 2.85) return { visible: false };
      const opacity = clamp((t - 2.85) / 0.12);
      const sent = 5.0, firstText = 5.9, done = 10.6;
      if (t < sent) {
        const typed = KELLY_QUESTION.slice(0, Math.max(0, Math.floor((t - 3.25) / 0.045)));
        return { visible: true, opacity, input: typed, state: { ...BASE, context: SELECTION } };
      }
      const user = { role: "user", content: KELLY_QUESTION, stopped: false, context: SELECTION };
      if (t < done) {
        const pending = t < firstText ? "" : streamed(KELLY_ANSWER, (t - firstText) / (done - firstText));
        return { visible: true, opacity, input: "", state: { ...BASE, messages: [user], pending } };
      }
      return {
        visible: true, opacity, input: "",
        state: {
          ...BASE, sessionHandoff: "Claude Code",
          messages: [user, { role: "assistant", content: KELLY_ANSWER, stopped: false }],
        },
      };
    },
  },

  // Stills.
  code: {
    still: true,
    dark: true,
    frame() {
      stage.showWindow(false);
      stage.select(0);
      stage.cursor(0, 0, false);
      stage.keys(0);
      return {
        visible: true, opacity: 1, input: "",
        state: {
          ...BASE, model: "haiku", sessionHandoff: "Claude Code",
          messages: [
            { role: "user", content: CODE_QUESTION, stopped: false },
            { role: "assistant", content: CODE_ANSWER, stopped: false },
          ],
        },
      };
    },
  },
  answer: {
    still: true,
    dark: false,
    frame() {
      stage.select(1);
      stage.cursor(0, 0, false);
      stage.keys(0);
      return {
        visible: true, opacity: 1, input: "",
        state: {
          ...BASE, sessionHandoff: "Claude Code",
          messages: [
            { role: "user", content: KELLY_QUESTION, stopped: false, context: SELECTION },
            { role: "assistant", content: KELLY_ANSWER, stopped: false },
          ],
        },
      };
    },
  },
  empty: {
    still: true,
    dark: false,
    frame() {
      stage.showWindow(false);
      stage.select(0);
      stage.cursor(0, 0, false);
      stage.keys(0);
      return { visible: true, opacity: 1, input: "", state: { ...BASE, showCmdHint: true } };
    },
  },
};
