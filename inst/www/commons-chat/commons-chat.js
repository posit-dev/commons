(function() {
  var register = function() {
    if (!window.Shiny || !Shiny.addCustomMessageHandler) {
      window.setTimeout(register, 25);
      return;
    }

    if (window.commonsAnswerPillTooltipInitialized) return;
    window.commonsAnswerPillTooltipInitialized = true;

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

    // The trajectory reviewer's sidebar still renders commons_answer_pill()
    // trust badges (R/trajectory-review.R's question_entry()), so their
    // hover/focus tooltip needs to stay positioned within the viewport.
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
