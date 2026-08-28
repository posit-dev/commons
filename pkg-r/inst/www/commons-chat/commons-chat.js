(() => {
  const triggerSelector = ".commons-provenance-info-trigger";
  const popoverSelector = ".commons-provenance-info-popover";

  const initialize = (root) => {
    const triggers = root.matches?.(triggerSelector)
      ? [root]
      : root.querySelectorAll?.(triggerSelector) ?? [];

    for (const trigger of triggers) {
      if (window.bootstrap.Popover.getInstance(trigger)) continue;

      const content = trigger.nextElementSibling;
      new window.bootstrap.Popover(trigger, {
        container: "body",
        content: () => content.firstElementChild.cloneNode(true),
        customClass: popoverSelector.slice(1),
        html: true,
        placement: "auto",
        title: trigger.getAttribute("aria-label"),
        trigger: "click"
      });
    }
  };

  const start = () => {
    initialize(document);

    const hideAll = () => {
      for (const trigger of document.querySelectorAll(triggerSelector)) {
        window.bootstrap.Popover.getInstance(trigger)?.hide();
      }
    };

    new MutationObserver((records) => {
      for (const record of records) {
        for (const node of record.addedNodes) {
          initialize(node);
        }
      }
    }).observe(document.body, { childList: true, subtree: true });

    document.addEventListener("click", (event) => {
      if (event.target.closest(`${triggerSelector}, ${popoverSelector}`)) return;
      hideAll();
    });

    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape") hideAll();
    });
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
  } else {
    start();
  }
})();
