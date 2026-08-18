#' Review commons trajectories
#'
#' @description
#' `trajectory_review()` launches a Shiny app for browsing conversation
#' trajectories read with [trajectory_read()]. The app charts each trust
#' level's share of answers over time—binned by day, week, or month, using
#' the finest unit the volume of answers supports—alongside a list of
#' conversations or of individual questions, filterable by date and trust
#' level. The transcript reconstructs each answer's recorded Commons
#' presentation: accepted citations appear inline at their original locations,
#' A/C provenance appears after the answer, and rejected citation attempts
#' appear in a separate "Review audit" aside.
#'
#' Transcripts are reviewable rather than live: conversations and questions
#' can be flagged for review and annotated with notes. Notes apply to the
#' whole conversation, or to a single question-and-answer exchange selected
#' in the transcript. Flags and notes are stored as one generated Markdown
#' document per reviewed conversation and are restored when the viewer
#' reopens.
#'
#' Each Markdown document contains the complete reviewer-visible conversation
#' and its tool activity. YAML frontmatter stores active flags and note history
#' so the reviewer can restore its state and agents can identify flagged
#' conversations, exchanges, and reviewer notes. The Markdown body is the
#' human-readable transcript for joint human-agent review. Search-pool results
#' are omitted because later tool calls record any selected measure; other tool
#' results are limited to 50 lines or 20,000 characters.
#'
#' Each answer's trust tag and citation outcomes are read back exactly as
#' [trajectory_read()] recorded them. The viewer uses those decisions to
#' reconstruct Commons citation asides from the raw ellmer answer; it never
#' re-verifies citations against a corpus. Missing or conflicting records are
#' omitted rather than inferred.
#'
#' Logged calls that aren't part of the agent's question-and-answer record—
#' shinychat's conversation-title generation, and completions with no user
#' turn—are excluded from the viewer.
#'
#' @param trajectories A named list of conversations, as returned by
#'   [trajectory_read()].
#' @param review_dir Optional directory where review actions write generated
#'   Markdown documents. Defaults to `COMMONS_REVIEW_DIR` when set and
#'   otherwise to `commons-reviews` in the working directory.
#'
#' @details
#' A single reviewer app writes all review documents to `review_dir`. Pass it
#' directly, set `COMMONS_REVIEW_DIR` for the current R process with
#' `Sys.setenv()`, or add it to `.Renviron` to keep the setting across local R
#' sessions. Without either, reviews land in `commons-reviews` relative to the
#' app's working directory.
#'
#' Files in a Posit Connect app's working directory are replaced on
#' redeployment. Review apps should use one Connect process because separate
#' processes do not coordinate file writes or in-memory review state.
#'
#' All sessions of one reviewer app share the same flags and notes; review
#' state is not separated by user. Notes record `session$user`, the login
#' information supplied by the Shiny host, or `"unknown"` when it is
#' unavailable. Flags do not record who changed them.
#'
#' @return A [shiny::shinyApp()] object. Calling `trajectory_review()` at the
#'   console launches the reviewer; the result can also be served as the last
#'   expression of an `app.R`.
#'
#' @examples
#' \dontrun{
#' trajectory_review()
#'
#' trajectory_review(trajectory_read(from = "2026-07-01"))
#'
#' Sys.setenv(COMMONS_REVIEW_DIR = "/path/to/persistent/reviews")
#' trajectory_review()
#' }
#' @export
trajectory_review <- function(
  trajectories = trajectory_read(),
  review_dir = NULL
) {
  check_viewer_packages()
  check_trajectories(trajectories)
  review_dir <- resolve_review_dir(review_dir)
  trajectories <- drop_side_conversations(trajectories)
  summary <- summarize_trajectories(trajectories)
  questions <- summarize_questions(trajectories)
  shiny::shinyApp(
    viewer_ui(summary),
    viewer_server(trajectories, summary, questions, review_dir)
  )
}

check_viewer_packages <- function(call = rlang::caller_env()) {
  pkgs <- c(
    "bslib",
    "htmltools",
    "plotly",
    "shiny",
    "shinychat",
    "yaml"
  )
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
       by {.fn trajectory_read}: each a list of {.cls ellmer::Turn}s.",
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

# Title generation shares the agent's client, so its calls enter the trace
# store.
shinychat_title_prompt <- "You title chat conversations."

is_side_conversation <- function(turns) {
  if (length(split_exchanges(turns)) == 0) {
    return(TRUE)
  }
  system <- turns[[1]]
  identical(system@role, "system") &&
    startsWith(system@text, shinychat_title_prompt)
}

summarize_trajectories <- function(trajectories) {
  unname(Map(conversation_record, names(trajectories), trajectories))
}

conversation_record <- function(id, turns) {
  exchanges <- split_exchanges(turns)
  provenance <- lapply(
    attr(turns, "provenance") %||% list(),
    exchange_provenance
  )
  list(
    id = id,
    snippet = first_user_snippet(exchanges),
    n_user_turns = length(exchanges),
    tags = vapply(provenance, function(p) p$tag, character(1)),
    last_active = attr(turns, "last_active") %||% as.POSIXct(NA)
  )
}

summarize_questions <- function(trajectories) {
  records <- list()
  for (i in rlang::seq2(1, length(trajectories))) {
    turns <- trajectories[[i]]
    exchanges <- split_exchanges(turns)
    provenance <- lapply(
      attr(turns, "provenance") %||% list(),
      exchange_provenance
    )
    for (j in rlang::seq2(1, length(exchanges))) {
      records[[length(records) + 1]] <- list(
        conversation = i,
        conversation_id = names(trajectories)[[i]],
        exchange = j,
        snippet = question_snippet(exchanges[[j]]),
        tag = (provenance[j][[1]] %||% list(tag = NA_character_))$tag,
        last_active = attr(turns, "last_active") %||% as.POSIXct(NA)
      )
    }
  }
  records
}

# trajectory_read() attaches one recorded provenance entry per reconstructed
# exchange. Review rendering consumes that audit record rather than re-deriving
# trust from message text.
exchange_provenance <- function(record) {
  list(tag = record$provenance_tag)
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

trajectory_transcript <- function(turns) {
  exchanges <- split_exchanges(turns)
  records <- attr(turns, "provenance") %||% list()
  messages <- list()

  for (i in seq_along(exchanges)) {
    exchange <- exchanges[[i]]
    messages[[length(messages) + 1]] <- list(
      role = "user",
      content = exchange[[1]]@text,
      exchange = i
    )
    record <- records[i][[1]] %||% empty_turn_provenance()
    chunks <- exchange_answer_chunks(
      exchange[-1],
      record$citation_decisions
    )
    if (length(chunks) == 0) {
      next
    }
    chip <- exchange_chip(record)
    if (!is.null(chip)) {
      chunks[[length(chunks) + 1]] <- chip
    }
    messages[[length(messages) + 1]] <- list(
      role = "assistant",
      content = chunks,
      exchange = i
    )
  }

  list(messages = messages)
}

exchange_chip <- function(record) {
  pieces <- c(
    provenance_aside(record$provenance_tag %||% NA_character_),
    review_audit_aside(record$citation_decisions)
  )
  pieces <- pieces[nzchar(pieces)]
  if (length(pieces) == 0) {
    return(NULL)
  }
  paste(pieces, collapse = "\n\n")
}

review_audit_aside <- function(decisions) {
  rejected <- sum(vapply(
    decisions,
    function(decision) {
      is.list(decision) && identical(decision$status, "rejected")
    },
    logical(1)
  ))
  if (rejected == 0) {
    return("")
  }
  sprintf(
    '<shiny-aside label="Review audit">%d citation%s rejected.</shiny-aside>',
    rejected,
    if (rejected == 1) "" else "s"
  )
}

# Reviewer badges and transcript asides share provenance_display so their copy,
# icon, and meaning cannot drift.
commons_answer_pill <- function(tag) {
  entry <- provenance_display[[tag]]
  if (is.null(entry)) {
    return(NULL)
  }
  htmltools::tags$span(
    class = paste0(
      "commons-answer-pill commons-answer-pill-",
      entry$pill_class
    ),
    title = entry$body,
    `aria-label` = paste0(entry$label, ". ", entry$body),
    tabindex = "0",
    commons_pill_icon(entry$icon, entry$label),
    htmltools::tags$span(entry$label),
    commons_pill_tooltip(entry$body)
  )
}

commons_pill_tooltip <- function(text) {
  htmltools::tags$span(class = "commons-tooltip", role = "tooltip", text)
}

commons_pill_icon <- function(file, alt) {
  if (is.null(file)) {
    return(NULL)
  }
  src <- svg_data_uri(file)
  if (is.null(src)) {
    return(NULL)
  }

  htmltools::tags$img(
    src = src,
    alt = alt,
    class = "commons-answer-pill-icon"
  )
}

exchange_answer_chunks <- function(turns, decisions) {
  chunks <- list()
  resolver <- recorded_citation_resolver(decisions)
  scanner <- citation_scanner(resolve = resolver$resolve)

  append_text <- function(text) {
    if (nzchar(text)) {
      chunks[[length(chunks) + 1]] <<-
        shinychat::contents_shinychat(ellmer::ContentText(text))
    }
  }
  reset_text_scanner <- function() {
    append_text(scanner$finish())
    scanner <<- citation_scanner(resolve = resolver$resolve)
  }

  for (turn in turns) {
    for (content in turn@contents) {
      if (S7::S7_inherits(content, ellmer::ContentText)) {
        append_text(scanner$feed(content@text))
        next
      }

      reset_text_scanner()
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
  append_text(scanner$finish())
  drop_nulls(chunks)
}

# Rebuild display metadata that is not retained by the OTLP round trip.
viewer_tool_display <- function(request, value = NULL) {
  if (is.null(request)) {
    return(NULL)
  }
  arguments <- request@arguments
  info <- switch(
    request@name,
    search_pool = list(title = "Found a trusted calculation", icon = "search"),
    call_metrics = list(
      title = sprintf(
        "Ran a trusted calculation: %s",
        html_escape(paste(unlist(arguments$metrics), collapse = ", "))
      ),
      icon = "shield-check"
    ),
    call_measure = list(
      title = sprintf(
        "Ran a trusted calculation: %s",
        html_escape(humanize_name(arguments$name %||% ""))
      ),
      icon = "shield-check"
    ),
    search_context = list(title = "Searched context", icon = "book"),
    describe_table = list(
      title = sprintf("Inspected %s", html_escape(arguments$table %||% "")),
      icon = "table"
    ),
    run_sql = list(title = "Grabbed data", icon = "code-square"),
    run_r = list(title = "Analyzed data", icon = "terminal"),
    return(NULL)
  )
  display <- list(title = info$title, open = FALSE, show_request = FALSE)
  display$icon <- maybe_icon(info$icon)
  if (identical(request@name, "run_sql") && is.character(arguments$sql)) {
    display$markdown <- paste(
      c(sprintf("```sql\n%s\n```", arguments$sql), value),
      collapse = "\n\n"
    )
  }
  display
}

seed_transcript_decorations <- function(
  session,
  id,
  transcript,
  selected_exchange = NULL
) {
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

viewer_ui <- function(summary) {
  dates <- viewer_date_range(summary)
  htmltools::attachDependencies(
    bslib::page_sidebar(
      title = "Trajectory reviewer",
      sidebar = bslib::sidebar(
        width = 380,
        class = "commons-viewer-sidebar",
        bslib::navset_underline(
          id = "group_by",
          bslib::nav_panel("Conversations", value = "conversation"),
          bslib::nav_panel("Questions", value = "question")
        ),
        shiny::dateRangeInput(
          "window",
          "Dates",
          start = dates$min,
          end = dates$max,
          min = dates$min,
          max = dates$max
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
        bslib::layout_sidebar(
          shiny::uiOutput("transcript", fill = TRUE),
          sidebar = bslib::sidebar(
            htmltools::div(
              class = "commons-viewer-review-pane",
              shiny::uiOutput("review_bar"),
              shiny::conditionalPanel(
                "output.review_ready === 'ready'",
                bslib::input_submit_textarea(
                  "review_note",
                  placeholder = "Add a note",
                  width = "100%",
                  button = htmltools::tags$button(
                    type = "button",
                    class = "btn commons-viewer-note-submit",
                    title = "Add note",
                    `aria-label` = "Add note",
                    maybe_icon("arrow-up") %||% "\u2191"
                  ),
                  submit_key = "enter"
                ),
                class = "commons-viewer-note-compose"
              )
            ),
            position = "right",
            width = 320,
            padding = 0,
            resizable = TRUE
          ),
          border = FALSE,
          border_radius = FALSE,
          padding = 0,
          gap = 0
        )
      )
    ),
    c(
      # Match the dependency order used by a live commons chat.
      htmltools::findDependencies(shinychat::chat_ui("commons_viewer_probe")),
      list(commons_chat_dependency(), commons_viewer_dependency())
    )
  )
}

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
  review_dir
) {
  # Share review state across sessions in the documented single process.
  review_state <- read_review_state(review_dir)
  app_flags <- shiny::reactiveVal(review_state$flags)
  app_notes <- shiny::reactiveVal(review_state$notes)

  function(input, output, session) {
    flags <- app_flags
    notes <- app_notes
    selected <- shiny::reactiveVal(NULL)
    selected_transcript <- shiny::reactive({
      key <- selected()
      if (is.null(key)) {
        return(NULL)
      }
      trajectory_transcript(trajectories[[key$conversation]])
    })
    review_target <- shiny::reactiveVal(NULL)
    review_selection <- shiny::reactive({
      review_target() %||% selected()["conversation"]
    })
    user <- review_user(session)

    output$review_ready <- shiny::renderText({
      if (is.null(review_selection())) "" else "ready"
    })
    shiny::outputOptions(output, "review_ready", suspendWhenHidden = FALSE)

    shiny::observeEvent(
      review_selection(),
      ignoreNULL = FALSE,
      {
        key <- review_selection()
        placeholder <- if (is.null(key)) {
          "Add a note"
        } else if (is.null(key$exchange)) {
          "Add a note about this conversation"
        } else {
          "Add a note about this exchange"
        }
        bslib::update_submit_textarea(
          "review_note",
          value = "",
          placeholder = placeholder,
          session = session
        )
      }
    )

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

    # Register once because filtering does not change trajectory indices.
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

    output$review_bar <- shiny::renderUI({
      key <- review_selection()
      if (is.null(key)) {
        return(NULL)
      }
      flagged <- selection_review_key(key, summary) %in% flags()
      review_bar_notes(
        key,
        flagged,
        notes_for_selection(notes(), key, summary)
      )
    })

    shiny::observeEvent(input$flag_toggle, {
      key <- review_selection()
      if (is.null(key)) {
        return()
      }
      review <- selection_review_key(key, summary)
      flagged <- review %in% flags()
      next_flags <- if (flagged) {
        setdiff(flags(), review)
      } else {
        union(flags(), review)
      }
      write_conversation_review(
        review_dir,
        trajectories,
        key$conversation,
        next_flags,
        notes()
      )
      flags(next_flags)
    })

    shiny::observeEvent(input$exchange_select, {
      navigation <- selected()
      if (is.null(navigation)) {
        return()
      }
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

    shiny::observeEvent(input$review_note, {
      key <- review_selection()
      note <- trimws(input$review_note %||% "")
      if (is.null(key) || !nzchar(note)) {
        return()
      }
      next_notes <- c(
        notes(),
        list(new_review_note(trajectories, key, user, note))
      )
      write_conversation_review(
        review_dir,
        trajectories,
        key$conversation,
        flags(),
        next_notes
      )
      notes(next_notes)
      bslib::update_submit_textarea(
        "review_note",
        value = "",
        focus = TRUE,
        session = session
      )
    })

    # A fresh id prevents stale pill timers from targeting a new transcript.
    output$transcript <- shiny::renderUI({
      key <- selected()
      if (is.null(key)) {
        return(viewer_empty_note(
          "Select a conversation to view its transcript."
        ))
      }
      commons_ui(
        transcript_id(key),
        messages = selected_transcript()$messages,
        height = "100%"
      )
    })

    # Seed decorations only after the new chat element is bound in the browser.
    shiny::observeEvent(selected(), {
      key <- selected()
      transcript <- selected_transcript()
      session$onFlushed(
        function() {
          seed_transcript_decorations(
            session,
            transcript_id(key),
            transcript,
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
    review_note_list(notes)
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

note_date <- function(note) {
  time <- parse_review_time(note$time %||% "")
  if (is.na(time)) {
    return(NULL)
  }
  attr(time, "tzone") <- ""
  htmltools::div(class = "commons-viewer-note-meta", day_label(time))
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

entry_date <- function(record) {
  time <- record$last_active
  if (is.na(time)) {
    return(NULL)
  }
  sprintf(
    "%s %s",
    day_label(time),
    sub("^0", "", format(time, "%I:%M %p"))
  )
}

viewer_empty_note <- function(text) {
  htmltools::div(class = "commons-viewer-empty", text)
}

in_window <- function(record, window) {
  if (length(window) < 2) {
    return(TRUE)
  }
  date <- local_date(record$last_active)
  is.na(date) || (date >= window[[1]] && date <= window[[2]])
}

viewer_date_range <- function(summary) {
  dates <- record_dates(summary)
  dates <- dates[!is.na(dates)]
  if (length(dates) == 0) {
    return(list(min = Sys.Date(), max = Sys.Date()))
  }
  list(min = min(dates), max = max(dates))
}

record_dates <- function(records) {
  as.Date(vapply(
    records,
    function(record) as.character(local_date(record$last_active)),
    character(1)
  ))
}

# as.Date.POSIXct() defaults to UTC rather than the reviewer's local day.
local_date <- function(time) {
  as.Date(format(time, "%Y-%m-%d"))
}

day_label <- function(date) {
  gsub("\\s+", " ", format(date, "%b %e, %Y"))
}

# Asset mtimes invalidate browser caches during package development.
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
