# Artifacts are Quarto documents the agent writes inside a <artifact>
# tag (see citation_scanner()) and changes with the edit_artifact tool. Each
# saved version is written to its own directory, which is ordinary Quarto
# source a user could deploy as it stands, and rendered in a sandboxed worker.

tool_edit_artifact <- function(private) {
  ellmer::tool(
    function(id, old_string, new_string, replace_all = FALSE) {
      artifact_edit(private$artifacts, id, old_string, new_string, replace_all)
    },
    paste(
      "Edit a document that already exists. Load the artifacts skill before",
      "you use this tool. This tool can't create a document: create one by",
      "writing it in a <artifact> tag in your reply. `old_string`",
      "must appear exactly once in the document's current source, unless",
      "`replace_all` is true; it is replaced with `new_string`.",
      "Edits can change the frontmatter. Each edit saves and renders a new",
      "version, and the result says whether it rendered. To rewrite most of a",
      "document, write the tag again with the same id instead."
    ),
    arguments = list(
      id = ellmer::type_string("The document's id."),
      old_string = ellmer::type_string(
        "Exact text to replace, with enough context to be unique."
      ),
      new_string = ellmer::type_string("The replacement text."),
      replace_all = ellmer::type_boolean(
        "Replace every occurrence of `old_string`.",
        required = FALSE
      )
    ),
    name = "edit_artifact",
    annotations = ellmer::tool_annotations(
      title = "Editing a document",
      icon = maybe_icon("file-earmark-text"),
      read_only_hint = FALSE
    )
  )
}

# --- the store -----------------------------------------------------------------

# `resolve_input(method, args)` answers a document's call to a `commons`
# method; the store never touches data sources itself.
new_artifact_store <- function(
  resolve_input,
  network = "none",
  protection = "sandbox"
) {
  store <- new.env(parent = emptyenv())
  store$artifacts <- new.env(parent = emptyenv())
  store$streams <- new.env(parent = emptyenv())
  # A closed stream or an edit can still be rendering when the chat is cleared.
  store$runs <- new.env(parent = emptyenv())
  store$root <- tempfile("commons-artifacts-")
  store$resolve_input <- resolve_input
  store$network <- network
  store$protection <- protection
  store$listener <- NULL
  store$link_input <- NULL
  store$reminders <- character()
  store
}

artifact_store_reset <- function(store) {
  for (key in ls(store$runs)) {
    artifact_run_cancel(store$runs[[key]])
  }
  store$artifacts <- new.env(parent = emptyenv())
  store$streams <- new.env(parent = emptyenv())
  store$reminders <- character()
  artifact_notify(store, list(type = "reset"))
  invisible(store)
}

artifact_notify <- function(store, event) {
  if (!is.null(store$listener)) {
    tryCatch(
      store$listener(event),
      error = function(err) cli::cli_warn(conditionMessage(err))
    )
  }
  invisible(NULL)
}

artifact_remind <- function(store, text) {
  store$reminders <- c(store$reminders, text)
  invisible(store)
}

take_artifact_reminders <- function(store) {
  if (is.null(store)) {
    return(list())
  }
  reminders <- store$reminders
  store$reminders <- character()
  lapply(
    reminders,
    function(text) {
      ContentTurnReminder(text = paste0("<reminder>", text, "</reminder>"))
    }
  )
}

# An artifact exists from the moment its tag opens, but only counts as a
# document once it has a version.
artifact_get <- function(store, id) {
  if (!rlang::is_string(id)) {
    return(NULL)
  }
  artifact <- store$artifacts[[id]]
  if (is.null(artifact) || length(artifact$versions) == 0) NULL else artifact
}

artifact_ensure <- function(store, id) {
  artifact <- store$artifacts[[id]]
  if (is.null(artifact)) {
    artifact <- new.env(parent = emptyenv())
    artifact$id <- id
    artifact$title <- id
    artifact$versions <- list()
    artifact$units <- list()
    artifact$html <- character()
    artifact$errors <- character()
    artifact$status <- "writing"
    assign(id, artifact, envir = store$artifacts)
  }
  artifact
}

artifact_latest_dir <- function(artifact) {
  artifact$versions[[length(artifact$versions)]]$dir
}

artifact_scan_handler <- function(store) {
  function(event) {
    switch(
      event$type,
      open = {
        artifact <- artifact_ensure(store, event$id)
        if (!is.null(store$streams[[event$id]])) {
          artifact_run_cancel(store$streams[[event$id]])
        }
        assign(event$id, new_artifact_run(store, artifact), envir = store$streams)
        store$streams[[event$id]]$source <- ""
        artifact_notify(store, event)
      },
      delta = {
        run <- store$streams[[event$id]]
        run$source <- paste0(run$source, event$text)
        artifact_run_update(run, run$source)
      },
      close = {
        run <- store$streams[[event$id]]
        rm(list = event$id, envir = store$streams)
        committed <- artifact_commit(
          store,
          event$id,
          event$title,
          event$body,
          run = run
        )
        if (!is.null(committed$error)) {
          artifact_remind(
            store,
            artifact_rejected_reminder(event$id, committed$error)
          )
          return("")
        }
        promises::then(committed$rendered, function(result) {
          if (run$cancelled || !identical(store$artifacts[[event$id]], run$artifact)) {
            return(NULL)
          }
          if (length(result$errors)) {
            artifact_remind(store, artifact_errors_reminder(
              event$id,
              committed$version,
              result$errors
            ))
          }
        })
        artifact_link_html(store, event$id)
      },
      error = {
        if (!is.null(event$id) && !is.null(store$streams[[event$id]])) {
          artifact_run_cancel(store$streams[[event$id]])
          rm(list = event$id, envir = store$streams)
        }
        artifact_notify(store, event)
        artifact_remind(store, artifact_scan_reminder(event))
      }
    )
  }
}

artifact_scan_reminder <- function(event) {
  what <- if (is.null(event$id)) {
    "A document"
  } else {
    sprintf("The document `%s`", event$id)
  }
  why <- switch(
    event$reason,
    malformed = paste(
      "had a malformed opening tag. Start it on its own line as",
      "`<artifact id=\"short-id\" title=\"Title\">`, with a",
      "lowercase id."
    ),
    too_long = "was too long.",
    unclosed = "was never closed with `</artifact>`."
  )
  paste(what, why, "It was not saved.")
}

artifact_rejected_reminder <- function(id, error) {
  sprintf(
    "The document `%s` was not saved: %s Fix it and write it again.",
    id,
    error
  )
}

artifact_errors_reminder <- function(id, version, errors) {
  sprintf(
    paste(
      "Version %d of the document `%s` ran with errors, which the user sees",
      "in the document. Fix them with edit_artifact.\n\n%s"
    ),
    version,
    id,
    paste0("- ", errors, collapse = "\n")
  )
}

# Validates and saves a version, then finishes running it: a streamed
# version's run has been going since its frontmatter arrived, and an edited
# one gets a new run that reuses outputs when its code is unchanged.
artifact_commit <- function(store, id, title, source, run = NULL) {
  doc <- tryCatch(
    parse_artifact_document(source),
    commons_artifact_invalid = function(cnd) cnd
  )
  if (inherits(doc, "condition")) {
    if (!is.null(run)) {
      artifact_run_cancel(run)
    }
    artifact_notify(store, list(
      type = "rejected",
      id = id,
      error = conditionMessage(doc)
    ))
    return(list(error = conditionMessage(doc)))
  }

  artifact <- artifact_ensure(store, id)
  artifact$title <- doc$frontmatter$title %||% title
  doc$frontmatter$title <- artifact$title
  version <- length(artifact$versions) + 1L
  dir <- file.path(store$root, id, paste0("v", version))
  artifact$versions[[version]] <- list(source = source, dir = dir)
  artifact_notify(store, list(
    type = "version",
    id = id,
    title = artifact$title,
    version = version
  ))

  rendered <- tryCatch(
    {
      run <- run %||% artifact_rerun(store, artifact, doc)
      artifact_run_finish(run, source)
    },
    error = function(err) {
      if (!is.null(run)) {
        artifact_run_cancel(run)
      }
      promises::promise_resolve(list(
        html = character(),
        errors = conditionMessage(err)
      ))
    }
  )
  rendered <- promises::then(rendered, function(result) {
    artifact_settle(store, artifact, version, doc, run, result)
  })
  list(version = version, rendered = rendered)
}

artifact_rerun <- function(store, artifact, doc) {
  run <- new_artifact_run(store, artifact)
  units <- artifact_units(segment_artifact_body(doc$body))
  signature <- function(units) lapply(units, `[`, c("kind", "text"))
  if (identical(signature(units), signature(artifact$units))) {
    run$units <- artifact$units
    run$queued <- length(units)
  }
  run
}

artifact_settle <- function(store, artifact, version, doc, run, result) {
  if (!is.null(run)) {
    artifact_run_unregister(run)
  }
  if (!identical(store$artifacts[[artifact$id]], artifact) ||
      (!is.null(run) && run$cancelled)) {
    return(result)
  }
  if (version == length(artifact$versions)) {
    artifact$html <- result$html
    artifact$errors <- result$errors
    artifact$status <- "ready"
    if (!is.null(run)) {
      artifact$units <- run$units
    }
  }
  dir <- artifact$versions[[version]]$dir
  write_artifact_dir(dir, doc)
  writeLines(
    artifact_document_html(artifact$title, result$html),
    file.path(dir, "report.html"),
    useBytes = TRUE
  )
  artifact_notify(store, list(
    type = "status",
    id = artifact$id,
    status = "ready",
    error = if (length(result$errors) && !length(result$html)) {
      result$errors[[1]]
    }
  ))
  result
}

artifact_edit <- function(
  store,
  id,
  old_string,
  new_string,
  replace_all = FALSE,
  call = rlang::caller_env()
) {
  artifact <- artifact_get(store, id)
  if (is.null(artifact)) {
    ids <- Filter(function(id) !is.null(artifact_get(store, id)), ls(store$artifacts))
    cli::cli_abort(
      c(
        "There is no document with id {.val {id}}.",
        i = if (length(ids)) "Documents in this conversation: {.val {ids}}.",
        i = paste(
          "To create a document, write it in a",
          "{.code <artifact>} tag in your reply."
        )
      ),
      call = call
    )
  }
  current <- artifact$versions[[length(artifact$versions)]]$source
  source <- apply_artifact_edit(
    current,
    old_string,
    new_string,
    replace_all,
    call = call
  )
  committed <- artifact_commit(store, id, artifact$title, source)
  if (!is.null(committed$error)) {
    cli::cli_abort(
      "The edit was not saved: {committed$error}",
      call = call
    )
  }
  promises::then(committed$rendered, function(result) {
    artifact_edit_result(store, artifact, committed$version, result)
  })
}

artifact_edit_result <- function(store, artifact, version, result) {
  if (!identical(store$artifacts[[artifact$id]], artifact)) {
    return(tool_result(
      "The conversation was cleared before the edit finished.",
      title = "Cancelled edit"
    ))
  }
  value <- sprintf("Saved version %d of `%s`.", version, artifact$id)
  if (length(result$errors)) {
    value <- paste0(
      value,
      " It ran with errors, which the user sees in the document:\n\n",
      paste0("- ", result$errors, collapse = "\n")
    )
  }
  tool_result(
    value,
    title = sprintf("Edited %s", artifact$title),
    icon = maybe_icon("file-earmark-text"),
    html = artifact_link_html(store, artifact$id, version)
  )
}

artifact_link_html <- function(store, id, version = NULL) {
  artifact <- artifact_get(store, id)
  version <- version %||% length(artifact$versions)
  sprintf(
    paste0(
      "<commons-artifact-link artifact=\"%s\" version=\"%d\"%s>",
      "%s \u00b7 v%d</commons-artifact-link>"
    ),
    escape_attr(id),
    version,
    if (is.null(store$link_input)) {
      ""
    } else {
      sprintf(" input=\"%s\"", escape_attr(store$link_input))
    },
    html_escape(artifact$title),
    version
  )
}

# --- documents -----------------------------------------------------------------

artifact_allowed_keys <- c("title", "subtitle", "date", "format")

parse_artifact_document <- function(source, call = rlang::caller_env()) {
  split <- split_artifact_source(source)
  if (is.null(split)) {
    artifact_invalid(
      "missing_frontmatter",
      "The document must start with YAML frontmatter between `---` lines.",
      call = call
    )
  }
  c(
    validate_artifact_frontmatter(split$yaml, call = call),
    list(body = split$body)
  )
}

# NULL until the frontmatter's closing `---` has arrived.
split_artifact_source <- function(source) {
  text <- sub("^(?:[ \t]*\n)+", "", gsub("\r\n", "\n", source), perl = TRUE)
  match <- regexec(
    "(?s)^---[ \t]*\n(?:(.*?)\n)??(?:---|\\.\\.\\.)[ \t]*(?:\n|$)",
    text,
    perl = TRUE
  )[[1]]
  if (match[[1]] == -1L) {
    return(NULL)
  }
  yaml <- if (attr(match, "match.length")[[2]] > 0) {
    substr(text, match[[2]], match[[2]] + attr(match, "match.length")[[2]] - 1L)
  } else {
    ""
  }
  list(
    yaml = yaml,
    body = substr(text, attr(match, "match.length")[[1]] + 1L, nchar(text))
  )
}

validate_artifact_frontmatter <- function(yaml_text, call = rlang::caller_env()) {
  front <- tryCatch(
    yaml::yaml.load(yaml_text, eval.expr = FALSE, handlers = yaml12_booleans()),
    error = function(err) err
  )
  if (inherits(front, "error")) {
    artifact_invalid(
      "invalid_yaml",
      "The frontmatter is not valid YAML: {conditionMessage(front)}",
      call = call
    )
  }
  front <- front %||% list()
  if (!is_mapping(front)) {
    artifact_invalid(
      "invalid_yaml",
      "The frontmatter must be a YAML mapping.",
      call = call
    )
  }

  disallowed <- setdiff(names(front), artifact_allowed_keys)
  if (length(disallowed)) {
    artifact_invalid(
      "disallowed_key",
      "The frontmatter may only set {.field {artifact_allowed_keys}}, not
       {.field {disallowed}}. The format, theme, and execution options are
       set for you.",
      call = call
    )
  }
  for (key in intersect(c("title", "subtitle", "date"), names(front))) {
    if (!rlang::is_string(front[[key]])) {
      artifact_invalid(
        "invalid_value",
        "The frontmatter's {.field {key}} must be text.",
        call = call
      )
    }
  }
  if (!is.null(front$format) && !identical(front$format, "html")) {
    artifact_invalid(
      "disallowed_format",
      "The frontmatter's {.field format} can only be {.val html}; its options are set
       for you.",
      call = call
    )
  }
  list(frontmatter = front)
}

apply_artifact_edit <- function(
  source,
  old_string,
  new_string,
  replace_all = FALSE,
  call = rlang::caller_env()
) {
  replace_all <- isTRUE(replace_all)
  n <- if (nzchar(old_string)) {
    lengths(regmatches(source, gregexpr(old_string, source, fixed = TRUE)))
  } else {
    0L
  }
  if (n == 0L) {
    artifact_invalid(
      "no_match",
      "{.arg old_string} does not appear in the document's current source.",
      call = call
    )
  }
  if (identical(old_string, new_string)) {
    artifact_invalid(
      "unchanged",
      "{.arg old_string} and {.arg new_string} are identical.",
      call = call
    )
  }
  if (n > 1L && !replace_all) {
    artifact_invalid(
      "multiple_matches",
      "{.arg old_string} appears {n} times. Include more context to make it
       unique, or set {.arg replace_all}.",
      call = call
    )
  }
  if (replace_all) {
    gsub(old_string, new_string, source, fixed = TRUE)
  } else {
    sub(old_string, new_string, source, fixed = TRUE)
  }
}

artifact_invalid <- function(slug, message, call = rlang::caller_env()) {
  cli::cli_abort(
    message,
    class = "commons_artifact_invalid",
    slug = slug,
    call = call,
    .envir = parent.frame()
  )
}

# YAML 1.1 reads `n`, `y`, `on`, and `off` as booleans, which would turn a
# subtitle of `On` into `TRUE`. Quarto reads YAML 1.2, where only true and
# false are.
yaml12_booleans <- function() {
  list(
    "bool#yes" = function(x) if (tolower(x) == "true") TRUE else x,
    "bool#no" = function(x) if (tolower(x) == "false") FALSE else x
  )
}

is_mapping <- function(x) {
  is.list(x) &&
    !is.data.frame(x) &&
    (length(x) == 0 || (!is.null(names(x)) && all(nzchar(names(x)))))
}

# --- the document's commons ----------------------------------------------------

# The methods a document's `commons` offers: the trusted calculations, and
# read-only SQL for what they don't cover.
artifact_commons_methods <- c("measure", "metrics", "calculation", "run_sql")

# Answers a document's `commons$<method>(...)` on the real commons. Requests
# come from the sandbox, so only plain values pass in and only tables and
# vectors pass out: a plot, for one, would carry its environment with it.
resolve_artifact_input <- function(commons, method, args) {
  if (!rlang::is_string(method) || !method %in% artifact_commons_methods) {
    cli::cli_abort(
      "Documents can call {.code commons${artifact_commons_methods}()} only.",
      call = NULL
    )
  }
  if (!is.list(args) || !is_plain_value(args)) {
    cli::cli_abort(
      "Arguments must be strings, numbers, or lists of them.",
      call = NULL
    )
  }
  value <- do.call(commons[[method]], args)
  if (identical(method, "measure")) {
    value <- artifact_measure_data(value)
  }
  if (is.data.frame(value)) {
    return(as.data.frame(value))
  }
  if (is.atomic(value) && !is.null(value) && is_plain_value(unclass(value))) {
    return(value)
  }
  cli::cli_abort(
    "It returned neither a table nor a value, which documents can't use.",
    call = NULL
  )
}

is_plain_value <- function(x) {
  if (!all(names(attributes(x)) %in% "names")) {
    return(FALSE)
  }
  if (is.null(x) || is.atomic(x)) {
    return(TRUE)
  }
  is.list(x) && all(vapply(x, is_plain_value, logical(1)))
}

# The data behind a measure's value, as call_measure registers it for run_r.
artifact_measure_data <- function(value) {
  if (S7::S7_inherits(value, ellmer::ContentToolResult)) {
    value <- if (is.null(value@error)) value@extra$data
  }
  value <- collect_lazy_table(value)
  if (is_gt_table(value)) {
    value <- recover_gt_table_data(value)
  }
  value
}

write_artifact_dir <- function(dir, doc) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  writeLines(artifact_quarto_yml(), file.path(dir, "_quarto.yml"))
  writeLines(
    artifact_qmd(doc$frontmatter, doc$body),
    file.path(dir, "report.qmd"),
    useBytes = TRUE
  )
  invisible(dir)
}

artifact_qmd <- function(frontmatter, body) {
  paste0("---\n", yaml::as.yaml(frontmatter), "---\n\n", body)
}

artifact_quarto_yml <- function() {
  c(
    "project:",
    "  type: default",
    "format:",
    "  html:",
    "    embed-resources: true",
    "    code-fold: true",
    "    code-summary: \"Code\"",
    "    df-print: kable",
    "    fontsize: 0.9em",
    "execute:",
    "  warning: false",
    "  message: false"
  )
}

# Outside a stream nothing projects the reply, so `$chat()` saves the
# documents in the turns it added after the fact and says where they were
# written.
save_turn_artifacts <- function(store, turns) {
  if (is.null(store)) {
    return(invisible())
  }
  committed <- list()
  on_artifact <- function(event) {
    if (identical(event$type, "close")) {
      committed[[length(committed) + 1L]] <<- c(
        list(id = event$id),
        artifact_commit(store, event$id, event$title, event$body)
      )
    }
    NULL
  }
  for (turn in Filter(function(x) S7::S7_inherits(x, ellmer::AssistantTurn), turns)) {
    scanner <- citation_scanner(on_artifact = on_artifact)
    scanner$feed(turn_text(turn))
    scanner$finish()
  }

  for (item in committed) {
    if (!is.null(item$error)) {
      artifact_remind(store, artifact_rejected_reminder(item$id, item$error))
      cli::cli_warn("Document {.val {item$id}} was not saved: {item$error}")
      next
    }
    result <- wait_for_promise(item$rendered)
    path <- file.path(
      artifact_latest_dir(artifact_get(store, item$id)),
      "report.html"
    )
    if (length(result$errors)) {
      artifact_remind(
        store,
        artifact_errors_reminder(item$id, item$version, result$errors)
      )
      cli::cli_warn(c(
        "Document {.val {item$id}} ran with errors; see {.file {path}}.",
        rlang::set_names(gsub("([{}])", "\\1\\1", result$errors), "x")
      ))
    } else {
      cli::cli_inform("Knitted {.val {item$id}} to {.file {path}}.")
    }
  }
  invisible()
}

turn_text <- function(turn) {
  texts <- Filter(function(x) S7::S7_inherits(x, ellmer::ContentText), turn@contents)
  paste(vapply(texts, function(x) x@text, character(1)), collapse = "")
}

wait_for_promise <- function(promise) {
  done <- FALSE
  value <- NULL
  promises::then(
    promise,
    function(result) {
      value <<- result
      done <<- TRUE
    },
    function(err) {
      value <<- list(error = conditionMessage(err))
      done <<- TRUE
    }
  )
  while (!done) {
    later::run_now(0.1)
  }
  value
}
