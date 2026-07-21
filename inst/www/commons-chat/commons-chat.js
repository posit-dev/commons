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
    // hatch: it unpins from the bottom without moving the viewport. The
    // escape only registers once the content actually overflows, which the
    // expansion may create at any point during its transition, so it is
    // repeated every frame for a beat — alongside a scrollTop hold, since
    // scroll events (but not wheel events) are ignored while a resize is
    // in flight.
    document.addEventListener("click", function(event) {
      if (!event.target || !event.target.closest) return;
      var header = event.target.closest(".shiny-tool-card > .card-header");
      if (!header) return;
      var scroller = header.closest(".shiny-chat-messages");
      if (!scroller) return;

      var top = scroller.scrollTop;
      var until = performance.now() + 600;
      var steady = function() {
        scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: -1 }));
        if (scroller.scrollTop !== top) {
          scroller.scrollTop = top;
        }
        if (performance.now() < until) {
          window.requestAnimationFrame(steady);
        }
      };
      steady();
    }, true);

    var messageContents = function(chat) {
      return chat.querySelectorAll(
        ".shiny-chat-message .shiny-chat-message-content"
      );
    };

    // One numbered footnote for a run of adjacent citations. The tooltip
    // interleaves the model's short reason for each citation (unverified
    // commentary, shown plain) with the verified quote (shown as an
    // attributed blockquote); it is a real element rather than the pills'
    // attr() pseudo-element so it can hold that structure.
    var footnote = function(number, entries) {
      var sup = document.createElement("sup");
      sup.className = "commons-citation";
      sup.setAttribute("tabindex", "0");
      sup.textContent = String(number);

      var tip = document.createElement("span");
      tip.className = "commons-citation-tooltip";
      tip.setAttribute("role", "tooltip");
      var summary = [];
      entries.forEach(function(entry) {
        var heading = entry.reason && (
          /[.,:;!?]$/.test(entry.reason) ? entry.reason : entry.reason + ":"
        );
        if (heading) {
          var reason = document.createElement("span");
          reason.className = "commons-citation-reason";
          reason.textContent = heading;
          tip.appendChild(reason);
        }
        var quote = document.createElement("span");
        quote.className = "commons-citation-quote";
        quote.textContent = "“" + entry.quote + "”";
        var source = document.createElement("span");
        source.className = "commons-citation-source";
        source.textContent = "— " + entry.label;
        quote.appendChild(source);
        tip.appendChild(quote);
        summary.push(
          (heading ? heading + " " : "") +
            "“" + entry.quote + "” — " + entry.label
        );
      });
      sup.setAttribute("aria-label", summary.join("; "));
      sup.appendChild(tip);
      return sup;
    };

    // Citations the model wrote back to back — separated only by
    // whitespace, typically one per line at the end of the reply.
    var adjacentCitations = function(a, b) {
      var node = a.nextSibling;
      while (node && node !== b) {
        if (node.nodeType !== Node.TEXT_NODE || node.textContent.trim()) {
          return false;
        }
        node = node.nextSibling;
      }
      return node === b;
    };

    var footnotesOnly = function(p) {
      var found = false;
      for (var node = p.firstChild; node; node = node.nextSibling) {
        if (node.nodeType === Node.ELEMENT_NODE) {
          if (!node.classList.contains("commons-citation")) return false;
          found = true;
        } else if (node.textContent.trim()) {
          return false;
        }
      }
      return found;
    };

    // The server verifies each <citation> the answer rendered and sends one
    // entry per element, in document order; positional matching avoids
    // re-matching quote text that markdown rendering may have reflowed.
    // Each run of adjacent citations with a verified entry becomes one
    // merged numbered footnote, and unverified citations are dropped.
    var applyCitations = function(content, citations) {
      var elements = content.querySelectorAll("citation");
      if (!elements.length) return;

      var runs = [];
      elements.forEach(function(el, i) {
        var run = runs[runs.length - 1];
        if (run && adjacentCitations(run.elements[run.elements.length - 1], el)) {
          run.elements.push(el);
          run.entries.push((citations || [])[i]);
        } else {
          runs.push({ elements: [el], entries: [(citations || [])[i]] });
        }
      });

      var n = 0;
      runs.forEach(function(run) {
        var verified = run.entries.filter(function(entry) {
          return entry && entry.verified;
        });
        if (verified.length) {
          n += 1;
          run.elements[0].replaceWith(footnote(n, verified));
        }
        run.elements.forEach(function(el) {
          var parent = el.parentElement;
          el.remove();
          var emptied = parent &&
            parent.tagName === "P" &&
            !parent.textContent.trim() &&
            !parent.children.length;
          if (emptied) parent.remove();
        });
      });

      // A paragraph left holding only footnotes collapses into the end of
      // the preceding block, so markers sit inline with the answer.
      content.querySelectorAll("p").forEach(function(p) {
        if (!footnotesOnly(p)) return;
        var prev = p.previousElementSibling;
        var target =
          prev && prev.tagName === "P" ? prev :
          prev && (prev.tagName === "UL" || prev.tagName === "OL")
            ? prev.lastElementChild : null;
        if (!target) return;
        p.querySelectorAll(".commons-citation").forEach(function(sup) {
          target.appendChild(sup);
        });
        p.remove();
      });
    };

    var placePill = function(content, html, citations) {
      applyCitations(content, citations);
      if (content.querySelector(".commons-answer-pill")) return;

      var holder = document.createElement("span");
      holder.innerHTML = html;
      var pill = holder.firstElementChild;
      if (!pill) return;

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

    // A live turn's pill lands on the last assistant message.
    Shiny.addCustomMessageHandler("commonsProvenancePill", function(message) {
      var chat = document.getElementById(message.id);
      if (!chat) return;

      var appendPill = function(attempt) {
        var messages = messageContents(chat);
        var content = messages[messages.length - 1];

        if (!content) {
          if (attempt < 40) {
            window.setTimeout(function() { appendPill(attempt + 1); }, 25);
          }
          return;
        }

        placePill(content, message.html, message.citations);
      };

      window.requestAnimationFrame(function() { appendPill(0); });
    });

    // Restored history streams into the chat message by message, so pills
    // for seeded exchanges can only be placed once every exchange has
    // rendered and the transcript has stopped growing; placing them
    // eagerly races the restore and pins them to whichever message happens
    // to be last at the time. Indexed from the end because seeded chats may
    // open with welcome messages ahead of the restored exchanges.
    Shiny.addCustomMessageHandler("commonsProvenancePillSeed", function(message) {
      var chat = document.getElementById(message.id);
      if (!chat) return;

      var attempts = 0;
      var stable = 0;
      var lastSize = -1;

      var place = function() {
        var messages = messageContents(chat);
        var size = chat.textContent.length;

        if (messages.length < message.count || size !== lastSize) {
          stable = 0;
        } else {
          stable += 1;
        }
        lastSize = size;

        if (stable < 3) {
          if (attempts++ < 200) window.setTimeout(place, 50);
          return;
        }

        message.pills.forEach(function(pill) {
          var content = messages[messages.length - 1 - pill.indexFromEnd];
          if (content) placePill(content, pill.html, pill.citations);
        });
      };

      window.setTimeout(place, 50);
    });
  };

  register();
})();
