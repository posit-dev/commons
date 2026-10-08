// The drawer view for document artifacts and the chip that reopens one.
//
// The server shows the drawer once with a <commons-artifact-view> and streams
// everything else as "commons-artifact" custom messages: the document arrives
// as HTML pieces, each replaced when its text grows or its code finishes
// running. State lives here rather than in the element, because the drawer
// can replace its content and the element must be able to redraw from scratch.
(() => {
  const assetRoot = new URL(".", document.currentScript.src);

  const views = new Map();
  const connected = new Set();

  const stateFor = (view) => {
    if (!views.has(view)) views.set(view, { current: null, artifacts: new Map() });
    return views.get(view);
  };

  const artifactFor = (state, id) => {
    if (!state.artifacts.has(id)) {
      state.artifacts.set(id, { id, pieces: [], status: "writing", error: null });
    }
    return state.artifacts.get(id);
  };

  const scanErrors = {
    malformed: "The document's opening tag was malformed, so it wasn't saved.",
    too_long: "The document was too long, so it wasn't saved.",
    unclosed: "The document was never finished, so it wasn't saved.",
  };

  const patch = (a, msg) => {
    for (const piece of msg.pieces || []) a.pieces[piece.index] = piece.html;
    a.pieces.length = msg.count;
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
        Object.assign(a, { pieces: [], status: "writing", error: null });
        break;
      case "version":
        state.current = a.id;
        Object.assign(a, { status: "running", error: null });
        break;
      case "pieces":
        patch(a, msg);
        break;
      case "status":
        Object.assign(a, { status: msg.status, error: msg.error || null });
        break;
      case "rejected":
        Object.assign(a, { status: "failed", error: msg.error });
        break;
      case "error":
        Object.assign(a, { status: "failed", error: scanErrors[msg.reason] });
        break;
      case "select":
        state.current = a.id;
        Object.assign(a, { pieces: [], status: msg.status, error: msg.error || null });
        patch(a, msg);
        break;
    }
  };

  const register = () => {
    // A shared copy is a static page with no Shiny.
    if (!window.Shiny?.addCustomMessageHandler) return;
    window.Shiny.addCustomMessageHandler("commons-artifact", (msg) => {
      apply(msg);
      for (const el of connected) {
        if (el.getAttribute("view") === msg.view) el.render();
      }
    });
  };
  if (window.Shiny?.addCustomMessageHandler) {
    register();
  } else {
    document.addEventListener("DOMContentLoaded", register);
  }

  const escape = (text) =>
    text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

  // The document is model-written HTML, so it lives in a sandboxed frame with
  // an opaque origin, and its policy lets only the frame's own script run and
  // nothing but the stylesheet load from the network. The frame patches the
  // pieces it is sent rather than reloading, so streaming text and finished
  // cells don't flicker.
  const nonce = crypto.randomUUID();
  const frameSource = `<!doctype html>
<html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-${nonce}'; style-src ${assetRoot.origin} 'unsafe-inline'; img-src data:">
<link rel="stylesheet" href="${new URL("commons-document.css", assetRoot)}">
</head><body><main id="doc"></main><script nonce="${nonce}">
const doc = document.getElementById("doc");
window.addEventListener("message", (event) => {
  if (event.source !== window.parent) return;
  const msg = event.data;
  const root = document.scrollingElement;
  const following = root.scrollHeight - root.scrollTop - root.clientHeight < 40;
  if (msg.reset) doc.replaceChildren();
  for (const piece of msg.pieces) {
    while (doc.children.length <= piece.index) doc.append(document.createElement("section"));
    doc.children[piece.index].innerHTML = piece.html;
  }
  while (doc.children.length > msg.count) doc.lastElementChild.remove();
  if (msg.follow && following) root.scrollTop = root.scrollHeight;
});
parent.postMessage("ready", "*");
</script></body></html>`;

  const statusText = { writing: "Writing…", running: "Running…" };

  class CommonsArtifactView extends HTMLElement {
    connectedCallback() {
      connected.add(this);
      this.render();
    }

    disconnectedCallback() {
      connected.delete(this);
    }

    frame() {
      const body = this.querySelector(".commons-artifact-body");
      let frame = body.querySelector("iframe");
      if (!frame) {
        frame = document.createElement("iframe");
        frame.setAttribute("sandbox", "allow-scripts");
        frame.className = "commons-artifact-frame";
        this.ready = false;
        this.shown = { id: null, pieces: [] };
        const onReady = (event) => {
          if (event.source !== frame.contentWindow || event.data !== "ready") return;
          window.removeEventListener("message", onReady);
          this.ready = true;
          this.render();
        };
        window.addEventListener("message", onReady);
        frame.srcdoc = frameSource;
        body.replaceChildren(frame);
      }
      return frame;
    }

    render() {
      const state = stateFor(this.getAttribute("view"));
      const a = state.current ? state.artifacts.get(state.current) : null;
      const status = this.querySelector(".commons-artifact-status");
      const notice = this.querySelector(".commons-artifact-notice");
      if (!status || !notice) return;

      this.toggleAttribute("empty", !a);
      if (!a) return;
      status.textContent = statusText[a.status] ?? "";
      notice.innerHTML = a.error ? `<p>${escape(a.error)}</p>` : "";

      const frame = this.frame();
      if (!this.ready) return;
      const reset = this.shown.id !== a.id;
      const old = reset ? [] : this.shown.pieces;
      const pieces = [];
      a.pieces.forEach((html, index) => {
        if (old[index] !== html) pieces.push({ index, html });
      });
      if (!reset && !pieces.length && old.length === a.pieces.length) return;
      frame.contentWindow.postMessage(
        { reset, pieces, count: a.pieces.length, follow: a.status === "writing" },
        "*"
      );
      this.shown = { id: a.id, pieces: [...a.pieces] };
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
        const shared = document.getElementById("commons-shared-documents");
        if (shared) {
          const path = JSON.parse(shared.textContent)[this.getAttribute("artifact")];
          if (path) window.open(path, "_blank", "noopener");
          return;
        }
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
