(function() {
  var register = function() {
    if (!window.Shiny || !Shiny.addCustomMessageHandler) {
      window.setTimeout(register, 25);
      return;
    }

    if (window.commonsProvenancePillInitialized) return;
    window.commonsProvenancePillInitialized = true;

    // Keep the viewport still when a tool card is expanded or collapsed;
    // otherwise shinychat's stick-to-bottom scrolling chases the height
    // change. A synthetic upward wheel tick is the library's own escape
    // hatch: it unpins from the bottom without moving the viewport. Direct
    // scrollTop writes don't work here, since scroll events are ignored
    // while a resize (the expansion itself) is in flight. Repeated on the
    // next frames because the escape requires overflowing content, which
    // the expansion may only create after this handler runs.
    document.addEventListener("click", function(event) {
      if (!event.target || !event.target.closest) return;
      var header = event.target.closest(".shiny-tool-card > .card-header");
      if (!header) return;
      var scroller = header.closest(".shiny-chat-messages");
      if (!scroller) return;

      var escape = function() {
        scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: -1 }));
      };
      escape();
      window.requestAnimationFrame(function() {
        escape();
        window.requestAnimationFrame(escape);
      });
    }, true);

    Shiny.addCustomMessageHandler("commonsProvenancePill", function(message) {
      var chat = document.getElementById(message.id);
      if (!chat) return;

      var appendPill = function(attempt) {
        var messages = chat.querySelectorAll(
          ".shiny-chat-message .shiny-chat-message-content"
        );
        // Counted from the end: seeded chats may open with welcome messages,
        // so restored exchanges are the *last* assistant messages.
        var fromEnd = typeof message.indexFromEnd === "number" ? message.indexFromEnd : 0;
        var content = messages[messages.length - 1 - fromEnd];

        if (!content) {
          if (attempt < 40) {
            window.setTimeout(function() { appendPill(attempt + 1); }, 25);
          }
          return;
        }

        if (content.querySelector(".commons-answer-pill")) return;

        var holder = document.createElement("span");
        holder.innerHTML = message.html;
        var pill = holder.firstElementChild;
        if (!pill) return;

        var trigger = pill.querySelector("[data-commons-review-trigger]");
        if (trigger && message.inputId && window.Shiny && Shiny.setInputValue) {
          trigger.addEventListener("click", function(event) {
            event.preventDefault();
            Shiny.setInputValue(message.inputId, Date.now(), { priority: "event" });
          });
        }

        var blocks = content.querySelectorAll("p, li, table");
        var target = blocks[blocks.length - 1] || content;

        if (target.tagName === "TABLE" || target.tagName === "LI") {
          content.appendChild(document.createElement("br"));
          content.appendChild(pill);
          return;
        }

        target.appendChild(document.createTextNode(" "));
        target.appendChild(pill);
      };

      window.requestAnimationFrame(function() { appendPill(0); });
    });
  };

  register();
})();
