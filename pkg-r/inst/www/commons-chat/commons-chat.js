(() => {
  const componentName = "commons-provenance-info";
  const modalId = "commons-provenance-info-modal";
  const assetRoot = new URL(".", document.currentScript.src);

  const icon = (file) => `
    <img src="${new URL(`figs/${file}`, assetRoot)}" alt="" aria-hidden="true">`;

  const item = (marker, label, body) => `
    <li>
      <div class="commons-provenance-info-label">
        ${marker}
        <strong>${label}</strong>
      </div>
      <p>${body}</p>
    </li>`;

  const modal = `
    <div class="modal fade" id="${modalId}" tabindex="-1"
         aria-labelledby="${modalId}-title">
      <div class="modal-dialog">
        <div class="modal-content">
          <div class="modal-header">
            <h4 class="modal-title" id="${modalId}-title">
              How answer trust is determined
            </h4>
          </div>
          <div class="modal-body">
            <div class="commons-provenance-info-body">
              <p>
                This application asks an AI agent to use trusted calculations
                whenever possible. When no relevant calculation is available,
                the agent may write code itself.
              </p>
              <ul class="commons-provenance-info-list">
                ${item(
                  icon("trusted-icon.svg"),
                  "Trusted",
                  "For the given answer, the agent only searched for and invoked a human-vetted calculation."
                )}
                ${item(
                  '<span class="commons-provenance-info-no-marker" aria-hidden="true">—</span>',
                  "No marker",
                  "For answers that don't do any new calculations, the application shows no badge."
                )}
                ${item(
                  icon("citation-mark.svg"),
                  "Cited",
                  "The agent did ad-hoc analysis and was able to cite vetted context that supported its approach."
                )}
                ${item(
                  icon("warning-icon.svg"),
                  "Untrusted",
                  "The agent did ad-hoc analysis and was <strong>not</strong> able to cite vetted context that supported its approach."
                )}
              </ul>
              <p>
                The agent itself does not choose the badge. The badge is chosen
                by the application based on the agent's response.
              </p>
            </div>
          </div>
          <div class="modal-footer">
            <button type="button" class="btn btn-default"
                    data-dismiss="modal" data-bs-dismiss="modal">Close</button>
          </div>
        </div>
      </div>
    </div>`;

  const ensureModal = () => {
    if (document.getElementById(modalId)) return;
    document.body.insertAdjacentHTML("beforeend", modal);
  };

  class CommonsProvenanceInfo extends HTMLElement {
    connectedCallback() {
      if (this.querySelector("button")) return;
      ensureModal();
      this.insertAdjacentHTML(
        "beforeend",
        `<button type="button" class="commons-provenance-info-trigger"
                 aria-label="How answer trust is determined"
                 aria-controls="${modalId}"
                 data-toggle="modal" data-bs-toggle="modal"
                 data-target="#${modalId}" data-bs-target="#${modalId}">
           <span aria-hidden="true">i</span>
         </button>`
      );
    }
  }

  customElements.define(componentName, CommonsProvenanceInfo);
})();
