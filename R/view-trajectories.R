#' View commons trajectories
#'
#' @description
#' `view_trajectories()` launches a Shiny app for browsing conversation
#' trajectories read with [read_trajectories()]. The app shows the rate of
#' each trust level across conversations, a conversation list that can be
#' filtered by date, and a read-only transcript of each conversation with the
#' provenance pills the commons chat UI would show.
#'
#' Trajectories carry no record of how each answer was tagged when it was
#' produced, so the viewer derives trust levels from the tool calls in the
#' trajectory: answers backed only by governed tools (`call_measure`,
#' `call_metrics`) are verified, and answers that used fallback tools
#' (`run_sql`, `run_r`) count as cited when they contain citation markup and
#' untrusted when they don't. Citation quotes are not re-verified against the
#' agent's context.
#'
#' @param trajectories A named list of conversations, as returned by
#'   [read_trajectories()].
#'
#' @return A [shiny::shinyApp()] object. Calling `view_trajectories()` at the
#'   console launches the viewer; the result can also be served as the last
#'   expression of an `app.R`.
#'
#' @examples
#' \dontrun{
#' view_trajectories()
#'
#' view_trajectories(read_trajectories(from = "2026-07-01"))
#' }
#' @export
view_trajectories <- function(trajectories = read_trajectories()) {
  check_viewer_packages()
  check_trajectories(trajectories)
  summary <- summarize_trajectories(trajectories)
  shiny::shinyApp(viewer_ui(summary), viewer_server(trajectories, summary))
}

check_viewer_packages <- function(call = rlang::caller_env()) {
  pkgs <- c("bslib", "htmltools", "shiny", "shinychat")
  missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]

  if (length(missing)) {
    cli::cli_abort(
      c(
        "{.fn view_trajectories} requires missing package{?s}: {.pkg {missing}}.",
        i = "Install {.pkg {missing}} to use the trajectory viewer."
      ),
      call = call
    )
  }
}

check_trajectories <- function(trajectories, call = rlang::caller_env()) {
  ok <- is.list(trajectories) &&
    (length(trajectories) == 0 || !is.null(names(trajectories))) &&
    all(vapply(trajectories, is.list, logical(1)))

  if (!ok) {
    cli::cli_abort(
      "{.arg trajectories} must be a named list of conversations as returned
       by {.fn read_trajectories}: each a list of {.cls ellmer::Turn}s.",
      call = call
    )
  }
}

# Summaries ---------------------------------------------------------------

# One record per conversation, in input order. A plain list of records
# rather than a data frame: the app maps over conversations anyway.
summarize_trajectories <- function(trajectories) {
  unname(Map(conversation_record, names(trajectories), trajectories))
}

conversation_record <- function(id, turns) {
  exchanges <- split_exchanges(turns)
  provenance <- lapply(exchanges, exchange_provenance)
  list(
    id = id,
    snippet = first_user_snippet(exchanges),
    n_user_turns = length(exchanges),
    tags = vapply(provenance, function(p) p$tag, character(1)),
    last_active = attr(turns, "last_active") %||% as.POSIXct(NA)
  )
}

# The viewer re-derives what runtime tagging stores in extra$commons_tag --
# dropped by the OTLP round trip -- from the tool-call names that survive
# it. B vs C is decided by citation *presence*: with no agent there is no
# corpus to verify quotes against.
trajectory_provenance <- function(turns) {
  lapply(split_exchanges(turns), exchange_provenance)
}

exchange_provenance <- function(exchange) {
  tags <- exchange_tool_tags(exchange)
  text <- unlist(lapply(exchange, turn_text)) %||% character()
  citations <- extract_citations(text)
  tag <- if ("B" %in% tags) {
    if (length(citations) > 0) "B" else "C"
  } else if ("A" %in% tags) {
    "A"
  } else {
    NA_character_
  }
  list(tag = tag, citations = citations)
}

viewer_tool_tags <- c(
  call_measure = "A",
  call_metrics = "A",
  run_sql = "B",
  run_r = "B"
)

# Tags come from tool requests rather than results: reconstructed histories
# always pair them, and a request never depends on the result's back-pointer
# having been re-linked.
exchange_tool_tags <- function(turns) {
  calls <- unlist(lapply(turns, function(turn) {
    lapply(turn@contents, function(content) {
      if (S7::S7_inherits(content, ellmer::ContentToolRequest)) {
        content@name
      }
    })
  }))
  tags <- viewer_tool_tags[calls]
  unname(tags[!is.na(tags)])
}

first_user_snippet <- function(exchanges, max_chars = 80) {
  if (length(exchanges) == 0) {
    return("")
  }
  text <- trimws(gsub("\\s+", " ", exchanges[[1]][[1]]@text))
  if (nchar(text) <= max_chars) {
    return(text)
  }
  paste0(substr(text, 1, max_chars - 1), "…")
}

# Exchange-level counts of each trust level across a set of conversations'
# tag vectors.
hit_rate <- function(tag_sets) {
  tags <- unlist(tag_sets) %||% character()
  list(
    n = length(tags),
    counts = c(
      A = sum(tags %in% "A"),
      B = sum(tags %in% "B"),
      C = sum(tags %in% "C"),
      none = sum(is.na(tags))
    )
  )
}

# Transcripts -------------------------------------------------------------

# A conversation as shinychat-ready messages plus the pill-seed payload for
# the commonsProvenancePillSeed handler (see commons-chat.js). One user
# message per exchange opener; the rest of each exchange merges into one
# assistant message whose chunks are markdown strings and tool-result cards.
# Tool requests are dropped, mirroring shinychat's own transcript restore
# (each result card carries its request). `count` and `indexFromEnd` index
# assistant messages, which is what the seed handler counts.
trajectory_transcript <- function(turns) {
  exchanges <- split_exchanges(turns)
  messages <- list()
  pills <- list()
  n_assistant <- 0L

  for (exchange in exchanges) {
    messages[[length(messages) + 1]] <- list(
      role = "user",
      content = exchange[[1]]@text
    )
    chunks <- exchange_answer_chunks(exchange[-1])
    if (length(chunks) == 0) {
      next
    }
    n_assistant <- n_assistant + 1L
    messages[[length(messages) + 1]] <- list(
      role = "assistant",
      content = chunks
    )
    pill <- viewer_pill(exchange_provenance(exchange), n_assistant)
    if (!is.null(pill)) {
      pills[[length(pills) + 1]] <- pill
    }
  }

  for (i in seq_along(pills)) {
    pills[[i]]$indexFromEnd <- n_assistant - pills[[i]]$indexFromEnd
  }
  list(messages = messages, count = n_assistant, pills = pills)
}

# Exchanges whose tag is NA and whose answer attempted no citations need
# neither a pill nor citation cleanup. Cited ("B") answers send an empty
# pill: the client still strips their <citation> markup before finding no
# pill to place. All citations go over unverified, so none become footnotes.
viewer_pill <- function(provenance, assistant_index) {
  if (is.na(provenance$tag) && length(provenance$citations) == 0) {
    return(NULL)
  }
  list(
    html = htmltools::renderTags(commons_answer_pill(provenance$tag))$html,
    citations = lapply(provenance$citations, function(x) list(verified = FALSE)),
    indexFromEnd = assistant_index
  )
}

exchange_answer_chunks <- function(turns) {
  chunks <- list()
  for (turn in turns) {
    for (content in turn@contents) {
      if (S7::S7_inherits(content, ellmer::ContentToolRequest)) {
        next
      }
      chunks[[length(chunks) + 1]] <- shinychat::contents_shinychat(content)
    }
  }
  drop_nulls(chunks)
}

# Replays a conversation into a bound chat element. Assistant messages
# stream as chunks -- the mode the pill-seed handler was designed around --
# and the seed is sent last so pills land once the transcript settles.
restore_transcript <- function(session, id, turns) {
  transcript <- trajectory_transcript(turns)
  for (message in transcript$messages) {
    if (identical(message$role, "user")) {
      shinychat::chat_append_message(id, message, chunk = FALSE, session = session)
      next
    }
    shinychat::chat_append_message(
      id,
      list(role = "assistant", content = ""),
      chunk = "start",
      session = session
    )
    for (chunk in message$content) {
      shinychat::chat_append_message(
        id,
        list(role = "assistant", content = chunk),
        chunk = TRUE,
        session = session
      )
    }
    shinychat::chat_append_message(
      id,
      list(role = "assistant", content = ""),
      chunk = "end",
      session = session
    )
  }
  if (length(transcript$pills) > 0) {
    session$sendCustomMessage(
      "commonsProvenancePillSeed",
      list(id = id, count = transcript$count, pills = transcript$pills)
    )
  }
}

# App ---------------------------------------------------------------------

viewer_ui <- function(summary) {
  dates <- viewer_date_range(summary)
  htmltools::attachDependencies(
    bslib::page_sidebar(
      title = "Conversations",
      sidebar = bslib::sidebar(
        width = 380,
        shiny::dateRangeInput(
          "window",
          "Active between",
          start = dates$min,
          end = dates$max,
          min = dates$min,
          max = dates$max
        ),
        shiny::uiOutput("conversations")
      ),
      shiny::uiOutput("hit_rate"),
      bslib::card(
        fill = TRUE,
        class = "commons-viewer-transcript",
        shiny::uiOutput("transcript", fill = TRUE)
      )
    ),
    list(commons_chat_dependency(), commons_viewer_dependency())
  )
}

viewer_server <- function(trajectories, summary) {
  function(input, output, session) {
    selected <- shiny::reactiveVal(NULL)

    visible <- shiny::reactive({
      window <- input$window
      Filter(
        function(i) in_window(summary[[i]], window),
        seq_along(summary)
      )
    })

    output$hit_rate <- shiny::renderUI({
      hit_rate_boxes(hit_rate(lapply(visible(), function(i) summary[[i]]$tags)))
    })

    output$conversations <- shiny::renderUI({
      indices <- visible()
      if (length(indices) == 0) {
        return(viewer_empty_note(if (length(summary) == 0) {
          "No conversations to view."
        } else {
          "No conversations in this date range."
        }))
      }
      lapply(indices, function(i) {
        conversation_entry(i, summary[[i]], selected = identical(selected(), i))
      })
    })

    # Entry ids index into `trajectories`, which never changes, so observers
    # registered once stay valid as the date filter re-renders the list.
    for (i in seq_along(trajectories)) {
      local({
        index <- i
        shiny::observeEvent(input[[paste0("conversation_", index)]], {
          selected(index)
        })
      })
    }

    # A fresh chat element per selection: a superseded pill-seed timer from a
    # fast conversation switch then targets a defunct element id and dies
    # harmlessly instead of racing the new transcript.
    output$transcript <- shiny::renderUI({
      i <- selected()
      if (is.null(i)) {
        return(viewer_empty_note("Select a conversation to view its transcript."))
      }
      commons_ui(paste0("transcript_", i), height = "100%")
    })

    # onFlushed fires after the flush that delivers the new chat element, so
    # it is bound client-side before the replayed messages arrive -- the same
    # mechanism commons_server() uses to seed pills.
    shiny::observeEvent(selected(), {
      i <- selected()
      session$onFlushed(
        function() {
          restore_transcript(session, paste0("transcript_", i), trajectories[[i]])
        },
        once = TRUE
      )
    })
  }
}

viewer_levels <- c(
  A = "Verified",
  B = "Cited",
  C = "Untrusted",
  none = "No data tool"
)

hit_rate_boxes <- function(rate) {
  boxes <- lapply(names(viewer_levels), function(key) {
    bslib::value_box(
      title = viewer_levels[[key]],
      value = rate_percent(rate$counts[[key]], rate$n),
      htmltools::p(sprintf("%d of %d answers", rate$counts[[key]], rate$n))
    )
  })
  do.call(bslib::layout_columns, c(boxes, list(fill = FALSE)))
}

rate_percent <- function(count, n) {
  if (n == 0) {
    return("—")
  }
  sprintf("%.0f%%", 100 * count / n)
}

conversation_entry <- function(index, record, selected = FALSE) {
  pills <- lapply(intersect(c("A", "C"), record$tags), commons_answer_pill)
  shiny::actionLink(
    paste0("conversation_", index),
    class = if (selected) {
      "commons-viewer-entry commons-viewer-entry-selected"
    } else {
      "commons-viewer-entry"
    },
    label = htmltools::tagList(
      htmltools::div(class = "commons-viewer-entry-snippet", record$snippet),
      htmltools::div(
        class = "commons-viewer-entry-meta",
        htmltools::tags$span(entry_meta(record)),
        pills
      )
    )
  )
}

entry_meta <- function(record) {
  turns <- sprintf(
    "%d %s",
    record$n_user_turns,
    if (record$n_user_turns == 1) "turn" else "turns"
  )
  date <- local_date(record$last_active)
  if (is.na(date)) {
    return(turns)
  }
  sprintf("%s · %s", turns, format(date, "%b %e, %Y"))
}

viewer_empty_note <- function(text) {
  htmltools::div(class = "commons-viewer-empty", text)
}

# Conversations without a timestamp always pass the date filter.
in_window <- function(record, window) {
  date <- local_date(record$last_active)
  is.na(date) ||
    ((is.na(window[[1]]) || date >= window[[1]]) &&
      (is.na(window[[2]]) || date <= window[[2]]))
}

# The date filter's bounds; when no conversation carries a timestamp, both
# collapse to today and the filter is inert (NA times always pass).
viewer_date_range <- function(summary) {
  dates <- as.Date(vapply(
    summary,
    function(record) as.character(local_date(record$last_active)),
    character(1)
  ))
  dates <- dates[!is.na(dates)]
  if (length(dates) == 0) {
    return(list(min = Sys.Date(), max = Sys.Date()))
  }
  list(min = min(dates), max = max(dates))
}

# as.Date() on a POSIXct reads it in UTC; the viewer filters and displays
# calendar days in the reader's local time.
local_date <- function(time) {
  as.Date(format(time, "%Y-%m-%d"))
}

# Asset mtimes ride in the version so the dependency URL changes whenever
# the files do; browsers otherwise cache edited assets under the stable
# version's URL indefinitely.
commons_viewer_dependency <- function() {
  src <- system.file("www", "commons-viewer", package = "commons")
  stamp <- max(file.mtime(list.files(src, full.names = TRUE)))

  htmltools::htmlDependency(
    name = "commons-viewer",
    version = paste0("0.0.0.9000.", as.integer(stamp)),
    src = c(file = src),
    stylesheet = "commons-viewer.css"
  )
}
