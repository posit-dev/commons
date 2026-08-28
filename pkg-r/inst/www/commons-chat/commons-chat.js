// <commons-provenance-info> renders the "how answer trust is determined"
// trigger inside shinychat aside popovers and opens a static offcanvas panel
// explaining the provenance outcomes. A custom element is the right fit here:
// shinychat mounts aside HTML long after page load, and custom elements
// upgrade whenever they connect, so no Shiny input binding or mount ordering
// is involved. Light DOM throughout, so the commons-chat stylesheet and
// Bootstrap's offcanvas CSS apply as usual.
//
// The panel is a singleton shared by every trigger on the page; the trigger
// uses Bootstrap's delegated data-api, so clicks need no listeners here.
// Icons are inlined (Radix Icons glyphs, MIT, https://www.radix-ui.com/icons)
// so the component doesn't depend on the dependency's versioned asset URLs.
(() => {
  const PANEL_ID = "commons-provenance-info";

  const icons = {
    trusted: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" aria-hidden="true"><path fill="#2fa37b" d="M8 1.1c1.7.9 3.7 1.7 5.7 2.1.4.1.7.5.7.9v4.7c0 3.2-2.1 5.7-6.4 7.2-4.3-1.5-6.4-4-6.4-7.2V4.1c0-.4.3-.8.7-.9 2-.4 4-1.2 5.7-2.1z"/><path fill="#fff" stroke="#fff" stroke-width="0.9" stroke-linejoin="round" transform="translate(8 8.3) scale(0.72) translate(-7.5 -7.5)" d="M10.6015 3.90815C10.7903 3.61941 11.1779 3.53792 11.4667 3.72651C11.7555 3.91533 11.837 4.30288 11.6484 4.59175L7.39837 11.0917C7.29822 11.2449 7.13558 11.3469 6.95404 11.3701C6.77251 11.3932 6.58945 11.3359 6.45404 11.2128L3.70404 8.71284L3.62005 8.61811C3.44857 8.38342 3.4589 8.05252 3.66205 7.82905C3.86511 7.60576 4.19344 7.56371 4.4433 7.71186L4.54584 7.78706L6.75287 9.79292L10.6015 3.90815Z"/></svg>`,
    cited: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" aria-hidden="true"><rect x="1.2" y="1.2" width="13.6" height="13.6" rx="3.4" fill="#55729e"/><path fill="#fff" fill-rule="evenodd" clip-rule="evenodd" transform="translate(8 8) scale(0.70) translate(-7.5 -7.5)" d="M9.42503 3.44136C10.0561 3.23654 10.7837 3.2402 11.3792 3.54623C12.7532 4.25224 13.3477 6.07191 12.7946 8C12.5465 8.8649 12.1102 9.70472 11.1861 10.5524C10.262 11.4 8.98034 11.9 8.38571 11.9C8.17269 11.9 8 11.7321 8 11.525C8 11.3179 8.17644 11.15 8.38571 11.15C9.06497 11.15 9.67189 10.7804 10.3906 10.236C10.9406 9.8193 11.3701 9.28633 11.608 8.82191C12.0628 7.93367 12.0782 6.68174 11.3433 6.34901C10.9904 6.73455 10.5295 6.95946 9.97725 6.95946C8.7773 6.95946 8.0701 5.99412 8.10051 5.12009C8.12957 4.28474 8.66032 3.68954 9.42503 3.44136ZM3.42503 3.44136C4.05614 3.23654 4.78366 3.2402 5.37923 3.54623C6.7532 4.25224 7.34766 6.07191 6.79462 8C6.54654 8.8649 6.11019 9.70472 5.1861 10.5524C4.26201 11.4 2.98034 11.9 2.38571 11.9C2.17269 11.9 2 11.7321 2 11.525C2 11.3179 2.17644 11.15 2.38571 11.15C3.06497 11.15 3.67189 10.7804 4.39058 10.236C4.94065 9.8193 5.37014 9.28633 5.60797 8.82191C6.06282 7.93367 6.07821 6.68174 5.3433 6.34901C4.99037 6.73455 4.52948 6.95946 3.97725 6.95946C2.7773 6.95946 2.0701 5.99412 2.10051 5.12009C2.12957 4.28474 2.66032 3.68954 3.42503 3.44136Z"/></svg>`,
    untrusted: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="7" fill="#d9b84a"/><path fill="#fff" stroke="#fff" stroke-width="0.35" stroke-linejoin="round" transform="translate(8 8) scale(1.1) translate(-7.5 -7.5)" d="M7.49946 9.72624C7.91367 9.72624 8.24946 10.062 8.24946 10.4762C8.24933 10.8903 7.91359 11.2262 7.49946 11.2262C7.08549 11.226 6.74958 10.8902 6.74946 10.4762C6.74946 10.0622 7.08542 9.72645 7.49946 9.72624ZM7.49946 3.78679C7.88158 3.78679 8.1879 4.10418 8.17329 4.48601L8.01899 8.48698C8.00826 8.76597 7.77866 8.98698 7.49946 8.98698C7.22048 8.98673 6.99163 8.76581 6.9809 8.48698L6.82661 4.48601C6.812 4.10434 7.11756 3.78706 7.49946 3.78679Z"/></svg>`,
  };

  const item = (marker, label, body) => `
    <li>
      <div class="commons-provenance-info-label">${marker}<strong>${label}</strong></div>
      <p>${body}</p>
    </li>`;

  const panelHTML = `
    <div class="offcanvas offcanvas-end" tabindex="-1" id="${PANEL_ID}"
         aria-labelledby="${PANEL_ID}-title" style="--bs-offcanvas-width: 22rem;">
      <div class="offcanvas-header">
        <h5 class="offcanvas-title" id="${PANEL_ID}-title">How answer trust is determined</h5>
        <button type="button" class="btn-close" data-bs-dismiss="offcanvas" aria-label="Close"></button>
      </div>
      <div class="offcanvas-body">
        <div class="commons-provenance-info-body">
          <p>This application asks an AI agent to use trusted calculations whenever possible.
             When no relevant calculation is available, the agent may write code itself.</p>
          <ul class="commons-provenance-info-list">
            ${item(icons.trusted, "Trusted", "For the given answer, the agent only searched for and invoked a human-vetted calculation.")}
            ${item('<span class="commons-provenance-info-no-marker" aria-hidden="true">\u2014</span>', "No marker", "No data tool was used for this answer, so commons assigns no provenance outcome.")}
            ${item(icons.cited, "Cited", "The agent did ad-hoc analysis and was able to cite vetted context that supported its approach.")}
            ${item(icons.untrusted, "Untrusted", "The agent did ad-hoc analysis and was <strong>not</strong> able to cite vetted context that supported its approach.")}
          </ul>
          <p>The agent itself does not choose the badge. The badge is chosen by
             the application based on the agent's response.</p>
        </div>
      </div>
    </div>`;

  const ensurePanel = () => {
    if (document.getElementById(PANEL_ID)) return;
    const host = document.createElement("div");
    host.innerHTML = panelHTML;
    document.body.appendChild(host.firstElementChild);
  };

  class CommonsProvenanceInfo extends HTMLElement {
    connectedCallback() {
      // Popovers can re-mount the same markup; don't render twice.
      if (this.querySelector("button")) return;
      ensurePanel();
      this.insertAdjacentHTML(
        "beforeend",
        `<button type="button" class="commons-provenance-info-trigger"
                 aria-label="How answer trust is determined"
                 aria-controls="${PANEL_ID}"
                 data-bs-toggle="offcanvas" data-bs-target="#${PANEL_ID}">
           <span aria-hidden="true">i</span>
         </button>`
      );
    }
  }

  customElements.define("commons-provenance-info", CommonsProvenanceInfo);
})();
