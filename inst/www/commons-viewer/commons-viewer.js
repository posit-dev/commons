(function() {
  var register = function() {
    if (!window.Shiny || !Shiny.addCustomMessageHandler) {
      window.setTimeout(register, 25);
      return;
    }
    if (window.commonsViewerExchangeInitialized) return;
    window.commonsViewerExchangeInitialized = true;

    var exchangeMessages = function(chat) {
      return chat.querySelectorAll(
        ".shiny-chat-user-message, .shiny-chat-message"
      );
    };

    var positionHighlight = function(chat) {
      var selected = chat.querySelectorAll(
        ".commons-viewer-exchange-selected"
      );
      var content = chat.querySelector(".shiny-chat-messages-content");
      var highlight = content &&
        content.querySelector(".commons-viewer-exchange-highlight");
      if (!highlight || !selected.length) {
        if (highlight) highlight.style.display = "none";
        return;
      }

      var first = selected[0].getBoundingClientRect();
      var last = selected[selected.length - 1].getBoundingClientRect();
      var parent = content.getBoundingClientRect();
      var padding = 8;
      highlight.style.display = "block";
      highlight.style.top = first.top - parent.top - padding + "px";
      highlight.style.height = last.bottom - first.top + 2 * padding + "px";
    };

    var ensureHighlight = function(chat) {
      var content = chat.querySelector(".shiny-chat-messages-content");
      if (!content) return;
      var highlight = content.querySelector(
        ".commons-viewer-exchange-highlight"
      );
      if (!highlight) {
        highlight = document.createElement("div");
        highlight.className = "commons-viewer-exchange-highlight";
        content.prepend(highlight);
      }
      if (!chat.commonsViewerResizeObserver) {
        chat.commonsViewerResizeObserver = new ResizeObserver(function() {
          positionHighlight(chat);
        });
        chat.commonsViewerResizeObserver.observe(content);
      }
    };

    var selectExchange = function(chat, exchange) {
      exchangeMessages(chat).forEach(function(node) {
        var selected = node.dataset.exchange === String(exchange);
        node.classList.toggle("commons-viewer-exchange-selected", selected);
        if (node.dataset.exchange) {
          node.setAttribute("aria-pressed", selected ? "true" : "false");
        }
      });
      ensureHighlight(chat);
      window.requestAnimationFrame(function() {
        positionHighlight(chat);
      });
    };

    // Clicking the selected exchange again deselects it; `exchange: null`
    // tells the server to drop its review target.
    var activateExchange = function(node) {
      var chat = node.closest("shiny-chat-container");
      var exchange = Number(node.dataset.exchange);
      if (!chat || !Number.isInteger(exchange)) return;
      var deselect = node.classList.contains(
        "commons-viewer-exchange-selected"
      );
      selectExchange(chat, deselect ? null : exchange);
      Shiny.setInputValue(
        "exchange_select",
        { exchange: deselect ? null : exchange, nonce: Math.random() },
        { priority: "event" }
      );
    };

    document.addEventListener("click", function(event) {
      if (!event.target || !event.target.closest) return;
      var node = event.target.closest(".commons-viewer-exchange-message");
      if (!node) return;
      var control = event.target.closest(
        "a, button, input, textarea, select, [tabindex]"
      );
      if (control && control !== node) return;
      activateExchange(node);
    });

    document.addEventListener("keydown", function(event) {
      if (event.key !== "Enter" && event.key !== " ") return;
      var node = event.target.closest(".commons-viewer-exchange-message");
      if (!node || event.target !== node) return;
      event.preventDefault();
      activateExchange(node);
    });

    // The divider between the transcript and the notes pane drags (and, for
    // keyboard users, arrows) the pane's width, within bounds that keep both
    // panes usable.
    var setReviewWidth = function(workspace, width) {
      var bounds = workspace.getBoundingClientRect();
      var min = 200;
      var max = Math.max(min, bounds.width - 320);
      width = Math.min(Math.max(width, min), max);
      workspace.style.setProperty(
        "--commons-viewer-review-width",
        width + "px"
      );
    };

    var resizing = null;
    document.addEventListener("pointerdown", function(event) {
      if (!event.target || !event.target.closest) return;
      var resizer = event.target.closest(".commons-viewer-pane-resizer");
      if (!resizer) return;
      var workspace = resizer.closest(".commons-viewer-workspace");
      if (!workspace) return;
      event.preventDefault();
      resizer.setPointerCapture(event.pointerId);
      resizer.classList.add("commons-viewer-pane-resizing");
      resizing = { resizer: resizer, workspace: workspace };
    });

    document.addEventListener("pointermove", function(event) {
      if (!resizing) return;
      var bounds = resizing.workspace.getBoundingClientRect();
      setReviewWidth(resizing.workspace, bounds.right - event.clientX);
    });

    var endResize = function() {
      if (!resizing) return;
      resizing.resizer.classList.remove("commons-viewer-pane-resizing");
      resizing = null;
    };
    document.addEventListener("pointerup", endResize);
    document.addEventListener("pointercancel", endResize);

    document.addEventListener("keydown", function(event) {
      if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
      if (!event.target || !event.target.closest) return;
      var resizer = event.target.closest(".commons-viewer-pane-resizer");
      if (!resizer) return;
      var workspace = resizer.closest(".commons-viewer-workspace");
      var pane = workspace &&
        workspace.querySelector(".commons-viewer-review-pane");
      if (!pane) return;
      event.preventDefault();
      var step = event.key === "ArrowLeft" ? 16 : -16;
      setReviewWidth(
        workspace,
        pane.getBoundingClientRect().width + step
      );
    });

    // Server-driven selection state: review_target changes (including
    // deselection when navigation moves away) mirror into the transcript.
    Shiny.addCustomMessageHandler("commonsViewerExchangeSelect", function(message) {
      var chat = document.getElementById(message.id);
      if (!chat) return;
      selectExchange(chat, message.exchange == null ? null : message.exchange);
    });

    Shiny.addCustomMessageHandler("commonsViewerExchangeSeed", function(message) {
      var chat = document.getElementById(message.id);
      if (!chat) return;

      var attempts = 0;
      var stable = 0;
      var lastSize = -1;
      var seed = function() {
        var nodes = exchangeMessages(chat);
        var size = chat.textContent.length;
        if (nodes.length < message.count || size !== lastSize) {
          stable = 0;
        } else {
          stable += 1;
        }
        lastSize = size;
        if (stable < 3) {
          if (attempts++ < 200) window.setTimeout(seed, 25);
          return;
        }

        message.exchanges.forEach(function(exchange, i) {
          var node = nodes[i];
          if (!node) return;
          node.classList.add("commons-viewer-exchange-message");
          node.dataset.exchange = exchange;
          node.setAttribute("role", "button");
          node.setAttribute("tabindex", "0");
          node.setAttribute(
            "aria-label",
            "Select question " + exchange + " for review notes"
          );
        });
        selectExchange(chat, message.selected);
        // A question entry opens the whole conversation; slide its
        // exchange to the top of the view.
        if (message.selected != null) {
          var target = chat.querySelector(
            '.commons-viewer-exchange-message[data-exchange="' +
              message.selected + '"]'
          );
          if (target) {
            target.scrollIntoView({ behavior: "smooth", block: "start" });
          }
        }
      };

      seed();
    });
  };

  register();
})();
