(() => {
  const triggerSelector = ".commons-provenance-info-trigger";

  const openModal = (trigger) => {
    const template = trigger.nextElementSibling.firstElementChild;
    const modal = template.cloneNode(true);
    document.body.append(modal);

    const instance = new window.bootstrap.Modal(modal);
    modal.addEventListener(
      "hidden.bs.modal",
      () => {
        instance.dispose();
        modal.remove();
        if (trigger.isConnected) trigger.focus();
      },
      { once: true }
    );

    instance.show();
    const backdrops = document.querySelectorAll(".modal-backdrop");
    backdrops.item(backdrops.length - 1)?.classList.add(
      "commons-provenance-info-backdrop"
    );
  };

  document.addEventListener("click", (event) => {
    const trigger = event.target.closest(triggerSelector);
    if (trigger) openModal(trigger);
  });
})();
