(function() {
  var register = function() {
    if (!window.Shiny || !Shiny.addCustomMessageHandler) {
      window.setTimeout(register, 25);
      return;
    }

    if (window.commonsChatInitialized) return;
    window.commonsChatInitialized = true;

    var resumeMessages = function(chat) {
      var content = chat.querySelector(".shiny-chat-messages-content");
      if (!content) return [];
      return content.querySelectorAll(
        ":scope > .shiny-chat-message, :scope > .shiny-chat-user-message"
      );
    };

    var resumeBoundaries = function(boundaries, count) {
      return Array.from(new Set(boundaries))
        .filter(function(index) {
          return Number.isInteger(index) && index > 0 && index <= count;
        })
        .sort(function(a, b) { return a - b; });
    };

    var reportResumeBoundaries = function(state) {
      var serialized = JSON.stringify(state.boundaries);
      if (serialized === state.lastReported) return;
      state.lastReported = serialized;
      Shiny.setInputValue(
        state.inputId,
        state.boundaries,
        { priority: "event" }
      );
    };

    var renderResumeBoundaries = function(chat, state, trim) {
      var messages = resumeMessages(chat);
      chat.querySelectorAll(".commons-resume-boundary").forEach(function(node) {
        node.classList.remove("commons-resume-boundary");
      });
      if (trim) {
        state.boundaries = resumeBoundaries(
          state.boundaries,
          messages.length
        );
      }
      state.boundaries.forEach(function(index) {
        if (messages[index - 1]) {
          messages[index - 1].classList.add("commons-resume-boundary");
        }
      });
      reportResumeBoundaries(state);
    };

    var scheduleResumeRender = function(chat, state) {
      window.clearTimeout(state.renderTimer);
      state.renderTimer = window.setTimeout(function() {
        var messages = resumeMessages(chat);
        if (messages.length === 0) {
          window.clearTimeout(state.clearTimer);
          state.clearTimer = window.setTimeout(function() {
            if (resumeMessages(chat).length === 0) {
              state.boundaries = [];
              reportResumeBoundaries(state);
            }
          }, 50);
          return;
        }
        window.clearTimeout(state.clearTimer);
        renderResumeBoundaries(chat, state, !state.restoring);
      }, 50);
    };

    Shiny.addCustomMessageHandler("commonsResumeConversation", function(message) {
      var chat = document.getElementById(message.id);
      if (!chat) return;

      var state = chat.commonsResumeState;
      if (!state) {
        state = {
          boundaries: [],
          inputId: message.input_id,
          lastReported: null,
          renderTimer: null,
          clearTimer: null,
          restoring: false,
          restoreGeneration: 0
        };
        chat.commonsResumeState = state;
        state.observer = new MutationObserver(function() {
          scheduleResumeRender(chat, state);
        });
        state.observer.observe(chat, { childList: true, subtree: true });
      }
      state.inputId = message.input_id;
      window.clearTimeout(state.clearTimer);
      state.restoring = true;
      var generation = ++state.restoreGeneration;
      state.boundaries = Array.isArray(message.boundaries)
        ? message.boundaries.slice()
        : Number.isInteger(message.boundaries)
          ? [message.boundaries]
          : [];

      var attempts = 0;
      var previousCount = -1;
      var markBoundary = function() {
        if (generation !== state.restoreGeneration) return;
        var messages = resumeMessages(chat);
        if (messages.length !== previousCount && attempts++ < 10) {
          previousCount = messages.length;
          window.requestAnimationFrame(markBoundary);
          return;
        }
        if (messages.length > 0) state.boundaries.push(messages.length);
        state.boundaries = resumeBoundaries(
          state.boundaries,
          messages.length
        );
        state.restoring = false;
        renderResumeBoundaries(chat, state, false);
      };

      window.requestAnimationFrame(markBoundary);
    });

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

    // Provenance tooltips are centered above their marker, which leaves them
    // hanging outside the chat pane — and clipped by it — when the marker
    // sits near an edge. The box has no layout until the marker is hovered
    // or focused, so it is measured and nudged back inside then: sideways by
    // a shift the arrow deliberately doesn't follow, so the arrow keeps
    // pointing at the marker, and vertically by flipping below.
    var placeTooltip = function(marker) {
      var tip = marker.querySelector(".commons-tooltip");
      if (!tip) return;

      marker.classList.remove("commons-tooltip-below");
      tip.style.setProperty("--commons-tooltip-shift", "0px");

      var rect = tip.getBoundingClientRect();
      if (!rect.width) return;

      var margin = 8;
      var bounds = clipBounds(marker);
      var minLeft = bounds.left + margin;
      var maxRight = bounds.right - margin;

      var shift = 0;
      if (rect.right > maxRight) shift = maxRight - rect.right;
      if (rect.left + shift < minLeft) shift = minLeft - rect.left;
      tip.style.setProperty("--commons-tooltip-shift", shift + "px");

      if (rect.top < bounds.top + margin) {
        marker.classList.add("commons-tooltip-below");
      }
    };

    // Any scrolling or clipping ancestor can crop the tooltip, not just the
    // nearest one: shinychat's message scroller deliberately hangs a
    // scroll-margin's worth of padding past the wrapper that clips it, so
    // stopping at the scroller still leaves the box cut off on the right.
    var clipBounds = function(marker) {
      var root = document.documentElement;
      var bounds = { left: 0, right: root.clientWidth, top: 0 };

      for (var node = marker.parentElement; node; node = node.parentElement) {
        if (!node.clientWidth && !node.clientHeight) continue;
        var style = window.getComputedStyle(node);
        var rect = node.getBoundingClientRect();
        if (style.overflowX !== "visible") {
          var left = rect.left + node.clientLeft;
          bounds.left = Math.max(bounds.left, left);
          bounds.right = Math.min(bounds.right, left + node.clientWidth);
        }
        if (style.overflowY !== "visible") {
          bounds.top = Math.max(bounds.top, rect.top + node.clientTop);
        }
      }

      return bounds;
    };

    var onMarker = function(event) {
      if (!event.target || !event.target.closest) return;
      var marker = event.target.closest(".commons-answer-pill");
      if (marker) placeTooltip(marker);
    };

    document.addEventListener("pointerover", onMarker, true);
    document.addEventListener("focusin", onMarker, true);
  };

  register();
})();
