(function() {
  var register = function() {
    if (!window.Shiny || !Shiny.addCustomMessageHandler) {
      window.setTimeout(register, 25);
      return;
    }

    if (window.commonsProvenancePillInitialized) return;
    window.commonsProvenancePillInitialized = true;

    Shiny.addCustomMessageHandler("commonsProvenancePill", function(message) {
      var chat = document.getElementById(message.id);
      if (!chat) return;

      var appendPill = function(attempt) {
        var messages = chat.querySelectorAll(
          ".shiny-chat-message .shiny-chat-message-content"
        );
        var content = messages[messages.length - 1];

        if (!content) {
          if (attempt < 20) {
            window.setTimeout(function() { appendPill(attempt + 1); }, 25);
          }
          return;
        }

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

        if (target.tagName === "TABLE") {
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
