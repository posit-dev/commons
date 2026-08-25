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
      var top = Math.max(0, first.top - parent.top - padding);
      var bottom = last.bottom - parent.top + padding;
      highlight.style.display = "block";
      highlight.style.top = top + "px";
      highlight.style.height = Math.max(0, bottom - top) + "px";
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

    var selectSidebar = function(conversation, exchange) {
      var accordion = document.getElementById("conversation_groups");
      if (!accordion) return;

      accordion.querySelectorAll(".accordion-item").forEach(function(item) {
        var selected =
          exchange == null &&
          item.dataset.value === String(conversation);
        item.classList.toggle(
          "commons-viewer-conversation-selected",
          selected
        );
      });
      accordion.querySelectorAll(".commons-viewer-entry").forEach(function(node) {
        var selected =
          exchange != null &&
          node.dataset.conversation === String(conversation) &&
          node.dataset.exchange === String(exchange);
        node.classList.toggle("commons-viewer-entry-selected", selected);
      });
    };

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

      var conversationButton = event.target.closest(
        "#conversation_groups .accordion-button"
      );
      if (conversationButton) {
        var item = conversationButton.closest(".accordion-item");
        var conversation = item && Number(item.dataset.value);
        if (Number.isInteger(conversation)) {
          selectSidebar(conversation, null);
          Shiny.setInputValue(
            "conversation_select",
            { conversation: conversation, nonce: Math.random() },
            { priority: "event" }
          );
        }
      }

      var entry = event.target.closest(
        "#conversation_groups .commons-viewer-entry"
      );
      if (entry) {
        selectSidebar(
          Number(entry.dataset.conversation),
          Number(entry.dataset.exchange)
        );
      }

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

    Shiny.addCustomMessageHandler("commonsViewerExchangeSelect", function(message) {
      var chat = document.getElementById(message.id);
      if (!chat) return;
      selectExchange(chat, message.exchange == null ? null : message.exchange);
    });

    Shiny.addCustomMessageHandler("commonsViewerSidebarSelect", function(message) {
      selectSidebar(
        message.conversation == null ? null : message.conversation,
        message.exchange == null ? null : message.exchange
      );
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
