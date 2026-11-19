// Chat UI. State comes from Swift via QA.setState(); user actions go back
// via post(type, data). In a plain browser (for testing) posts are logged.
(() => {
  const post = (type, data = {}) => {
    const handler = window.webkit?.messageHandlers?.qa;
    if (handler) handler.postMessage({ type, ...data });
    else console.log("post", type, data);
  };

  const escapeHtml = (s) =>
    s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

  // Inline $...$ follows Pandoc's rule so prices like "$5 and $10" stay text:
  // no $ inside, no space just inside the delimiters, no digit right after.
  const dollarInline = window.texmath.rules.dollars.inline.find((r) => r.name === "math_inline");
  if (dollarInline) {
    dollarInline.rex = /\$((?:[^\s\\$])|(?:[^\s$][^$]*?[^\s\\$]))\$(?!\d)/gy;
  }

  // Markdown with math ($...$, $$...$$, \(...\), \[...\]) and highlighted code.
  const md = window.markdownit({
    html: false,
    linkify: true,
    highlight(code, lang) {
      try {
        if (lang && hljs.getLanguage(lang)) {
          return hljs.highlight(code, { language: lang, ignoreIllegals: true }).value;
        }
      } catch (_) {}
      return escapeHtml(code);
    },
  }).use(window.texmath, {
    engine: window.katex,
    delimiters: ["dollars", "brackets"],
    katexOptions: { throwOnError: false },
  });

  const fence = md.renderer.rules.fence;
  md.renderer.rules.fence = (...args) =>
    `<div class="code">${fence(...args)}<button class="copy" tabindex="-1">Copy</button></div>`;

  // Rendering finished messages is cached; only the streaming answer re-renders.
  const cache = new Map();
  const renderMarkdown = (text) => {
    if (!cache.has(text)) {
      if (cache.size > 200) cache.clear();
      cache.set(text, md.render(text));
    }
    return cache.get(text);
  };

  const $ = (id) => document.getElementById(id);
  const thread = $("thread"), input = $("input"), modelChip = $("model"), toast = $("toast");
  const composer = $("composer"), hints = $("hints"), app = $("app");

  let state = {
    messages: [], pending: null, error: null, model: "", models: [],
    provider: "Claude", handoff: null, maxHeight: 600,
  };
  let scheduled = false;

  function render() {
    scheduled = false;
    const nearBottom = thread.scrollHeight - thread.scrollTop - thread.clientHeight < 40;

    let html = "";
    for (const m of state.messages) {
      if (m.role === "user") {
        html += `<div class="msg user"><div class="bubble">${escapeHtml(m.content)}</div></div>`;
      } else {
        html += `<div class="msg assistant">${renderMarkdown(m.content)}${m.stopped ? '<div class="note">Stopped</div>' : ""}</div>`;
      }
    }
    if (state.pending !== null) {
      html += state.pending
        ? `<div class="msg assistant">${md.render(state.pending)}</div>`
        : `<div class="msg assistant thinking"><span></span><span></span><span></span></div>`;
    }
    if (state.error) html += `<div class="error">${escapeHtml(state.error)}</div>`;
    thread.innerHTML = html;

    const empty = state.messages.length === 0 && state.pending === null && !state.error;
    document.body.classList.toggle("empty", empty);
    input.placeholder = empty ? `Ask ${state.provider}` : "Ask a follow-up";
    const canHandOff = Boolean(state.handoff) && state.messages.length > 0;
    $("handoff-hint").hidden = !canHandOff;
    if (state.handoff) $("handoff-label").textContent = `open in ${state.handoff}`;
    const current = state.models.find((m) => m.id === state.model);
    modelChip.textContent = current ? current.label : state.model;

    fitThread();
    if (nearBottom || state.pending !== null) thread.scrollTop = thread.scrollHeight;
  }

  // The thread scrolls once the panel reaches its maximum height.
  function fitThread() {
    const chrome = composer.offsetHeight + (hints.offsetParent ? hints.offsetHeight : 0);
    thread.style.maxHeight = Math.max(80, state.maxHeight - chrome) + "px";
  }

  const schedule = () => {
    if (!scheduled) {
      scheduled = true;
      requestAnimationFrame(render);
    }
  };

  // Report content height so the panel can grow or shrink to fit.
  let lastHeight = 0;
  new ResizeObserver(() => {
    const h = Math.ceil(app.getBoundingClientRect().height);
    if (h !== lastHeight) {
      lastHeight = h;
      post("height", { value: h });
    }
  }).observe(app);

  function autosize() {
    input.style.height = "auto";
    input.style.height = Math.min(input.scrollHeight, 144) + "px";
  }
  input.addEventListener("input", autosize);

  let toastTimer;
  function flash(text) {
    toast.textContent = text;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => (toast.textContent = ""), 1200);
  }

  const hasSelection = () =>
    (window.getSelection()?.toString() ?? "") !== "" ||
    (document.activeElement === input && input.selectionStart !== input.selectionEnd);

  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
      e.preventDefault();
      const text = input.value.trim();
      if (text && state.pending === null) {
        post("send", { text });
        input.value = "";
        autosize();
      }
    }
  });

  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") {
      e.preventDefault();
      post("close");
      return;
    }
    if (!e.metaKey || e.ctrlKey || e.altKey) return;
    const key = e.key.toLowerCase();
    if (key === "n") {
      e.preventDefault();
      post("newChat");
    } else if (key === "o") {
      e.preventDefault();
      if (state.handoff && state.messages.length > 0) post("handoff");
    } else if (key === "r") {
      e.preventDefault();
      post("retry");
    } else if (key === ".") {
      e.preventDefault();
      post("stop");
    } else if (/^[1-9]$/.test(key)) {
      const m = state.models[Number(key) - 1];
      if (m) {
        e.preventDefault();
        post("model", { id: m.id });
        flash(m.label);
      }
    } else if (key === "c" && !hasSelection()) {
      e.preventDefault();
      if (state.messages.some((m) => m.role === "assistant")) {
        post("copyAnswer");
        flash("Copied answer");
      }
    }
  });

  modelChip.addEventListener("click", () => {
    const i = state.models.findIndex((m) => m.id === state.model);
    const next = state.models[(i + 1) % state.models.length];
    if (next) post("model", { id: next.id });
    input.focus();
  });

  thread.addEventListener("click", (e) => {
    const button = e.target.closest(".copy");
    if (!button) return;
    post("copy", { text: button.parentElement.querySelector("pre").innerText.replace(/\n$/, "") });
    button.textContent = "Copied";
    setTimeout(() => (button.textContent = "Copy"), 1200);
  });

  window.QA = {
    setState(next) {
      state = { ...state, ...next };
      schedule();
    },
    focus() {
      input.focus();
    },
    clearInput() {
      input.value = "";
      autosize();
    },
  };

  render();
  post("ready");
})();
