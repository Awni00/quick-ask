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

  const icon = (name) => `<svg><use href="#i-${name}"/></svg>`;
  const $ = (id) => document.getElementById(id);
  const app = $("app"), thread = $("thread"), threadInner = $("thread-inner");
  const composer = $("composer"), input = $("input");
  const sendButton = $("send"), models = $("models"), toast = $("toast");
  const hint = $("hint"), tools = $("tools"), legend = $("legend");
  const handoffButton = $("handoff"), newButton = $("new");
  const contextCard = $("context"), axHint = $("axhint");

  let state = {
    messages: [], pending: null, error: null, model: "", models: [],
    provider: "Claude", handoff: null, showCmdHint: false, maxHeight: 600,
    context: null, axHint: false,
  };
  let scheduled = false;

  const isLoading = () => state.pending !== null;
  const hasAnswer = () => state.messages.some((m) => m.role === "assistant");

  function render() {
    scheduled = false;
    const nearBottom = thread.scrollHeight - thread.scrollTop - thread.clientHeight < 40;

    // Thread
    const lastAnswer = isLoading() ? -1 : state.messages.map((m) => m.role).lastIndexOf("assistant");
    let html = "";
    state.messages.forEach((m, i) => {
      if (m.role === "user") {
        const quote = m.context
          ? `<div class="quote" title="${escapeHtml(contextLabel(m.context))}">${escapeHtml(m.context.text)}</div>`
          : "";
        html += `<div class="msg user"><div class="bubble">${quote}${escapeHtml(m.content)}</div></div>`;
        return;
      }
      const latest = i === lastAnswer;
      const acts =
        `<div class="acts">` +
        `<button class="icon" data-act="copy" data-i="${i}" aria-label="Copy answer" title="Copy${latest ? " (⌘C)" : ""}">${icon("copy")}</button>` +
        (latest ? `<button class="icon" data-act="retry" aria-label="Retry" title="Retry (⌘R)">${icon("retry")}</button>` : "") +
        `</div>`;
      html +=
        `<div class="msg assistant${latest ? " latest" : ""}">${renderMarkdown(m.content)}` +
        `${m.stopped ? '<div class="note">Stopped</div>' : ""}${acts}</div>`;
    });
    if (isLoading()) {
      // The answer so far, then what the agent is doing (a tool call) or dots.
      const dots = `<span class="dots"><span></span><span></span><span></span></span>`;
      const activity = state.status
        ? `<div class="status">${dots}${escapeHtml(state.status)}</div>`
        : state.pending ? "" : `<div class="status">${dots}</div>`;
      html += `<div class="msg assistant">${state.pending ? md.render(state.pending) : ""}${activity}</div>`;
    }
    if (state.error) html += `<div class="error">${escapeHtml(state.error)}</div>`;
    threadInner.innerHTML = html;

    // Composer
    const empty = state.messages.length === 0 && !isLoading() && !state.error;
    document.body.classList.toggle("empty", empty);
    renderContext();
    input.placeholder = state.context
      ? "Ask about the selection"
      : empty ? `Ask ${state.provider}` : "Ask a follow-up";
    updateSendButton();
    renderModels();

    const canHandOff = Boolean(state.handoff) && state.messages.length > 0;
    handoffButton.hidden = !canHandOff;
    if (state.handoff) handoffButton.title = `Open in ${state.handoff} (⌘O)`;
    newButton.hidden = empty;
    hint.hidden = !(state.showCmdHint && empty);
    renderLegend(canHandOff);

    if (nearBottom || isLoading()) thread.scrollTop = thread.scrollHeight;
    reportHeight();  // also when only the streaming flag changed
  }

  function contextLabel(c) {
    const where = c.source ? `Selected in ${c.source}` : "Selected text";
    const lines = `${c.lines} line${c.lines === 1 ? "" : "s"}`;
    return `${where} · ${lines}${c.truncated ? " (shortened)" : ""}`;
  }

  // The selection waiting to be attached, or (once) the note about Accessibility.
  function renderContext() {
    const c = state.context;
    contextCard.hidden = !c;
    if (c) {
      contextCard.innerHTML =
        `<div class="card-body"><div class="card-meta">${escapeHtml(contextLabel(c))}</div>` +
        `<div class="card-text">${escapeHtml(c.text)}</div></div>` +
        `<button class="icon" data-clear-context aria-label="Remove selection" title="Remove">${icon("x")}</button>`;
    }
    axHint.hidden = !(state.axHint && !c && state.messages.length === 0);
    if (state.hotkeyLabel) $("hotkey-label").textContent = state.hotkeyLabel;
  }

  // Send turns into stop while an answer streams; faded when there's nothing to send.
  function updateSendButton() {
    const loading = isLoading();
    sendButton.innerHTML = icon(loading ? "stop" : "send");
    sendButton.title = loading ? "Stop (⌘.)" : "Send (↵)";
    sendButton.setAttribute("aria-label", loading ? "Stop" : "Send");
    sendButton.classList.toggle("off", !loading && input.value.trim() === "");
  }

  // Speed dial: one dot per model, fastest to most capable; the active one is
  // filled and named. Hovering a dot previews its name.
  const modelLabel = (id) => state.models.find((m) => m.id === id)?.label ?? id;
  function renderModels() {
    const key = state.models.map((m) => m.id).join() + "|" + state.model;
    if (models.dataset.key === key) return;  // avoid re-rendering under the mouse
    models.dataset.key = key;
    const dots = state.models
      .map((m, i) => {
        const tip = `${m.label}${m.hint ? " · " + m.hint : ""} (⌘${i + 1})`;
        return `<button class="dial-dot${m.id === state.model ? " on" : ""}" data-model="${m.id}"` +
          ` title="${escapeHtml(tip)}" aria-label="${escapeHtml(m.label)}"><span></span></button>`;
      })
      .join("");
    models.innerHTML =
      `<span class="dial" role="group" aria-label="Model">${dots}</span>` +
      `<span class="dial-label">${escapeHtml(modelLabel(state.model))}</span>`;
  }

  function renderLegend(canHandOff) {
    const items = [];
    if (hasAnswer()) items.push(["C", "copy"], ["R", "retry"]);
    if (canHandOff) items.push(["O", state.handoff]);
    if (state.messages.length) items.push(["N", "new"]);
    if (state.models.length) items.push([`1–${state.models.length}`, "model"]);
    if (isLoading()) items.push([".", "stop"]);
    if (!state.messages.length) items.push([",", "settings"]);
    items.push(["esc", "close", true]);
    legend.innerHTML = items
      .map(([key, label, plain]) => `<span><kbd>${plain ? "" : "⌘"}${key}</kbd>${label}</span>`)
      .join("");
  }

  // The content's natural height: the composer plus the thread's messages
  // (measured inside the thread, so it doesn't depend on the panel's current size).
  function naturalHeight() {
    const threadShown = !document.body.classList.contains("empty");
    const style = getComputedStyle(thread);
    const padding = parseFloat(style.paddingTop) + parseFloat(style.paddingBottom);
    return composer.offsetHeight + (threadShown ? threadInner.offsetHeight + padding : 0);
  }

  const schedule = () => {
    if (!scheduled) {
      scheduled = true;
      requestAnimationFrame(render);
    }
  };

  // Report content height so the panel can grow or shrink to fit. `streaming`
  // lets Swift avoid shrinking mid-answer (re-rendering can briefly dip).
  let lastHeight = 0;
  let lastStreaming = false;
  function reportHeight() {
    const h = Math.min(Math.ceil(naturalHeight()), state.maxHeight);
    const streaming = isLoading();
    if (h !== lastHeight || streaming !== lastStreaming) {
      lastHeight = h;
      lastStreaming = streaming;
      post("height", { value: h, streaming });
    }
  }
  const observer = new ResizeObserver(reportHeight);
  observer.observe(threadInner);
  observer.observe(composer);

  function autosize() {
    input.style.height = "auto";
    input.style.height = Math.min(input.scrollHeight, 144) + "px";
  }
  input.addEventListener("input", () => {
    autosize();
    updateSendButton();
  });

  let toastTimer;
  function flash(text) {
    toast.textContent = text;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => (toast.textContent = ""), 1200);
  }

  function send() {
    const text = input.value.trim();
    if (!text || isLoading()) return;
    post("send", { text });
    input.value = "";
    autosize();
    updateSendButton();
  }

  function chooseModel(id) {
    const m = state.models.find((m) => m.id === id);
    if (!m) return;
    post("model", { id });
    input.focus();
  }

  const hasSelection = () =>
    (window.getSelection()?.toString() ?? "") !== "" ||
    (document.activeElement === input && input.selectionStart !== input.selectionEnd);

  // Holding ⌘ on its own for a moment shows the shortcut legend.
  let cmdTimer;
  const hideLegend = () => {
    clearTimeout(cmdTimer);
    document.body.classList.remove("cmd");
  };
  document.addEventListener("keydown", (e) => {
    if (e.key === "Meta") {
      clearTimeout(cmdTimer);
      cmdTimer = setTimeout(() => {
        document.body.classList.add("cmd");
        if (state.showCmdHint) {
          state.showCmdHint = false;
          post("cmdHintSeen");
          schedule();
        }
      }, 350);
    } else {
      hideLegend();
    }
  });
  document.addEventListener("keyup", (e) => {
    if (e.key === "Meta") hideLegend();
  });
  window.addEventListener("blur", hideLegend);

  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
      e.preventDefault();
      send();
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
    } else if (key === ",") {
      e.preventDefault();
      post("settings");
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
        chooseModel(m.id);
      }
    } else if (key === "c" && !hasSelection()) {
      e.preventDefault();
      if (hasAnswer()) {
        post("copyAnswer");
        flash("Copied answer");
      }
    }
  });

  sendButton.addEventListener("click", () => {
    if (isLoading()) post("stop");
    else send();
    input.focus();
  });

  models.addEventListener("click", (e) => {
    const dot = e.target.closest("[data-model]");
    if (dot) chooseModel(dot.dataset.model);
  });
  models.addEventListener("mouseover", (e) => {
    const dot = e.target.closest("[data-model]");
    const label = models.querySelector(".dial-label");
    if (!dot || !label) return;
    label.textContent = modelLabel(dot.dataset.model);
    label.classList.toggle("preview", dot.dataset.model !== state.model);
  });
  models.addEventListener("mouseleave", () => {
    const label = models.querySelector(".dial-label");
    if (!label) return;
    label.textContent = modelLabel(state.model);
    label.classList.remove("preview");
  });

  contextCard.addEventListener("click", (e) => {
    if (e.target.closest("[data-clear-context]")) {
      post("clearContext");
      input.focus();
    }
  });
  axHint.addEventListener("click", (e) => {
    const button = e.target.closest("[data-ax]");
    if (!button) return;
    post(button.dataset.ax === "open" ? "openAXSettings" : "dismissAXHint");
    input.focus();
  });

  handoffButton.addEventListener("click", () => post("handoff"));
  newButton.addEventListener("click", () => {
    post("newChat");
    input.focus();
  });

  thread.addEventListener("click", (e) => {
    const codeCopy = e.target.closest(".copy");
    if (codeCopy) {
      post("copy", { text: codeCopy.parentElement.querySelector("pre").innerText.replace(/\n$/, "") });
      codeCopy.textContent = "Copied";
      setTimeout(() => (codeCopy.textContent = "Copy"), 1200);
      return;
    }
    const act = e.target.closest("[data-act]");
    if (!act) return;
    if (act.dataset.act === "copy") {
      const m = state.messages[Number(act.dataset.i)];
      if (m) post("copy", { text: m.content });
      act.innerHTML = icon("check");
      act.classList.add("done");
      setTimeout(() => {
        act.innerHTML = icon("copy");
        act.classList.remove("done");
      }, 1200);
    } else if (act.dataset.act === "retry") {
      post("retry");
    }
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
      schedule();
    },
  };

  render();
  post("ready");
})();
