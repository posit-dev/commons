// The drawer view for document artifacts and the chip that reopens one.
//
// The server shows the drawer once with a <commons-artifact-view> and streams
// everything else as "commons-artifact" custom messages. State lives here
// rather than in the element, because the drawer can replace its content and
// the element must be able to redraw from scratch.
(() => {
  const views = new Map();
  const connected = new Set();

  const stateFor = (view) => {
    if (!views.has(view)) views.set(view, { current: null, artifacts: new Map() });
    return views.get(view);
  };

  const artifactFor = (state, id) => {
    if (!state.artifacts.has(id)) {
      state.artifacts.set(id, {
        id,
        title: id,
        source: "",
        version: 0,
        status: "streaming",
        html: null,
        htmlVersion: 0,
        error: null,
      });
    }
    return state.artifacts.get(id);
  };

  const scanErrors = {
    malformed: "The document's opening tag was malformed, so it wasn't saved.",
    too_long: "The document was too long, so it wasn't saved.",
    unclosed: "The document was never finished, so it wasn't saved.",
  };

  const apply = (msg) => {
    const state = stateFor(msg.view);
    if (msg.type === "reset") {
      state.current = null;
      state.artifacts.clear();
      return;
    }
    if (!msg.id) return;
    const a = artifactFor(state, msg.id);
    switch (msg.type) {
      case "open":
        state.current = a.id;
        Object.assign(a, { title: msg.title, source: "", status: "streaming", error: null });
        break;
      case "delta":
        a.source += msg.text;
        break;
      case "version":
        state.current = a.id;
        Object.assign(a, {
          title: msg.title,
          version: msg.version,
          source: msg.source,
          status: "rendering",
          error: null,
        });
        break;
      case "rendered":
        if (msg.version >= a.htmlVersion) {
          a.html = msg.html;
          a.htmlVersion = msg.version;
        }
        if (msg.version === a.version) a.status = "ready";
        break;
      case "failed":
        if (msg.version === a.version) Object.assign(a, { status: "failed", error: msg.error });
        break;
      case "rejected":
        Object.assign(a, { status: "rejected", error: msg.error });
        break;
      case "error":
        Object.assign(a, { status: "rejected", error: scanErrors[msg.reason] });
        break;
      case "select":
        state.current = a.id;
        Object.assign(a, {
          title: msg.title,
          version: msg.version,
          source: msg.source,
          html: msg.html,
          htmlVersion: msg.html_version,
          status: msg.status,
          error: msg.error,
        });
        break;
    }
  };

  const register = () => {
    window.Shiny.addCustomMessageHandler("commons-artifact", (msg) => {
      apply(msg);
      for (const el of connected) {
        if (el.getAttribute("view") === msg.view) el.scheduleRender();
      }
    });
  };
  if (window.Shiny?.addCustomMessageHandler) {
    register();
  } else {
    document.addEventListener("DOMContentLoaded", register);
  }

  // --- streaming preview ------------------------------------------------------

  // A preview of a document still being written: prose renders as Markdown
  // with any raw HTML escaped, and code cells become placeholders, since
  // they only run when the finished document renders.
  const escape = (text) =>
    text
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");

  const inline = (text) =>
    text
      .split(/(`[^`\n]*`)/)
      .map((part, i) => {
        if (i % 2) {
          const code = part.slice(1, -1);
          if (/^\{?(r|python)\}?\s/.test(code)) {
            return '<span class="commons-artifact-inline" title="Computed when the document renders">&hellip;</span>';
          }
          return `<code>${escape(code)}</code>`;
        }
        return escape(part)
          .replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
          .replace(/(^|[^*])\*([^*\s][^*]*)\*/g, "$1<em>$2</em>")
          .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1");
      })
      .join("");

  const listItem = /^\s*([-*+]|\d+[.)])\s+/;

  const renderMarkdown = (source) => {
    let text = source.replace(/\r\n/g, "\n").replace(/^\s+/, "");
    const out = [];
    if (text.startsWith("---")) {
      const closed = text.match(/^---[ \t]*\n([\s\S]*?)\n(?:---|\.\.\.)[ \t]*(?:\n|$)/);
      const front = closed ? closed[1] : text;
      const title = front.match(/^title:[ \t]*(.+)$/m);
      if (title) out.push(`<h1>${inline(title[1].replace(/^(["'])(.*)\1$/, "$2"))}</h1>`);
      text = closed ? text.slice(closed[0].length) : "";
    }

    const lines = text.split("\n");
    let paragraph = [];
    const flush = () => {
      if (paragraph.length) out.push(`<p>${inline(paragraph.join(" "))}</p>`);
      paragraph = [];
    };
    let i = 0;
    while (i < lines.length) {
      const line = lines[i];
      const fence = line.match(/^(`{3,}|~{3,})\s*(.*)$/);
      if (fence) {
        flush();
        const body = [];
        for (i++; i < lines.length && !lines[i].startsWith(fence[1]); i++) body.push(lines[i]);
        i++;
        out.push(
          fence[2].startsWith("{")
            ? '<div class="commons-artifact-cell">Code runs when the document renders</div>'
            : `<pre><code>${escape(body.join("\n"))}</code></pre>`
        );
        continue;
      }
      const heading = line.match(/^(#{1,6})\s+(.*)$/);
      if (heading) {
        flush();
        const n = heading[1].length;
        out.push(`<h${n}>${inline(heading[2].replace(/\s*\{[^}]*\}\s*$/, ""))}</h${n}>`);
        i++;
      } else if (listItem.test(line)) {
        flush();
        const tag = /^\s*\d/.test(line) ? "ol" : "ul";
        const items = [];
        for (; i < lines.length && listItem.test(lines[i]); i++) {
          items.push(`<li>${inline(lines[i].replace(listItem, ""))}</li>`);
        }
        out.push(`<${tag}>${items.join("")}</${tag}>`);
      } else if (/^>/.test(line)) {
        flush();
        const quoted = [];
        for (; i < lines.length && /^>/.test(lines[i]); i++) quoted.push(lines[i].replace(/^>\s?/, ""));
        out.push(`<blockquote>${inline(quoted.join(" "))}</blockquote>`);
      } else if (/^\|/.test(line)) {
        flush();
        const rows = [];
        for (; i < lines.length && /^\|/.test(lines[i]); i++) {
          if (/^\|[\s:|-]+$/.test(lines[i])) continue;
          const cells = lines[i].replace(/^\||\|\s*$/g, "").split("|");
          const tag = rows.length ? "td" : "th";
          rows.push(`<tr>${cells.map((c) => `<${tag}>${inline(c.trim())}</${tag}>`).join("")}</tr>`);
        }
        out.push(`<table>${rows.join("")}</table>`);
      } else if (/^:::/.test(line) || !line.trim()) {
        flush();
        i++;
      } else {
        paragraph.push(line);
        i++;
      }
    }
    flush();
    return out.join("\n");
  };

  // --- the drawer view --------------------------------------------------------

  const statusText = {
    streaming: "Writing…",
    rendering: "Rendering…",
    ready: "",
    failed: "This version didn't render",
    rejected: "Not saved",
  };

  class CommonsArtifactView extends HTMLElement {
    connectedCallback() {
      connected.add(this);
      this.render();
    }

    disconnectedCallback() {
      connected.delete(this);
    }

    scheduleRender() {
      if (this.pending) return;
      this.pending = true;
      requestAnimationFrame(() => {
        this.pending = false;
        this.render();
      });
    }

    render() {
      const state = stateFor(this.getAttribute("view"));
      const a = state.current ? state.artifacts.get(state.current) : null;
      const status = this.querySelector(".commons-artifact-status");
      const notice = this.querySelector(".commons-artifact-notice");
      const body = this.querySelector(".commons-artifact-body");
      if (!status || !body || !notice) return;

      this.toggleAttribute("empty", !a);
      if (!a) {
        status.replaceChildren();
        notice.replaceChildren();
        body.replaceChildren();
        return;
      }

      status.textContent = statusText[a.status];

      if (a.error) {
        const [summary, ...details] = a.error.split("\n");
        const shown = a.htmlVersion ? ` Showing version ${a.htmlVersion}.` : "";
        notice.innerHTML =
          `<p>${escape(summary)}${shown}</p>` +
          (details.length
            ? `<details><summary>Details</summary><pre>${escape(details.join("\n"))}</pre></details>`
            : "");
      } else {
        notice.replaceChildren();
      }

      if (a.html && a.status !== "streaming") {
        let frame = body.querySelector("iframe");
        if (!frame) {
          frame = document.createElement("iframe");
          frame.setAttribute("sandbox", "allow-scripts");
          frame.className = "commons-artifact-frame";
          body.replaceChildren(frame);
        }
        const key = `${a.id}:${a.htmlVersion}`;
        if (frame.dataset.key !== key) {
          frame.dataset.key = key;
          frame.title = a.title;
          frame.srcdoc = a.html;
        }
        return;
      }

      let preview = body.querySelector(".commons-artifact-preview");
      if (!preview) {
        preview = document.createElement("div");
        preview.className = "commons-artifact-preview";
        body.replaceChildren(preview);
      }
      const following = body.scrollHeight - body.scrollTop - body.clientHeight < 40;
      preview.innerHTML = renderMarkdown(a.source);
      if (a.status === "streaming" && following) body.scrollTop = body.scrollHeight;
    }
  }

  // --- the chat chip ----------------------------------------------------------

  // shinychat renders the chip from Markdown with React, which owns its light
  // DOM, so the button lives in a shadow root around the slotted label.
  const chipStyle = `
    button {
      display: inline-flex; align-items: center; gap: 0.4em;
      font: inherit; color: inherit; cursor: pointer;
      padding: 0.35em 0.75em; margin: 0.25em 0;
      border: 1px solid var(--bs-border-color, #dee2e6);
      border-radius: var(--bs-border-radius, 0.375rem);
      background: var(--bs-tertiary-bg, #f8f9fa);
    }
    button:hover { background: var(--bs-secondary-bg, #e9ecef); }
    svg { width: 1em; height: 1em; flex: none; }`;

  const documentIcon = `
    <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" aria-hidden="true">
      <path d="M4 1.5h5.5L13 5v9.5H4z"/><path d="M9.5 1.5V5H13M6 8h5M6 10.5h5"/>
    </svg>`;

  class CommonsArtifactLink extends HTMLElement {
    connectedCallback() {
      if (this.shadowRoot) return;
      const root = this.attachShadow({ mode: "open" });
      root.innerHTML = `<style>${chipStyle}</style><button type="button" part="button">${documentIcon}<slot></slot></button>`;
      root.querySelector("button").addEventListener("click", () => {
        const input = this.getAttribute("input");
        if (!input || !window.Shiny?.setInputValue) return;
        window.Shiny.setInputValue(
          input,
          { artifact: this.getAttribute("artifact"), nonce: Date.now() },
          { priority: "event" }
        );
      });
    }
  }

  customElements.define("commons-artifact-view", CommonsArtifactView);
  customElements.define("commons-artifact-link", CommonsArtifactLink);
})();
