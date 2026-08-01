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
      };

      seed();
    });
  };

  register();
})();

// Trust-level timeline: a 100%-stacked area chart drawn client-side from
// the JSON payload trust_timeline() renders, so it can size to its card
// and re-draw as the card resizes. All values it shows on hover also live
// in the adjacent (visually hidden) table.
(function() {
  var SVG = "http://www.w3.org/2000/svg";
  // Chart chrome shares the app's text/border tokens; the surface color
  // doubles as the 2px gap separating stacked bands.
  var SURFACE = "var(--bs-card-bg, #fff)";
  var GRID = "var(--bs-border-color, #dee2e6)";
  var TEXT = "var(--bs-secondary-color, #6c757d)";
  var MARGIN = { top: 8, right: 12, bottom: 22, left: 40 };

  var element = function(name, attributes, parent) {
    var node = document.createElementNS(SVG, name);
    Object.keys(attributes || {}).forEach(function(key) {
      node.setAttribute(key, attributes[key]);
    });
    if (parent) parent.appendChild(node);
    return node;
  };

  // Cumulative share boundaries per day: boundaries[i][k] is the fraction
  // of day i's answers at or below stack level k.
  var boundaries = function(days, levels) {
    return days.map(function(day) {
      var total = 0;
      return levels.map(function(level) {
        total += day.counts[level.key] / day.n;
        return Math.min(total, 1);
      });
    });
  };

  var timeScale = function(days, left, width) {
    var times = days.map(function(day) {
      return Date.parse(day.date + "T00:00:00Z");
    });
    var min = times[0];
    var span = times[times.length - 1] - min || 1;
    return times.map(function(time) {
      return left + ((time - min) / span) * width;
    });
  };

  // Date ticks at roughly 90px spacing, always including the first and
  // last day; indices are deduplicated when the chart is narrow.
  var tickIndexes = function(count, width) {
    var target = Math.max(2, Math.min(count, Math.floor(width / 90) + 1));
    var indexes = [];
    for (var i = 0; i < target; i++) {
      var index = Math.round((i * (count - 1)) / (target - 1));
      if (indexes.indexOf(index) === -1) indexes.push(index);
    }
    return indexes;
  };

  var shortLabel = function(day) {
    return day.label.replace(/,\s*\d{4}$/, "").replace(/\s+/g, " ");
  };

  var drawFrame = function(svg, geometry) {
    [0, 0.5, 1].forEach(function(share) {
      var y = geometry.y(share);
      element("line", {
        x1: MARGIN.left, x2: geometry.right, y1: y, y2: y,
        stroke: GRID, "stroke-width": 1
      }, svg);
      var label = element("text", {
        x: MARGIN.left - 8, y: y + 3.5,
        "text-anchor": "end", "font-size": 11, fill: TEXT
      }, svg);
      label.textContent = Math.round(share * 100) + "%";
    });
  };

  var drawTicks = function(svg, geometry, days, xs) {
    tickIndexes(days.length, geometry.right - MARGIN.left)
      .forEach(function(index) {
        var anchor = index === 0 ? "start" :
          index === days.length - 1 ? "end" : "middle";
        var label = element("text", {
          x: xs[index], y: geometry.bottom + 15,
          "text-anchor": anchor, "font-size": 11, fill: TEXT
        }, svg);
        label.textContent = shortLabel(days[index]);
      });
  };

  var drawBands = function(svg, geometry, payload, xs, stacked) {
    payload.levels.forEach(function(level, k) {
      var upper = xs.map(function(x, i) {
        return x + "," + geometry.y(stacked[i][k]);
      });
      var lower = xs.map(function(x, i) {
        return x + "," + geometry.y(k === 0 ? 0 : stacked[i][k - 1]);
      });
      element("polygon", {
        points: upper.concat(lower.reverse()).join(" "),
        fill: level.color
      }, svg);
    });
    // Interior boundaries redrawn as surface-colored lines: the 2px gap
    // that keeps neighboring bands apart without adding stroke ink.
    for (var k = 0; k + 1 < payload.levels.length; k++) {
      element("polyline", {
        points: xs.map(function(x, i) {
          return x + "," + geometry.y(stacked[i][k]);
        }).join(" "),
        fill: "none", stroke: SURFACE, "stroke-width": 2
      }, svg);
    }
  };

  // A single dated day can't make an area; it gets one stacked column with
  // the same gaps, rounded at the top of the stack, square at the baseline.
  var drawColumn = function(svg, geometry, payload, x, stacked) {
    var half = 12;
    payload.levels.forEach(function(level, k) {
      var top = geometry.y(stacked[0][k]);
      var bottom = geometry.y(k === 0 ? 0 : stacked[0][k - 1]);
      if (bottom - top < 0.5) return;
      var gap = k === 0 ? 0 : 2;
      var rounded = stacked[0][k] >= 1 - 1e-9;
      element("path", {
        d: rounded
          ? "M" + (x - half) + " " + (bottom - gap) +
            "V" + (top + 4) +
            "Q" + (x - half) + " " + top + " " + (x - half + 4) + " " + top +
            "H" + (x + half - 4) +
            "Q" + (x + half) + " " + top + " " + (x + half) + " " + (top + 4) +
            "V" + (bottom - gap) + "Z"
          : "M" + (x - half) + " " + (bottom - gap) +
            "V" + top + "H" + (x + half) + "V" + (bottom - gap) + "Z",
        fill: level.color
      }, svg);
    });
  };

  var buildTooltip = function(state, index) {
    var day = state.payload.days[index];
    var tooltip = state.tooltip;
    tooltip.textContent = "";
    var heading = document.createElement("div");
    heading.className = "commons-viewer-timeline-tooltip-date";
    heading.textContent = day.label.replace(/\s+/g, " ") +
      " · " + day.n + (day.n === 1 ? " answer" : " answers");
    tooltip.appendChild(heading);
    state.payload.levels.forEach(function(level) {
      var row = document.createElement("div");
      row.className = "commons-viewer-timeline-tooltip-row";
      var swatch = document.createElement("span");
      swatch.className = "commons-viewer-timeline-swatch";
      swatch.style.background = level.color;
      var value = document.createElement("strong");
      value.textContent =
        Math.round((100 * day.counts[level.key]) / day.n) + "%";
      var label = document.createElement("span");
      label.textContent = level.label;
      row.appendChild(swatch);
      row.appendChild(value);
      row.appendChild(label);
      tooltip.appendChild(row);
    });
  };

  var showIndex = function(state, index) {
    if (!state.geometry) return;
    state.index = index;
    var x = state.xs[index];
    state.crosshair.setAttribute("x1", x);
    state.crosshair.setAttribute("x2", x);
    state.crosshair.style.display = "block";
    buildTooltip(state, index);
    var tooltip = state.tooltip;
    tooltip.style.display = "block";
    var plotWidth = state.plot.clientWidth;
    var width = tooltip.offsetWidth;
    var left = x + 12 + width > plotWidth ? x - 12 - width : x + 12;
    tooltip.style.left = Math.max(0, left) + "px";
    tooltip.style.top = MARGIN.top + "px";
  };

  var hideIndex = function(state) {
    state.index = null;
    state.crosshair.style.display = "none";
    state.tooltip.style.display = "none";
  };

  var nearestIndex = function(state, clientX) {
    var offset = clientX - state.plot.getBoundingClientRect().left;
    var best = 0;
    state.xs.forEach(function(x, i) {
      if (Math.abs(x - offset) < Math.abs(state.xs[best] - offset)) best = i;
    });
    return best;
  };

  var drawTimeline = function(state) {
    var plot = state.plot;
    var payload = state.payload;
    var width = plot.clientWidth;
    var height = plot.clientHeight;
    if (width <= MARGIN.left + MARGIN.right || height <= 0) return;

    var geometry = {
      right: width - MARGIN.right,
      bottom: height - MARGIN.bottom,
      y: function(share) {
        return MARGIN.top +
          (1 - share) * (height - MARGIN.top - MARGIN.bottom);
      }
    };
    var stacked = boundaries(payload.days, payload.levels);
    var xs = payload.days.length === 1
      ? [(MARGIN.left + geometry.right) / 2]
      : timeScale(payload.days, MARGIN.left, geometry.right - MARGIN.left);

    plot.textContent = "";
    var svg = element("svg", { width: width, height: height });
    drawFrame(svg, geometry);
    if (payload.days.length === 1) {
      drawColumn(svg, geometry, payload, xs[0], stacked);
    } else {
      drawBands(svg, geometry, payload, xs, stacked);
    }
    drawTicks(svg, geometry, payload.days, xs);
    state.crosshair = element("line", {
      y1: MARGIN.top, y2: geometry.bottom,
      stroke: TEXT, "stroke-width": 1, style: "display: none"
    }, svg);
    plot.appendChild(svg);

    state.geometry = geometry;
    state.xs = xs;
    if (state.index != null && state.index < payload.days.length) {
      showIndex(state, state.index);
    }
  };

  var attachPointer = function(state) {
    state.plot.addEventListener("pointermove", function(event) {
      showIndex(state, nearestIndex(state, event.clientX));
    });
    state.plot.addEventListener("pointerleave", function() {
      hideIndex(state);
    });
    state.plot.addEventListener("keydown", function(event) {
      var last = state.payload.days.length - 1;
      var moves = {
        ArrowLeft: state.index == null ? last : Math.max(0, state.index - 1),
        ArrowRight: state.index == null
          ? 0
          : Math.min(last, state.index + 1),
        Home: 0,
        End: last
      };
      if (event.key === "Escape") {
        hideIndex(state);
      } else if (event.key in moves) {
        showIndex(state, moves[event.key]);
      } else {
        return;
      }
      event.preventDefault();
    });
    state.plot.addEventListener("blur", function() {
      hideIndex(state);
    });
  };

  var initTimeline = function(container) {
    if (container.commonsViewerTimeline) return;
    container.commonsViewerTimeline = true;
    var script = container.querySelector(".commons-viewer-timeline-data");
    var plot = container.querySelector(".commons-viewer-timeline-plot");
    if (!script || !plot) return;
    var payload;
    try {
      payload = JSON.parse(script.textContent);
    } catch (error) {
      return;
    }
    if (!payload.days || !payload.days.length) return;

    var tooltip = document.createElement("div");
    tooltip.className = "commons-viewer-timeline-tooltip";
    container.appendChild(tooltip);

    var state = {
      payload: payload,
      plot: plot,
      tooltip: tooltip,
      index: null
    };
    drawTimeline(state);
    attachPointer(state);
    new ResizeObserver(function() {
      drawTimeline(state);
    }).observe(plot);
  };

  var scan = function() {
    document
      .querySelectorAll(".commons-viewer-timeline")
      .forEach(initTimeline);
  };

  // The timeline arrives with each renderUI flush; watch for it rather
  // than hooking Shiny's (jQuery-only) render events.
  var observe = function() {
    if (!document.body) {
      window.setTimeout(observe, 25);
      return;
    }
    new MutationObserver(scan).observe(document.body, {
      childList: true,
      subtree: true
    });
    scan();
  };

  observe();
})();
