#' Review commons trajectories
#'
#' @description
#' `trajectory_review()` launches a Shiny app for browsing conversation
#' trajectories read with [read_trajectories()]. The app charts each trust
#' level's share of answers over time—binned by day, week, or month, using
#' the finest unit the volume of answers supports—alongside a list of
#' conversations or of individual questions, filterable by date and trust
#' level, and a transcript of each with the provenance pills the commons
#' chat UI would show.
#'
#' Transcripts are reviewable rather than live: conversations and questions
#' can be flagged for review and annotated with notes. Notes apply to the
#' whole conversation, or to a single question-and-answer exchange selected
#' in the transcript. Flags and notes land in `review_file`, one JSON record
#' per line, and are restored when the viewer reopens.
#'
#' New review records use schema version 1 and include a unique event id, UTC
#' timestamp, reviewer username, trajectory source, conversation id, optional
#' exchange number, action, and optional note. Exchange-level records also
#' snapshot the question and trust tag. [trajectory_reviews_read()] reduces
#' the event log to its active flags and notes and can join them back to the
#' reviewed turns.
#'
#' Trajectories carry no record of how each answer was tagged when it was
#' produced, so the viewer derives trust levels from the tool calls in the
#' trajectory: answers backed only by governed tools (`call_measure`,
#' `call_metrics`) are verified, and answers that used fallback tools
#' (`run_sql`, `run_r`) count as cited when they contain citation markup and
#' untrusted when they don't. A cited answer's quotes render as footnotes so
#' they can be reviewed, but they are not re-verified against the agent's
#' context: footnotes name no source and are attributed "unverified".
#'
#' Logged calls that aren't part of the agent's question-and-answer record—
#' shinychat's conversation-title generation, and completions with no user
#' turn—are excluded from the viewer.
#'
#' @param trajectories A named list of conversations, as returned by
#'   [read_trajectories()].
#' @param review_file Path of the JSONL file that review actions append to:
#'   flags, unflags, and feedback notes, each with a timestamp, the
#'   conversation id, and (for questions) the exchange number. Created on
#'   first use; flags and notes recorded here are restored when the viewer
#'   reopens. Defaults to `COMMONS_REVIEW_FILE` when set.
#'
#' @details
#' A single reviewer app writes all of its review events to `review_file`. For a
#' deployed app, point `COMMONS_REVIEW_FILE` at persistent storage: files in a
#' Posit Connect app's working directory are replaced on redeployment.
#' File-backed review apps should use one Connect process because separate
#' processes do not coordinate file writes or in-memory review state.
#'
#' @return A [shiny::shinyApp()] object. Calling `trajectory_review()` at the
#'   console launches the reviewer; the result can also be served as the last
#'   expression of an `app.R`.
#'
#' @examples
#' \dontrun{
#' trajectory_review()
#'
#' trajectory_review(read_trajectories(from = "2026-07-01"))
#' }
#' @export
trajectory_review <- function(
  trajectories = read_trajectories(),
  review_file = Sys.getenv(
    "COMMONS_REVIEW_FILE",
    unset = "commons-review.jsonl"
  )
) {
  check_viewer_packages()
  check_trajectories(trajectories)
  rlang::check_string(review_file)
  source <- trajectory_source(trajectories)
  trajectories <- drop_side_conversations(trajectories)
  summary <- summarize_trajectories(trajectories)
  questions <- summarize_questions(trajectories)
  shiny::shinyApp(
    viewer_ui(summary),
    viewer_server(trajectories, summary, questions, review_file, source)
  )
}

check_viewer_packages <- function(call = rlang::caller_env()) {
  pkgs <- c("bslib", "htmltools", "plotly", "shiny", "shinychat", "shinyWidgets")
  missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]

  if (length(missing)) {
    cli::cli_abort(
      c(
        "{.fn trajectory_review} requires missing package{?s}: {.pkg {missing}}.",
        i = "Install {.pkg {missing}} to use the trajectory reviewer."
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

drop_side_conversations <- function(trajectories) {
  side <- vapply(trajectories, is_side_conversation, logical(1))
  if (any(side)) {
    cli::cli_inform(
      "Excluding {sum(side)} logged call{?s} that {?isn't/aren't} part of the
       agent's Q&A record (e.g. conversation-title generation)."
    )
  }
  trajectories[!side]
}

# shinychat's conversation-title generation rides a clone of the agent's own
# client, so its calls land in the trace store looking like one-question
# conversations; match its system prompt (shinychat's TITLE_SYSTEM_PROMPT)
# by prefix. Completions with no plain user turn have no question to review
# and are side calls of one kind or another.
shinychat_title_prompt <- "You title chat conversations."

is_side_conversation <- function(turns) {
  if (length(split_exchanges(turns)) == 0) {
    return(TRUE)
  }
  system <- turns[[1]]
  identical(system@role, "system") &&
    startsWith(system@text, shinychat_title_prompt)
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

# One record per question -> answer exchange across all conversations, in
# conversation order.
summarize_questions <- function(trajectories) {
  records <- list()
  for (i in rlang::seq2(1, length(trajectories))) {
    turns <- trajectories[[i]]
    exchanges <- split_exchanges(turns)
    provenance <- lapply(exchanges, exchange_provenance)
    for (j in rlang::seq2(1, length(exchanges))) {
      records[[length(records) + 1]] <- list(
        conversation = i,
        conversation_id = names(trajectories)[[i]],
        exchange = j,
        snippet = question_snippet(exchanges[[j]]),
        tag = provenance[[j]]$tag,
        last_active = attr(turns, "last_active") %||% as.POSIXct(NA)
      )
    }
  }
  records
}

# The viewer re-derives what runtime tagging stores in extra$commons_tag --
# dropped by the OTLP round trip -- from the tool-call names that survive
# it. B vs C is decided by citation *presence*: with no agent there is no
# corpus to verify quotes against.
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
  question_snippet(exchanges[[1]], max_chars)
}

question_snippet <- function(exchange, max_chars = 80) {
  text <- trimws(gsub("\\s+", " ", exchange[[1]]@text))
  if (nchar(text) <= max_chars) {
    return(text)
  }
  paste0(substr(text, 1, max_chars - 1), "\u2026")
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

  for (i in seq_along(exchanges)) {
    exchange <- exchanges[[i]]
    messages[[length(messages) + 1]] <- list(
      role = "user",
      content = exchange[[1]]@text,
      exchange = i
    )
    chunks <- exchange_answer_chunks(exchange[-1])
    if (length(chunks) == 0) {
      next
    }
    n_assistant <- n_assistant + 1L
    messages[[length(messages) + 1]] <- list(
      role = "assistant",
      content = chunks,
      exchange = i
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
# pill and their citations render as numbered footnotes, so a reviewer can
# read what the answer quoted; citations on other answers are stripped, as
# at runtime.
viewer_pill <- function(provenance, assistant_index) {
  if (is.na(provenance$tag) && length(provenance$citations) == 0) {
    return(NULL)
  }
  citations <- if (identical(provenance$tag, "B")) {
    lapply(provenance$citations, viewer_citation)
  } else {
    lapply(provenance$citations, function(x) list(verified = FALSE))
  }
  list(
    html = htmltools::renderTags(commons_answer_pill(provenance$tag))$html,
    citations = citations,
    indexFromEnd = assistant_index
  )
}

# Mirrors citations_payload() in chat.R, but for quotes the viewer can't
# check against a corpus: the footnote attributes the quote to "unverified"
# rather than naming a source.
viewer_citation <- function(citation) {
  list(
    verified = TRUE,
    reason = if (!is.na(citation$reason)) citation$reason,
    quote = normalize_citation(citation$quote),
    label = "unverified"
  )
}

exchange_answer_chunks <- function(turns) {
  chunks <- list()
  for (turn in turns) {
    for (content in turn@contents) {
      if (S7::S7_inherits(content, ellmer::ContentToolRequest)) {
        next
      }
      if (S7::S7_inherits(content, ellmer::ContentToolResult)) {
        content@extra$display <- content@extra$display %||%
          viewer_tool_display(content@request, content@value)
      }
      chunks[[length(chunks) + 1]] <- shinychat::contents_shinychat(content)
    }
  }
  drop_nulls(chunks)
}

# Runtime tool results carry display metadata (tool_result()'s
# extra$display: the quiet row's title and icon) that the OTLP round trip
# drops, so reconstructed results would fall back to shinychat's default
# card under the raw function name. Re-derive it from the request's tool
# name and arguments, mirroring the titles in tools.R; runtime-only detail
# (source labels, measure display HTML) is beyond reconstruction. Unknown
# tools keep the default card.
viewer_tool_display <- function(request, value = NULL) {
  if (is.null(request)) {
    return(NULL)
  }
  arguments <- request@arguments
  info <- switch(
    request@name,
    search_pool = list(title = "Searched the semantic layer", icon = "search"),
    call_metrics = list(
      title = sprintf(
        "Metrics: %s",
        html_escape(paste(unlist(arguments$metrics), collapse = ", "))
      ),
      icon = "shield-check"
    ),
    call_measure = list(
      title = sprintf(
        "Measure: %s",
        html_escape(humanize_name(arguments$name %||% ""))
      ),
      icon = "shield-check"
    ),
    search_context = list(title = "Searched context", icon = "book"),
    describe_table = list(
      title = sprintf("Described %s", html_escape(arguments$table %||% "")),
      icon = "table"
    ),
    run_sql = list(title = "Ran SQL", icon = "code-square"),
    run_r = list(title = "Ran R code", icon = "terminal"),
    return(NULL)
  )
  display <- list(title = info$title, open = FALSE, show_request = FALSE)
  display$icon <- maybe_icon(info$icon)
  # Expanding a SQL row shows the query above its result, as at runtime.
  if (identical(request@name, "run_sql") && is.character(arguments$sql)) {
    display$markdown <- paste(
      c(sprintf("```sql\n%s\n```", arguments$sql), value),
      collapse = "\n\n"
    )
  }
  display
}

# Replays a conversation into a bound chat element. Assistant messages
# stream as chunks -- the mode the pill-seed handler was designed around --
# and the seed is sent last so pills land once the transcript settles.
restore_transcript <- function(
  session,
  id,
  turns,
  selected_exchange = NULL
) {
  transcript <- trajectory_transcript(turns)
  for (message in transcript$messages) {
    if (identical(message$role, "user")) {
      shinychat::chat_append_message(
        id,
        message,
        chunk = FALSE,
        session = session
      )
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
  if (length(transcript$messages) > 0) {
    session$sendCustomMessage(
      "commonsViewerExchangeSeed",
      list(
        id = id,
        count = length(transcript$messages),
        exchanges = vapply(
          transcript$messages,
          function(message) message$exchange,
          integer(1)
        ),
        selected = selected_exchange
      )
    )
  }
}

# App ---------------------------------------------------------------------

viewer_ui <- function(summary) {
  dates <- viewer_date_range(summary)
  htmltools::attachDependencies(
    bslib::page_sidebar(
      title = "Trajectory reviewer",
      sidebar = bslib::sidebar(
        width = 380,
        class = "commons-viewer-sidebar",
        # The navset is purely a switcher: its panels are empty, and the
        # selected value arrives as input$group_by.
        bslib::navset_underline(
          id = "group_by",
          bslib::nav_panel("Conversations", value = "conversation"),
          bslib::nav_panel("Questions", value = "question")
        ),
        shinyWidgets::airDatepickerInput(
          "window",
          "Dates",
          range = TRUE,
          value = c(dates$min, dates$max),
          minDate = dates$min,
          maxDate = dates$max,
          dateFormat = "MMM d, yyyy",
          update_on = "close",
          addon = "none",
          # With toggling on, clicking the range's start date a second time
          # deselects it, making a one-day window unreachable.
          toggleSelected = FALSE
        ),
        shiny::selectInput(
          "trust",
          "Trust Level",
          trust_choices("conversation")
        ),
        shiny::uiOutput("entries")
      ),
      trust_timeline_card(),
      bslib::card(
        fill = TRUE,
        class = "commons-viewer-transcript",
        htmltools::div(
          class = "commons-viewer-workspace",
          htmltools::div(
            class = "commons-viewer-transcript-pane",
            shiny::uiOutput("transcript", fill = TRUE)
          ),
          htmltools::div(
            class = "commons-viewer-pane-resizer",
            role = "separator",
            `aria-orientation` = "vertical",
            `aria-label` = "Resize the notes pane",
            tabindex = "0"
          ),
          htmltools::div(
            class = "commons-viewer-review-pane",
            shiny::uiOutput("review_bar")
          )
        )
      )
    ),
    c(
      # In a live commons app, commons-chat.css loads after shinychat's
      # stylesheet and wins its specificity ties -- the quiet tool rows,
      # among others. Here the chat is dynamically rendered, which would
      # deliver shinychat's sheet last; pinning it into the head restores
      # the live app's order, so transcripts wear the same styling.
      htmltools::findDependencies(shinychat::chat_ui("commons_viewer_probe")),
      list(commons_chat_dependency(), commons_viewer_dependency())
    )
  )
}

# In conversation view the trust filter keeps conversations *containing* a
# matching answer; the option labels say so.
trust_choices <- function(group_by) {
  if (identical(group_by, "question")) {
    c(
      "All answers" = "all",
      "Verified" = "A",
      "Cited" = "B",
      "Untrusted" = "C",
      "No data tool" = "none"
    )
  } else {
    c(
      "All conversations" = "all",
      "Has a verified answer" = "A",
      "Has a cited answer" = "B",
      "Has an untrusted answer" = "C",
      "Has an answer with no data tool" = "none"
    )
  }
}

viewer_server <- function(
  trajectories,
  summary,
  questions,
  review_file,
  source = trajectory_source(trajectories)
) {
  function(input, output, session) {
    selected <- shiny::reactiveVal(NULL)
    review_target <- shiny::reactiveVal(NULL)
    review_records <- read_review_records(review_file)
    flags <- shiny::reactiveVal(review_flags(review_records))
    notes <- shiny::reactiveVal(review_notes(review_records))
    user <- review_user(session)

    shiny::observeEvent(input$group_by, {
      shiny::updateSelectInput(
        session,
        "trust",
        choices = trust_choices(input$group_by),
        selected = input$trust
      )
    })

    visible_conversations <- shiny::reactive({
      Filter(
        function(i) {
          conversation_visible(summary[[i]], input$window, input$trust)
        },
        seq_along(summary)
      )
    })

    visible_questions <- shiny::reactive({
      Filter(
        function(k) question_visible(questions[[k]], input$window, input$trust),
        seq_along(questions)
      )
    })

    # The timeline reflects the date window but not the trust filter: it
    # charts the trust distribution the filter slices. The legend's entry
    # tooltips carry the window's overall rates -- including undated
    # answers, which the per-bin bands can't place.
    output$timeline_legend <- shiny::renderUI({
      in_dates <- Filter(
        function(i) in_window(summary[[i]], input$window),
        seq_along(summary)
      )
      timeline_legend(hit_rate(lapply(in_dates, function(i) summary[[i]]$tags)))
    })

    output$timeline <- shiny::renderUI({
      trust_timeline(trust_timeline_bins(questions, input$window))
    })

    output$entries <- shiny::renderUI({
      entries <- if (identical(input$group_by, "question")) {
        lapply(
          visible_questions(),
          function(k) question_entry(questions[[k]], selected(), flags())
        )
      } else {
        lapply(
          visible_conversations(),
          function(i) conversation_entry(i, summary[[i]], selected(), flags())
        )
      }
      if (length(entries) == 0) {
        return(viewer_empty_note(
          if (length(summary) == 0) {
            "No conversations to view."
          } else {
            "Nothing matches these filters."
          }
        ))
      }
      entries
    })

    # Entry and transcript ids index into `trajectories`, which never
    # changes, so observers registered once stay valid as the filters
    # re-render the list.
    all_keys <- c(
      lapply(seq_along(trajectories), function(i) list(conversation = i)),
      lapply(questions, function(record) record[c("conversation", "exchange")])
    )
    for (key in all_keys) {
      local({
        k <- key
        shiny::observeEvent(input[[entry_link_id(k)]], {
          selected(k)
          review_target(if (is.null(k$exchange)) NULL else k)
        })
      })
    }

    # With no exchange selected the pane works at conversation level: the
    # flag and any notes cover the whole conversation. The fallback strips
    # any exchange from the navigation key, so deselecting an exchange
    # lands at conversation level from a question entry too.
    output$review_bar <- shiny::renderUI({
      key <- review_target() %||% selected()["conversation"]
      if (is.null(key)) {
        return(NULL)
      }
      flagged <- selection_review_key(key, summary) %in% flags()
      review_bar_notes(key, flagged, notes_for_selection(notes(), key, summary))
    })

    shiny::observeEvent(input$flag_toggle, {
      key <- review_target() %||% selected()["conversation"]
      review <- selection_review_key(key, summary)
      flagged <- review %in% flags()
      record <- new_review_event(
        trajectories,
        key,
        action = if (flagged) "unflag" else "flag",
        user = user,
        source = source
      )
      append_review_record(review_file, record)
      flags(if (flagged) setdiff(flags(), review) else union(flags(), review))
    })

    shiny::observeEvent(input$exchange_select, {
      navigation <- selected()
      if (is.null(navigation)) {
        return()
      }
      # A null exchange is the client deselecting (clicking the selected
      # exchange again).
      exchange <- as.integer(input$exchange_select$exchange)
      if (length(exchange) != 1 || is.na(exchange)) {
        review_target(NULL)
        return()
      }
      if (
        !exchange %in%
          seq_along(split_exchanges(trajectories[[navigation$conversation]]))
      ) {
        return()
      }
      review_target(list(
        conversation = navigation$conversation,
        exchange = exchange
      ))
    })

    # The transcript highlight follows review_target wherever it changes --
    # including deselection by re-clicking the current entry -- so the
    # client never shows a selection the review pane has dropped. Echoing a
    # client-initiated selection back is harmless: re-applying it sends no
    # input, and a message racing a fresh transcript finds no element and
    # dies quietly (the exchange seed carries that state instead).
    shiny::observeEvent(
      review_target(),
      ignoreNULL = FALSE,
      ignoreInit = TRUE,
      {
        key <- selected()
        if (is.null(key)) {
          return()
        }
        target <- review_target()
        session$sendCustomMessage(
          "commonsViewerExchangeSelect",
          list(
            id = transcript_id(key),
            exchange = if (!is.null(target)) target$exchange
          )
        )
      }
    )

    shiny::observeEvent(input$save_note, {
      key <- review_target() %||% selected()["conversation"]
      note <- trimws(input$review_note %||% "")
      if (is.null(key) || !nzchar(note)) {
        return()
      }
      record <- new_review_event(
        trajectories,
        key,
        action = "note",
        user = user,
        source = source,
        note = note
      )
      append_review_record(review_file, record)
      notes(c(notes(), list(record)))
    })

    # A fresh chat element per selection: a superseded pill-seed timer from a
    # fast selection switch then targets a defunct element id and dies
    # harmlessly instead of racing the new transcript.
    output$transcript <- shiny::renderUI({
      key <- selected()
      if (is.null(key)) {
        return(viewer_empty_note(
          "Select a conversation to view its transcript."
        ))
      }
      commons_ui(transcript_id(key), height = "100%")
    })

    # onFlushed fires after the flush that delivers the new chat element, so
    # it is bound client-side before the replayed messages arrive -- the same
    # mechanism commons_server() uses to seed pills.
    # Question and conversation entries open the same thing -- the whole
    # conversation -- a question entry just arrives with its exchange
    # selected and scrolled into view.
    shiny::observeEvent(selected(), {
      key <- selected()
      session$onFlushed(
        function() {
          restore_transcript(
            session,
            transcript_id(key),
            trajectories[[key$conversation]],
            selected_exchange = key$exchange
          )
        },
        once = TRUE
      )
    })
  }
}

conversation_visible <- function(record, window, trust) {
  in_window(record, window) &&
    (identical(trust, "all") || any(tag_matches(record$tags, trust)))
}

question_visible <- function(record, window, trust) {
  in_window(record, window) && tag_matches(record$tag, trust)
}

tag_matches <- function(tags, trust) {
  switch(
    trust,
    all = rep(TRUE, length(tags)),
    none = is.na(tags),
    tags %in% trust
  )
}

entry_link_id <- function(key) {
  paste(c("entry", key$conversation, key$exchange), collapse = "_")
}

transcript_id <- function(key) {
  paste(c("transcript", key$conversation, key$exchange), collapse = "_")
}

# Review ------------------------------------------------------------------

# Without an exchange the pane annotates the whole conversation; selecting
# an exchange in the transcript scopes it to that question instead.
review_bar_notes <- function(key, flagged, notes) {
  whole_conversation <- is.null(key$exchange)
  htmltools::div(
    class = "commons-viewer-review",
    htmltools::div(
      class = "commons-viewer-review-bar",
      htmltools::tags$strong(
        if (whole_conversation) {
          "Notes"
        } else {
          sprintf("Notes for Question %d", key$exchange)
        }
      ),
      flag_button(flagged, whole_conversation)
    ),
    if (whole_conversation) {
      htmltools::div(
        class = "commons-viewer-review-prompt",
        "Notes here apply to the entire conversation. Select a question or
         answer in the transcript to add a note specific to that exchange."
      )
    },
    review_note_list(notes),
    htmltools::div(
      class = "commons-viewer-note-compose",
      shiny::textAreaInput(
        "review_note",
        NULL,
        placeholder = if (whole_conversation) {
          "Add a note about this conversation"
        } else {
          "Add a note about this exchange"
        },
        rows = 2,
        width = "100%"
      ),
      shiny::actionButton(
        "save_note",
        "Add note",
        class = "btn-sm btn-outline-secondary"
      )
    )
  )
}

review_note_list <- function(notes) {
  if (length(notes) == 0) {
    return(NULL)
  }
  htmltools::div(
    class = "commons-viewer-notes",
    lapply(notes, function(note) {
      htmltools::div(
        class = "commons-viewer-note",
        htmltools::div(class = "commons-viewer-note-text", note$note),
        note_date(note)
      )
    })
  )
}

# Notes date themselves the way list entries do; a record whose time doesn't
# parse (or predates timestamps) just goes undated.
note_date <- function(note) {
  time <- parse_review_time(note$time %||% "")
  if (is.na(time)) {
    return(NULL)
  }
  htmltools::div(
    class = "commons-viewer-note-meta",
    format(time, "%b %e, %Y")
  )
}

notes_for_selection <- function(notes, key, summary) {
  selection <- selection_review_key(key, summary)
  Filter(
    function(note) review_key(note$conversation, note$exchange) == selection,
    notes
  )
}

selection_review_key <- function(key, summary) {
  review_key(summary[[key$conversation]]$id, key$exchange)
}

# An icon-only toggle: the flag reads gray until flagged, then wears the
# same orange as the list markers. State also rides in the tooltip and
# aria-pressed, so it isn't conveyed by color alone.
flag_button <- function(flagged, whole_conversation) {
  what <- if (whole_conversation) "conversation" else "question"
  title <- if (flagged) {
    "Flagged for review \u2014 click to unflag"
  } else {
    sprintf("Flag this %s for review", what)
  }
  bslib::tooltip(
    shiny::actionButton(
      "flag_toggle",
      label = "\u2691",
      class = if (flagged) {
        "commons-viewer-flag-button commons-viewer-flag-button-on"
      } else {
        "commons-viewer-flag-button"
      },
      `aria-label` = title,
      `aria-pressed` = if (flagged) "true" else "false"
    ),
    title
  )
}

flag_marker <- function(flagged) {
  if (!flagged) {
    return(NULL)
  }
  htmltools::tags$span(
    class = "commons-viewer-flag",
    title = "Flagged for review",
    "\u2691"
  )
}

# Entries -----------------------------------------------------------------

viewer_levels <- c(
  A = "Verified",
  B = "Cited",
  C = "Untrusted",
  none = "No data tool"
)

rate_percent <- function(count, n) {
  if (n == 0) {
    return("\u2014")
  }
  sprintf("%.0f%%", 100 * count / n)
}

# Conversation entries carry no trust pills: a conversation mixes answers
# at different levels, which a single answer's badge misstates. The trust
# filter, the timeline, and the transcript's own pills carry that story.
conversation_entry <- function(
  index,
  record,
  selected = NULL,
  flags = character()
) {
  key <- list(conversation = index)
  shiny::actionLink(
    entry_link_id(key),
    class = entry_class(identical(selected, key)),
    label = htmltools::tagList(
      htmltools::div(class = "commons-viewer-entry-snippet", record$snippet),
      htmltools::div(
        class = "commons-viewer-entry-meta",
        flag_marker(review_key(record$id) %in% flags),
        htmltools::tags$span(conversation_meta(record))
      )
    )
  )
}

question_entry <- function(record, selected = NULL, flags = character()) {
  key <- record[c("conversation", "exchange")]
  flagged <- review_key(record$conversation_id, record$exchange) %in% flags
  shiny::actionLink(
    entry_link_id(key),
    class = entry_class(identical(selected, key)),
    label = htmltools::tagList(
      htmltools::div(class = "commons-viewer-entry-snippet", record$snippet),
      htmltools::div(
        class = "commons-viewer-entry-meta",
        flag_marker(flagged),
        htmltools::tags$span(entry_date(record)),
        commons_answer_pill(record$tag)
      )
    )
  )
}

entry_class <- function(selected) {
  if (selected) {
    "commons-viewer-entry commons-viewer-entry-selected"
  } else {
    "commons-viewer-entry"
  }
}

conversation_meta <- function(record) {
  turns <- sprintf(
    "%d %s",
    record$n_user_turns,
    if (record$n_user_turns == 1) "turn" else "turns"
  )
  date <- entry_date(record)
  if (is.null(date)) {
    return(turns)
  }
  sprintf("%s \u00b7 %s", turns, date)
}

# Entries stamp themselves with the local time as well as the date, so
# same-day conversations stay tellable apart in the list.
entry_date <- function(record) {
  time <- record$last_active
  if (is.na(time)) {
    return(NULL)
  }
  sprintf(
    "%s %s",
    format(time, "%b %e, %Y"),
    sub("^0", "", format(time, "%I:%M %p"))
  )
}

viewer_empty_note <- function(text) {
  htmltools::div(class = "commons-viewer-empty", text)
}

# Conversations without a timestamp always pass the date filter, as does
# everything while the picker holds less than a complete range.
in_window <- function(record, window) {
  if (length(window) < 2) {
    return(TRUE)
  }
  date <- local_date(record$last_active)
  is.na(date) || (date >= window[[1]] && date <= window[[2]])
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

# Timeline ------------------------------------------------------------------

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

# Per-bin tag counts for the dated questions inside the window, in date
# order. Undated questions have no x position, so the chart skips them;
# the legend still counts them. Bins are days, weeks, or months -- the
# finest unit whose bins hold `target` answers on average -- so a sparse
# store charts a few honest aggregates rather than a per-day sawtooth of
# one-answer days swinging between 0% and 100%.
trust_timeline_bins <- function(questions, window = NULL, target = 5) {
  dates <- as.Date(vapply(
    questions,
    function(record) as.character(local_date(record$last_active)),
    character(1)
  ))
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
      counts = list(
        A = sum(tags %in% "A"),
        B = sum(tags %in% "B"),
        C = sum(tags %in% "C"),
        none = sum(is.na(tags))
      )
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
    return(format(start, "%b %e, %Y"))
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
    format(from, "%b %e, %Y")
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
    stylesheet = "commons-viewer.css",
    script = "commons-viewer.js"
  )
}
