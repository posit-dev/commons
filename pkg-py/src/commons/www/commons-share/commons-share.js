// Sharing to Posit Connect. This script loads only in sessions that can
// share, so the buttons it adds to plots and tables never reach a shared copy.
(() => {
  const send = (input, value) => {
    if (!input || !window.Shiny?.setInputValue) return;
    window.Shiny.setInputValue(input, value, { priority: "event" });
  };

  const config = () => document.querySelector(".commons-share-config");

  const decorate = () => {
    if (!config()) return;
    for (const el of document.querySelectorAll("[data-commons-share]")) {
      if (el.querySelector(":scope > .commons-share-output")) continue;
      const noun = el.dataset.commonsShareKind === "table" ? "table" : "figure";
      const button = document.createElement("button");
      button.type = "button";
      button.className = "commons-share-output";
      button.setAttribute("aria-label", `Share this ${noun}`);
      // The icon comes from the toolbar's share button, so both match.
      const icon = config().querySelector("svg")?.outerHTML ?? "";
      button.innerHTML = `${icon}<span>Share</span>`;
      el.appendChild(button);
    }
  };

  // Chat messages stream in and re-render, so check again after each change.
  let queued = false;
  new MutationObserver(() => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => {
      queued = false;
      decorate();
    });
  }).observe(document.body, { childList: true, subtree: true });
  decorate();

  // An app on Connect runs in a frame that may not allow the clipboard API.
  const copyText = async (text, within) => {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch {
      const area = document.createElement("textarea");
      area.value = text;
      area.setAttribute("readonly", "");
      area.style.position = "fixed";
      area.style.opacity = "0";
      within.appendChild(area);
      area.select();
      const ok = document.execCommand("copy");
      area.remove();
      return ok;
    }
  };

  document.addEventListener("click", async (event) => {
    const output = event.target.closest(".commons-share-output");
    if (output) {
      event.preventDefault();
      event.stopPropagation();
      const host = output.closest("[data-commons-share]");
      send(config()?.dataset.outputInput, {
        id: host.dataset.commonsShare,
        nonce: Date.now(),
      });
      return;
    }

    const person = event.target.closest(".commons-share-pick, .commons-share-remove");
    if (person) {
      send(person.dataset.input, { guid: person.dataset.guid, nonce: Date.now() });
      return;
    }

    const update = event.target.closest(".commons-share-update");
    if (update) {
      update.disabled = true;
      send(update.dataset.input, Date.now());
      return;
    }

    const copy = event.target.closest(".commons-share-copy");
    if (copy && !copy.disabled && copy.dataset.url) {
      const label = copy.lastChild;
      const ok = await copyText(copy.dataset.url, copy.closest(".modal") ?? document.body);
      if (!ok) {
        window.prompt("Copy this link:", copy.dataset.url);
      } else if (label?.nodeType === Node.TEXT_NODE) {
        label.textContent = "Link copied";
        setTimeout(() => (label.textContent = "Copy link"), 2000);
      }
      send(copy.dataset.input, Date.now());
    }
  });
})();
