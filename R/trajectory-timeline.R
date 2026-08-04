# The trajectory reviewer's "Trust levels over time" card: adaptive
# day/week/month binning of question tags, the plotly chart, and its
# screen-reader table.

viewer_levels <- c(
  A = "Verified",
  B = "Cited",
  C = "Untrusted",
  none = "No data tool"
)

# One fill per trust level, in stack order (Verified at the baseline). The
# set passes the usual palette gates -- colorblind separation between stack
# neighbors and 3:1 contrast on a white surface -- which is why "No data
# tool" wears a muted violet rather than a gray that would read as
# background, and Untrusted a darker amber than its pill.
viewer_level_colors <- c(
  A = "#2a9d64",
  B = "#2a78d6",
  C = "#b8860b",
  none = "#8a72c8"
)

# The card frame and title are static; the legend and plot re-render as
# the date window moves.
trust_timeline_card <- function() {
  bslib::card(
    fill = FALSE,
    class = "commons-viewer-timeline-card",
    bslib::card_header(
      class = "commons-viewer-timeline-header",
      htmltools::tags$strong("Trust levels over time"),
      shiny::uiOutput("timeline_legend", inline = TRUE)
    ),
    shiny::uiOutput("timeline")
  )
}

# The legend is a plain key for the chart's colors; each level's
# window-wide share sits one hover away, in its entry's tooltip, rather
# than inline where it read as part of the chart.
timeline_legend <- function(rate) {
  htmltools::div(
    class = "commons-viewer-timeline-legend",
    lapply(names(viewer_levels), function(key) {
      htmltools::tags$span(
        class = "commons-viewer-timeline-legend-item",
        title = sprintf(
          "%d of %d answers (%s)",
          rate$counts[[key]],
          rate$n,
          rate_percent(rate$counts[[key]], rate$n)
        ),
        htmltools::tags$span(
          class = "commons-viewer-timeline-swatch",
          style = paste0("background:", viewer_level_colors[[key]])
        ),
        viewer_levels[[key]]
      )
    })
  )
}

# Exchange-level counts of each trust level across a set of conversations'
# tag vectors.
hit_rate <- function(tag_sets) {
  tags <- unlist(tag_sets) %||% character()
  list(n = length(tags), counts = tag_counts(tags))
}

tag_counts <- function(tags) {
  c(
    A = sum(tags %in% "A"),
    B = sum(tags %in% "B"),
    C = sum(tags %in% "C"),
    none = sum(is.na(tags))
  )
}

rate_percent <- function(count, n) {
  if (n == 0) {
    return("\u2014")
  }
  sprintf("%.0f%%", 100 * count / n)
}

# Per-bin tag counts for the dated questions inside the window, in date
# order. Undated questions have no x position, so the chart skips them;
# the legend still counts them. Bins are days, weeks, or months -- the
# finest unit whose bins hold `target` answers on average -- so a sparse
# store charts a few honest aggregates rather than a per-day sawtooth of
# one-answer days swinging between 0% and 100%.
trust_timeline_bins <- function(questions, window = NULL, target = 5) {
  dates <- record_dates(questions)
  keep <- !is.na(dates)
  if (length(window) >= 2) {
    keep <- keep & dates >= window[[1]] & dates <= window[[2]]
  }
  questions <- questions[keep]
  dates <- dates[keep]

  bounds <- timeline_bounds(window, dates)
  unit <- timeline_bin_unit(dates, bounds, target)
  starts <- timeline_bin_start(dates, unit)
  bins <- lapply(sort(unique(starts)), function(start) {
    tags <- vapply(
      questions[starts == start],
      function(record) record$tag,
      character(1)
    )
    list(
      # A bin the window enters midway charts at the window's edge, not at
      # a calendar boundary outside it.
      date = format(max(start, bounds[[1]]), "%Y-%m-%d"),
      label = timeline_bin_label(start, unit, bounds),
      n = length(tags),
      counts = tag_counts(tags)
    )
  })
  list(unit = unit, bins = bins)
}

# The range the bins must respect: the picker's range when complete,
# otherwise the dated answers' own extent.
timeline_bounds <- function(window, dates) {
  if (length(window) >= 2) {
    return(as.Date(c(window[[1]], window[[2]])))
  }
  if (length(dates) == 0) {
    return(NULL)
  }
  c(min(dates), max(dates))
}

# The finest unit whose bins hold `target` answers on average --
# multiplication rather than mean() so zero dates stay on the day unit
# instead of dividing by zero. Units the window doesn't span at least a
# couple of times over aren't considered at all: a one-day selection
# charts that day however few answers it holds, never its whole month.
# When nothing reaches the target, the coarsest unit still in play.
timeline_bin_unit <- function(dates, bounds, target) {
  if (is.null(bounds)) {
    return("day")
  }
  span <- as.integer(bounds[[2]] - bounds[[1]]) + 1L
  units <- c("day", if (span >= 14) "week", if (span >= 60) "month")
  for (unit in units) {
    bins <- unique(timeline_bin_start(dates, unit))
    if (length(dates) >= target * length(bins)) {
      return(unit)
    }
  }
  units[[length(units)]]
}

# Weeks start on Monday (ISO), months on the first.
timeline_bin_start <- function(dates, unit) {
  switch(
    unit,
    day = dates,
    week = dates - (as.integer(format(dates, "%u")) - 1L),
    month = as.Date(format(dates, "%Y-%m-01"))
  )
}

# Bin labels never reach outside the window: a week or month the window
# covers only part of labels itself by the days it actually holds
# ("Jul 2-5, 2026"), and only a fully covered month wears its plain name.
timeline_bin_label <- function(start, unit, bounds) {
  if (identical(unit, "day")) {
    return(day_label(start))
  }
  end <- if (identical(unit, "week")) {
    start + 6
  } else {
    seq(start, by = "1 month", length.out = 2)[[2]] - 1
  }
  from <- max(start, bounds[[1]])
  to <- min(end, bounds[[2]])
  if (identical(unit, "month") && from == start && to == end) {
    return(format(start, "%B %Y"))
  }
  timeline_range_label(from, to)
}

timeline_range_label <- function(from, to) {
  day <- function(date) sub("^\\s+", "", format(date, "%e"))
  if (from == to) {
    day_label(from)
  } else if (identical(format(from, "%Y-%m"), format(to, "%Y-%m"))) {
    sprintf(
      "%s %s\u2013%s, %s",
      format(from, "%b"),
      day(from),
      day(to),
      format(from, "%Y")
    )
  } else if (identical(format(from, "%Y"), format(to, "%Y"))) {
    sprintf(
      "%s %s \u2013 %s %s, %s",
      format(from, "%b"),
      day(from),
      format(to, "%b"),
      day(to),
      format(from, "%Y")
    )
  } else {
    sprintf(
      "%s %s, %s \u2013 %s %s, %s",
      format(from, "%b"),
      day(from),
      format(from, "%Y"),
      format(to, "%b"),
      day(to),
      format(to, "%Y")
    )
  }
}

# The table is the same data as the chart, readable without a pointer, and
# is where screen readers land instead of the drawing: role="img" on the
# plot's wrapper keeps plotly's internals out of the accessibility tree.
trust_timeline <- function(binned) {
  if (length(binned$bins) == 0) {
    return(viewer_empty_note("No dated questions in this date range."))
  }
  htmltools::div(
    class = "commons-viewer-timeline",
    htmltools::div(
      class = "commons-viewer-timeline-plot",
      role = "img",
      `aria-label` = sprintf(
        "Chart of the share of answers at each trust level by %s.
         The values appear in the table that follows.",
        binned$unit
      ),
      timeline_plot(binned$bins, binned$unit)
    ),
    timeline_table(binned$bins)
  )
}

# A 100%-stacked area chart of each bin's trust-level shares -- one stacked
# column when only one bin is dated, since a single point can't make an
# area. The tooltip is one card drawn wholly from per-bin text -- unified
# hover's date header can't carry the bin's n beside the date -- and every
# trace carries the same card: with closest-point hover, the label then
# anchors to whichever band boundary sits nearest the pointer instead of
# always to the chart's top edge. The card header's legend names the
# levels, so the widget's own legend stays off.
timeline_plot <- function(bins, unit) {
  dates <- as.Date(vapply(bins, function(bin) bin$date, character(1)))
  n <- vapply(bins, function(bin) bin$n, numeric(1))
  # The card's HTML rides in the hovertemplate itself rather than behind a
  # %{text} reference: a lone bin's length-1 text unboxes to a scalar in
  # the widget JSON, which plotly.js leaves unsubstituted.
  tooltips <- paste0(
    vapply(bins, timeline_tooltip, character(1)),
    "<extra></extra>"
  )
  plot <- plotly::plot_ly(height = 176)

  for (k in seq_along(viewer_levels)) {
    key <- names(viewer_levels)[[k]]
    counts <- vapply(bins, function(bin) bin$counts[[key]], numeric(1))
    shares <- 100 * counts / n
    plot <- if (length(bins) == 1) {
      plotly::add_bars(
        plot,
        x = dates,
        y = shares,
        name = unname(viewer_levels[[key]]),
        hovertemplate = tooltips,
        marker = list(color = viewer_level_colors[[key]]),
        # About two hours wide, in the date axis's milliseconds; with the
        # axis pinned a day either side, a column rather than a fill.
        width = 7200000
      )
    } else {
      plotly::add_trace(
        plot,
        x = dates,
        y = shares,
        name = unname(viewer_levels[[key]]),
        hovertemplate = tooltips,
        # Anchor to the boundary lines' points; fills would hover at a
        # polygon centroid instead.
        hoveron = "points",
        type = "scatter",
        mode = "lines",
        stackgroup = "levels",
        fillcolor = viewer_level_colors[[key]],
        # The surface-colored boundary line is the 2px gap keeping
        # neighboring bands apart; the top band's boundary is the chart's
        # edge and draws nothing.
        line = list(
          color = "#ffffff",
          width = if (k == length(viewer_levels)) 0 else 2
        )
      )
    }
  }

  # Ticks sit on dated bins themselves rather than plotly's auto ticks,
  # which land on empty dates between them and wrap into two lines ("Jul 2"
  # over "2026") that the bottom margin can't fit: up to seven bins, always
  # including the first and last, as single-line labels.
  ticks <- unique(round(seq(
    1,
    length(dates),
    length.out = min(length(dates), 7)
  )))

  plot <- plotly::layout(
    plot,
    barmode = "stack",
    # Closest-point hover with no pixel cutoff: the card fires anywhere in
    # the fills and anchors to the nearest band boundary at the nearest
    # bin, pointing at the band under the cursor rather than the top edge.
    hovermode = "closest",
    hoverdistance = -1,
    hoverlabel = list(
      align = "left",
      bgcolor = "#ffffff",
      bordercolor = "#dee2e6",
      font = list(size = 12, color = "#212529")
    ),
    showlegend = FALSE,
    margin = list(t = 8, r = 12, b = 22, l = 40),
    paper_bgcolor = "transparent",
    plot_bgcolor = "transparent",
    font = list(size = 11, color = "#6c757d"),
    xaxis = list(
      title = FALSE,
      type = "date",
      showgrid = FALSE,
      fixedrange = TRUE,
      # Hovering draws a spike line down to the axis by default; the
      # tooltip alone is enough.
      showspikes = FALSE,
      tickvals = as.list(format(dates[ticks])),
      ticktext = as.list(format(
        dates[ticks],
        if (identical(unit, "month")) "%b %Y" else "%b %e"
      )),
      # A lone bin gives autorange nothing but the column's own edges to
      # work with, so it would stretch the column across the card.
      range = if (length(bins) == 1) as.list(format(dates + c(-1, 1)))
    ),
    yaxis = list(
      title = FALSE,
      range = c(0, 100),
      tickvals = c(0, 50, 100),
      ticksuffix = "%",
      gridcolor = "#dee2e6",
      zeroline = FALSE,
      fixedrange = TRUE
    )
  )
  plotly::config(plot, displayModeBar = FALSE, responsive = TRUE)
}

# One bin's hover card, in plotly's pseudo-HTML: the bin and its answer
# count on the header line, then a swatch row per level in legend order.
# The swatches are colored text glyphs -- plotly hover text supports
# color via span styles, but no real markup.
timeline_tooltip <- function(bin) {
  rows <- vapply(
    names(viewer_levels),
    function(key) {
      sprintf(
        "<span style=\"color: %s\">\u25a0</span> <b>%s</b> %s",
        viewer_level_colors[[key]],
        rate_percent(bin$counts[[key]], bin$n),
        viewer_levels[[key]]
      )
    },
    character(1)
  )
  paste(
    c(sprintf("<b>%s</b>  (n = %d)", bin$label, bin$n), rows),
    collapse = "<br>"
  )
}

timeline_table <- function(bins) {
  rows <- lapply(bins, function(bin) {
    htmltools::tags$tr(
      htmltools::tags$td(bin$label),
      lapply(names(viewer_levels), function(key) {
        htmltools::tags$td(sprintf(
          "%s (%d)",
          rate_percent(bin$counts[[key]], bin$n),
          bin$counts[[key]]
        ))
      }),
      htmltools::tags$td(bin$n)
    )
  })
  htmltools::tags$table(
    class = "commons-viewer-sr-only",
    htmltools::tags$caption("Trust levels over time"),
    htmltools::tags$thead(htmltools::tags$tr(
      htmltools::tags$th("Date"),
      lapply(unname(viewer_levels), htmltools::tags$th),
      htmltools::tags$th("Answers")
    )),
    htmltools::tags$tbody(rows)
  )
}
