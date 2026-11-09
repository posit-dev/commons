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
  const chips = new Set();

  const stateFor = (view) => {
    if (!views.has(view)) views.set(view, { current: null, artifacts: new Map() });
    return views.get(view);
  };

  const artifactFor = (state, id) => {
    if (!state.artifacts.has(id)) {
      state.artifacts.set(id, { id, pieces: [], status: "writing", error: null, thumbnail: null });
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
        Object.assign(a, {
          pieces: [],
          status: msg.status,
          error: msg.error || null,
          thumbnail: msg.thumbnail || null,
        });
        patch(a, msg);
        break;
      case "thumbnail":
        a.thumbnail = msg.src || null;
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
      for (const chip of chips) {
        if (chip.getAttribute("view") === msg.view) chip.render();
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
  //
  // The sandbox still lets the frame navigate itself, so the frame opens links
  // through the parent, drops the elements that navigate on their own, and
  // takes the document over a port that dies with it if it navigates anyway.
  const nonce = crypto.randomUUID();
  const frameSource = `<!doctype html>
<html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-${nonce}'; style-src ${assetRoot.origin} 'unsafe-inline'; img-src data:; form-action 'none'; base-uri 'none'">
<link rel="stylesheet" href="${new URL("commons-document.css", assetRoot)}">
</head><body><main id="doc"></main><script nonce="${nonce}">
const doc = document.getElementById("doc");
let port = null;
const show = (msg) => {
  const root = document.scrollingElement;
  const following = root.scrollHeight - root.scrollTop - root.clientHeight < 40;
  if (msg.reset) doc.replaceChildren();
  for (const piece of msg.pieces) {
    while (doc.children.length <= piece.index) doc.append(document.createElement("section"));
    // Parsed inert first: a <meta> refresh acts as soon as it's inserted.
    const template = document.createElement("template");
    template.innerHTML = piece.html;
    template.content.querySelectorAll("meta, base").forEach((node) => node.remove());
    doc.children[piece.index].replaceChildren(template.content);
  }
  while (doc.children.length > msg.count) doc.lastElementChild.remove();
  if (msg.follow && following) root.scrollTop = root.scrollHeight;
};
window.addEventListener("message", (event) => {
  if (port || event.source !== window.parent || !event.ports[0]) return;
  port = event.ports[0];
  port.onmessage = (event) => show(event.data);
});
document.addEventListener("click", (event) => {
  const link = event.target.closest("a[href]");
  if (!link) return;
  event.preventDefault();
  const href = link.getAttribute("href");
  // A fragment resolves against the chat page's URL, which would load it here.
  if (href.startsWith("#")) {
    document.getElementById(decodeURIComponent(href.slice(1)))?.scrollIntoView();
  } else if (port) {
    port.postMessage({ open: link.href });
  }
});
parent.postMessage("ready", "*");
</script></body></html>`;

  const openLink = (url) => {
    if (typeof url === "string" && /^https?:\/\//i.test(url)) {
      window.open(url, "_blank", "noopener,noreferrer");
    }
  };

  const statusText = { writing: "Writing…", running: "Running…" };

  class CommonsArtifactView extends HTMLElement {
    connectedCallback() {
      connected.add(this);
      const share = this.querySelector(".commons-artifact-share");
      if (share && !share.dataset.bound) {
        share.dataset.bound = "true";
        share.addEventListener("click", () => {
          const state = stateFor(this.getAttribute("view"));
          if (!state.current || !window.Shiny?.setInputValue) return;
          window.Shiny.setInputValue(
            this.getAttribute("share-input"),
            { artifact: state.current, nonce: Date.now() },
            { priority: "event" }
          );
        });
      }
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
        this.port?.close();
        this.shown = { id: null, pieces: [] };
        const onReady = (event) => {
          if (event.source !== frame.contentWindow || event.data !== "ready") return;
          window.removeEventListener("message", onReady);
          const channel = new MessageChannel();
          channel.port1.onmessage = (event) => openLink(event.data?.open);
          frame.contentWindow.postMessage("port", "*", [channel.port2]);
          this.port = channel.port1;
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
      const share = this.querySelector(".commons-artifact-share");
      // The share config renders only for viewers who can share.
      if (share) {
        share.hidden =
          a.status !== "ready" || !document.querySelector(".commons-share-config");
      }
      notice.innerHTML = a.error ? `<p>${escape(a.error)}</p>` : "";

      const frame = this.frame();
      frame.title = a.title || "Document";
      if (!this.ready) return;
      const reset = this.shown.id !== a.id;
      const old = reset ? [] : this.shown.pieces;
      const pieces = [];
      a.pieces.forEach((html, index) => {
        if (old[index] !== html) pieces.push({ index, html });
      });
      if (!reset && !pieces.length && old.length === a.pieces.length) return;
      this.port.postMessage({
        reset,
        pieces,
        count: a.pieces.length,
        follow: a.status === "writing",
      });
      this.shown = { id: a.id, pieces: [...a.pieces] };
    }
  }

  // --- the chat chip ----------------------------------------------------------

  // shinychat renders the chip from Markdown with React, which owns its light
  // DOM, so the button lives in a shadow root around the slotted title.
  const chipStyle = `
    button {
      display: flex; align-items: center; gap: 0.85rem;
      width: min(100%, 27rem); margin: 0.5rem 0;
      padding: 0.45rem 1rem 0.45rem 0.45rem;
      font: inherit; color: inherit; text-align: left; cursor: pointer;
      border: 1px solid color-mix(in srgb, currentColor 6%, transparent);
      border-radius: 12px;
      background: var(--bs-body-bg, #fff);
      box-shadow: 0 1px 2px rgb(0 0 0 / 0.06), 0 2px 8px rgb(0 0 0 / 0.06);
      transition: box-shadow 140ms, transform 140ms;
    }
    button:hover {
      box-shadow: 0 2px 4px rgb(0 0 0 / 0.08), 0 6px 16px rgb(0 0 0 / 0.08);
      transform: translateY(-1px);
    }
    .shot {
      flex: none; width: 4.5rem; height: 3rem; border-radius: 8px; overflow: hidden;
      display: grid; place-items: center;
      background: color-mix(in srgb, currentColor 6%, transparent);
    }
    .shot img { width: 100%; height: 100%; object-fit: cover; object-position: 50% 40%; }
    .shot svg { width: 1.3rem; height: 1.3rem; opacity: 0.55; }
    .title {
      min-width: 0; font-weight: 550;
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
    }`;

  const chartIcon = `
    <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"
      stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
      <path d="M2 2v12h12"/><path d="M4.5 10.5 7.5 7l2 2 4-5"/>
    </svg>`;

  // The server only sends embedded PNGs; checking again keeps the chat page
  // from ever loading a URL out of a document.
  const isThumbnail = (src) => typeof src === "string" && src.startsWith("data:image/png;base64,");

  class CommonsArtifactLink extends HTMLElement {
    connectedCallback() {
      chips.add(this);
      if (!this.shadowRoot) {
        const root = this.attachShadow({ mode: "open" });
        root.innerHTML = `<style>${chipStyle}</style><button type="button" part="button"><span class="shot"></span><span class="title"><slot></slot></span></button>`;
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
      this.render();
    }

    disconnectedCallback() {
      chips.delete(this);
    }

    render() {
      const shot = this.shadowRoot?.querySelector(".shot");
      if (!shot) return;
      const a = stateFor(this.getAttribute("view")).artifacts.get(this.getAttribute("artifact"));
      const src = isThumbnail(a?.thumbnail) ? a.thumbnail : null;
      if (shot.dataset.src === (src ?? "")) return;
      shot.dataset.src = src ?? "";
      if (src) {
        const img = document.createElement("img");
        img.alt = "";
        img.src = src;
        shot.replaceChildren(img);
      } else {
        shot.innerHTML = chartIcon;
      }
    }
  }

  customElements.define("commons-artifact-view", CommonsArtifactView);
  customElements.define("commons-artifact-link", CommonsArtifactLink);
})();
