(() => {
  const selector = ".commons-provenance-info-trigger";

  // shinychat mounts aside HTML after Shiny's usual input-binding pass.
  const scopeWithTrigger = (node) => {
    if (node.matches?.(selector)) return node.parentNode;
    if (node.querySelector?.(selector)) return node;
    return null;
  };

  const start = () => {
    new MutationObserver((records) => {
      for (const record of records) {
        for (const node of record.removedNodes) {
          const scope = scopeWithTrigger(node);
          if (scope) window.Shiny.unbindAll(scope);
        }
        for (const node of record.addedNodes) {
          const scope = scopeWithTrigger(node);
          if (scope) void window.Shiny.bindAll(scope);
        }
      }
    }).observe(document.body, { childList: true, subtree: true });
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
  } else {
    start();
  }
})();
