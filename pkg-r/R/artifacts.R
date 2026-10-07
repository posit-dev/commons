# Artifacts are Quarto documents the agent writes inside a <commons-artifact>
# tag (see citation_scanner()) and changes with the edit_artifact tool. Each
# saved version is written to its own directory, which is ordinary Quarto
# source a user could deploy as it stands, and rendered in a sandboxed worker.

tool_edit_artifact <- function(private) {
  ellmer::tool(
    function(id, old_string, new_string, replace_all = FALSE) {
      artifact_edit(private$artifacts, id, old_string, new_string, replace_all)
    },
    paste(
      "Edit a document you wrote in a <commons-artifact> tag. `old_string`",
      "must appear exactly once in the document's current source, unless",
      "`replace_all` is true; it is replaced with `new_string`. Edits can",
      "change the frontmatter. Each edit saves and renders a new version, and",
      "the result says whether it rendered. To rewrite most of a document,",
      "write the tag again with the same id instead."
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

# `resolve_input` runs one normalized input through its trusted path and
# returns the result; the store never touches data sources itself.
new_artifact_store <- function(
  resolve_input,
  network = "none",
  protection = "sandbox"
) {
  store <- new.env(parent = emptyenv())
  store$artifacts <- new.env(parent = emptyenv())
  store$root <- tempfile("commons-artifacts-")
  store$resolve_input <- resolve_input
  store$network <- network
  store$protection <- protection
  store$listener <- NULL
  store$link_input <- NULL
  store$reminders <- character()
  store$tail <- NULL
  store
}

artifact_store_reset <- function(store) {
  store$artifacts <- new.env(parent = emptyenv())
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
  reminders <- store$reminders
  store$reminders <- character()
  lapply(
    reminders,
    function(text) {
      ContentTurnReminder(text = paste0("<reminder>", text, "</reminder>"))
    }
  )
}

artifact_get <- function(store, id) {
  if (!rlang::is_string(id)) {
    return(NULL)
  }
  store$artifacts[[id]]
}

artifact_latest_dir <- function(artifact) {
  artifact$versions[[length(artifact$versions)]]$dir
}

# The scanner's artifact handler: forwards streaming events to the listener,
# commits a closed element, and returns the chip that replaces it in the chat.
artifact_scan_handler <- function(store) {
  function(event) {
    switch(
      event$type,
      open = ,
      delta = artifact_notify(store, event),
      close = {
        committed <- artifact_commit(store, event$id, event$title, event$body)
        if (!is.null(committed$error)) {
          artifact_remind(
            store,
            artifact_rejected_reminder(event$id, committed$error)
          )
          return("")
        }
        promises::then(committed$rendered, function(result) {
          if (!is.null(result$error)) {
            artifact_remind(store, artifact_render_reminder(
              event$id,
              committed$version,
              result$error
            ))
          }
        })
        artifact_link_html(store, event$id)
      },
      error = {
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
      "`<commons-artifact id=\"short-id\" title=\"Title\">`, with a",
      "lowercase id."
    ),
    too_long = "was too long.",
    unclosed = "was never closed with `</commons-artifact>`."
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

artifact_render_reminder <- function(id, version, error) {
  sprintf(
    paste(
      "Version %d of the document `%s` failed to render, so the user still",
      "sees the previous version. Fix it with edit_artifact.\n\n%s"
    ),
    version,
    id,
    error
  )
}

# Validate and save a new version, then render it. Returns the version and a
# promise for the render, or the reason the source was rejected.
artifact_commit <- function(store, id, title, source) {
  doc <- tryCatch(
    parse_artifact_document(source),
    commons_artifact_invalid = function(cnd) cnd
  )
  if (inherits(doc, "condition")) {
    artifact_notify(store, list(
      type = "rejected",
      id = id,
      error = conditionMessage(doc)
    ))
    return(list(error = conditionMessage(doc)))
  }

  artifact <- artifact_get(store, id)
  if (is.null(artifact)) {
    artifact <- new.env(parent = emptyenv())
    artifact$id <- id
    artifact$versions <- list()
    artifact$inputs <- list()
    artifact$html <- NULL
    artifact$html_version <- 0L
    assign(id, artifact, envir = store$artifacts)
  }
  artifact$title <- doc$frontmatter$title %||% title
  doc$frontmatter$title <- artifact$title
  version <- length(artifact$versions) + 1L
  dir <- file.path(store$root, id, paste0("v", version))
  artifact$versions[[version]] <- list(
    source = source,
    dir = dir,
    trusted = length(doc$inputs) > 0
  )
  artifact_notify(store, list(
    type = "version",
    id = id,
    title = artifact$title,
    version = version,
    trusted = length(doc$inputs) > 0,
    source = source
  ))

  rendered <- tryCatch(
    {
      data <- resolve_artifact_inputs(store, artifact, doc$inputs)
      write_artifact_dir(dir, doc, data)
      artifact_render_queued(store, dir)
    },
    error = function(err) {
      promises::promise_resolve(list(error = conditionMessage(err)))
    }
  )
  rendered <- promises::then(rendered, function(result) {
    artifact_settle(store, artifact, version, result)
  })
  list(version = version, rendered = rendered)
}

artifact_settle <- function(store, artifact, version, result) {
  if (is.null(result$error)) {
    if (version > artifact$html_version) {
      artifact$html <- result$html
      artifact$html_version <- version
    }
    artifact_notify(store, list(
      type = "rendered",
      id = artifact$id,
      version = version,
      html = result$html
    ))
  } else {
    artifact$failed_version <- version
    artifact$error <- result$error
    artifact_notify(store, list(
      type = "failed",
      id = artifact$id,
      version = version,
      error = result$error
    ))
  }
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
    ids <- ls(store$artifacts)
    cli::cli_abort(
      c(
        "There is no document with id {.val {id}}.",
        i = if (length(ids)) {
          "Documents in this conversation: {.val {ids}}."
        } else {
          "No documents have been written in this conversation."
        }
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
  value <- if (is.null(result$error)) {
    sprintf("Saved and rendered version %d of `%s`.", version, artifact$id)
  } else {
    shown <- if (artifact$html_version > 0) {
      sprintf("The user still sees version %d.", artifact$html_version)
    } else {
      "The user sees no rendered version yet."
    }
    sprintf(
      "Saved version %d of `%s`, but it failed to render. %s\n\n%s",
      version,
      artifact$id,
      shown,
      result$error
    )
  }
  tool_result(
    value,
    title = sprintf("Edited %s", artifact$title),
    icon = maybe_icon("file-earmark-text"),
    html = artifact_link_html(store, artifact$id, version)
  )
}

# The chip that stands in for a document in the chat. Clicking it reopens the
# document in the drawer through `link_input`, when commons_server() set one.
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

artifact_allowed_keys <- c("title", "subtitle", "date", "format", "commons")

parse_artifact_document <- function(source, call = rlang::caller_env()) {
  text <- sub("^(?:[ \t]*\n)+", "", gsub("\r\n", "\n", source), perl = TRUE)
  match <- regexec(
    "(?s)^---[ \t]*\n(?:(.*?)\n)??(?:---|\\.\\.\\.)[ \t]*(?:\n|$)",
    text,
    perl = TRUE
  )[[1]]
  if (match[[1]] == -1L) {
    artifact_invalid(
      "missing_frontmatter",
      "The document must start with YAML frontmatter between `---` lines.",
      call = call
    )
  }
  yaml_text <- if (attr(match, "match.length")[[2]] > 0) {
    substr(text, match[[2]], match[[2]] + attr(match, "match.length")[[2]] - 1L)
  } else {
    ""
  }
  body <- substr(text, attr(match, "match.length")[[1]] + 1L, nchar(text))

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
       {.field {disallowed}}. commons sets the format, theme, and execution
       options.",
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
      "The frontmatter's {.field format} can only be {.val html}; commons sets
       its options.",
      call = call
    )
  }
  commons <- front$commons %||% list()
  if (!is_mapping(commons) || length(setdiff(names(commons), "inputs"))) {
    artifact_invalid(
      "disallowed_key",
      "The frontmatter's {.field commons} key may only set {.field inputs}.",
      call = call
    )
  }

  front$commons <- NULL
  list(
    frontmatter = front,
    inputs = normalize_artifact_inputs(commons$inputs, call = call),
    body = body
  )
}

ARTIFACT_MAX_INPUTS <- 20L

artifact_input_keys <- list(
  measure = c("measure", "arguments"),
  metrics = c("metrics", "dimensions", "filters", "where", "arguments", "source"),
  calculation = c("calculation", "arguments", "source")
)

normalize_artifact_inputs <- function(inputs, call = rlang::caller_env()) {
  if (length(inputs) == 0) {
    return(list())
  }
  if (!is_mapping(inputs)) {
    artifact_invalid(
      "invalid_inputs",
      "{.field commons.inputs} must map input names to trusted calculations.",
      call = call
    )
  }
  if (length(inputs) > ARTIFACT_MAX_INPUTS) {
    artifact_invalid(
      "too_many_inputs",
      "A document can declare at most {ARTIFACT_MAX_INPUTS} inputs.",
      call = call
    )
  }
  Map(
    normalize_artifact_input,
    names(inputs),
    inputs,
    MoreArgs = list(call = call),
    USE.NAMES = FALSE
  )
}

normalize_artifact_input <- function(name, spec, call = rlang::caller_env()) {
  if (!grepl("^[a-z][a-z0-9_]{0,63}$", name)) {
    artifact_invalid(
      "invalid_input_name",
      "Input name {.val {name}} must be a lowercase identifier, such as
       {.val revenue_by_region}.",
      call = call
    )
  }
  kind <- if (is_mapping(spec)) {
    intersect(names(artifact_input_keys), names(spec))
  }
  if (length(kind) != 1L) {
    artifact_invalid(
      "invalid_input_kind",
      "Input {.val {name}} must name exactly one of {.field measure},
       {.field metrics}, or {.field calculation}.",
      call = call
    )
  }
  extra <- setdiff(names(spec), artifact_input_keys[[kind]])
  if (length(extra)) {
    artifact_invalid(
      "invalid_input_key",
      "Input {.val {name}} can't set {.field {extra}} for a {kind} input.",
      call = call
    )
  }
  invalid_value <- function(field) {
    artifact_invalid(
      "invalid_input_value",
      "Input {.val {name}} has an invalid {.field {field}}.",
      call = call
    )
  }

  arguments <- spec$arguments %||% structure(list(), names = character())
  if (!is_mapping(arguments)) {
    invalid_value("arguments")
  }
  if (!is.null(spec$source) && !rlang::is_string(spec$source)) {
    invalid_value("source")
  }
  strings <- function(field, required = FALSE) {
    value <- unlist(spec[[field]])
    if (
      (is.null(value) && !required) ||
        (is.character(value) && length(value) > 0 && !anyNA(value))
    ) {
      return(as.list(value))
    }
    invalid_value(field)
  }

  fn_call <- switch(
    kind,
    measure = ,
    calculation = {
      if (!rlang::is_string(spec[[kind]])) {
        invalid_value(kind)
      }
      c(
        list(name = spec[[kind]], arguments = arguments),
        if (identical(kind, "calculation")) list(source = spec$source)
      )
    },
    metrics = {
      where <- spec$where
      if (is_mapping(where)) {
        where <- list(where)
      }
      if (!is.null(where) && !all(vapply(where, is_mapping, logical(1)))) {
        invalid_value("where")
      }
      list(
        metrics = strings("metrics", required = TRUE),
        dimensions = strings("dimensions"),
        filters = strings("filters"),
        where = unname(as.list(where %||% list())),
        arguments = arguments,
        source = spec$source
      )
    }
  )
  list(
    name = name,
    kind = kind,
    call = fn_call,
    path = paste0("data/", name, ".csv")
  )
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

# YAML 1.1 reads `n`, `y`, `on`, and `off` as booleans, which would turn an
# argument named `n` into `FALSE`. Quarto reads YAML 1.2, where only true and
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

# --- inputs and files ------------------------------------------------------------

# Inputs whose call hasn't changed since the last version reuse its result.
resolve_artifact_inputs <- function(store, artifact, inputs) {
  data <- list()
  for (input in inputs) {
    cached <- artifact$inputs[[input$name]]
    value <- if (
      !is.null(cached) &&
        identical(cached$kind, input$kind) &&
        identical(cached$call, input$call)
    ) {
      cached$value
    } else {
      tryCatch(
        store$resolve_input(input),
        error = function(err) {
          cli::cli_abort(
            "Input {.val {input$name}} failed: {conditionMessage(err)}",
            call = NULL
          )
        }
      )
    }
    artifact$inputs[[input$name]] <- c(input, list(value = value))
    data[[input$name]] <- value
  }
  data
}

# Runs an input through the same implementation as its tool, with a private
# handle store so the result isn't advertised to run_r.
resolve_artifact_input <- function(private, input) {
  handles <- new_handle_store(max_rows = Inf)
  args <- input$call
  switch(
    input$kind,
    measure = call_measure_tool(
      private$registry,
      args$name,
      args$arguments,
      injections = private$injections,
      handles = handles,
      sources = private$sources,
      measure_provenance = private$measure_provenance,
      measure_display = private$measure_display
    ),
    metrics = call_metrics_impl(
      private$definitions,
      private$sources,
      handles,
      metrics = unlist(args$metrics),
      dimensions = unlist(args$dimensions),
      filters = unlist(args$filters),
      where = args$where,
      source_name = args$source,
      arguments = args$arguments
    ),
    calculation = call_calculation_impl(
      private$sources,
      handles,
      args$name,
      args$arguments,
      source_name = args$source
    )
  )
  ids <- handle_ids(handles)
  value <- if (length(ids)) get_handle(handles, ids[[1]])
  if (is.atomic(value) && !is.null(value)) {
    value <- data.frame(value = value)
  }
  if (!is.data.frame(value)) {
    cli::cli_abort("It must return a table or a value, not a plot or nothing.")
  }
  value
}

write_artifact_dir <- function(dir, doc, data) {
  dir.create(file.path(dir, "data"), recursive = TRUE, showWarnings = FALSE)
  writeLines(artifact_quarto_yml(), file.path(dir, "_quarto.yml"))
  writeLines(artifact_qmd(doc), file.path(dir, "report.qmd"), useBytes = TRUE)
  for (input in doc$inputs) {
    utils::write.csv(
      data[[input$name]],
      file.path(dir, input$path),
      row.names = FALSE,
      fileEncoding = "UTF-8"
    )
  }
  invisible(dir)
}

artifact_qmd <- function(doc) {
  paste0(
    "---\n",
    yaml::as.yaml(doc$frontmatter),
    "---\n\n",
    artifact_inputs_callout(doc$inputs),
    artifact_inputs_setup(doc$inputs),
    doc$body
  )
}

# Loading inputs ahead of the document's own cells means inline expressions
# can use them anywhere.
artifact_inputs_setup <- function(inputs) {
  if (length(inputs) == 0) {
    return("")
  }
  reads <- vapply(
    inputs,
    function(input) sprintf("`%s` <- read.csv(\"%s\")", input$name, input$path),
    character(1)
  )
  paste0(
    "```{r}\n#| include: false\n",
    paste(reads, collapse = "\n"),
    "\n```\n\n"
  )
}

# Stays with the document when it's deployed, so readers can see which
# numbers came from trusted calculations.
artifact_inputs_callout <- function(inputs) {
  if (length(inputs) == 0) {
    return("")
  }
  items <- vapply(
    inputs,
    function(input) {
      args <- drop_nulls(input$call)
      args <- args[lengths(args) > 0]
      sprintf(
        "- `%s`: %s %s",
        input$path,
        input$kind,
        jsonlite::toJSON(args, auto_unbox = TRUE)
      )
    },
    character(1)
  )
  paste0(
    "::: {.callout-note collapse=\"true\" title=\"Trusted inputs\"}\n",
    "These results of trusted calculations were computed before rendering:\n\n",
    paste(items, collapse = "\n"),
    "\n:::\n\n"
  )
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
    "execute:",
    "  warning: false",
    "  message: false"
  )
}

# Outside a stream nothing projects the reply, so `$chat()` saves the
# documents in its last turn after the fact and says where they rendered.
save_turn_artifacts <- function(store, turn) {
  text <- if (!is.null(turn)) {
    paste(
      vapply(
        Filter(function(x) S7::S7_inherits(x, ellmer::ContentText), turn@contents),
        function(x) x@text,
        character(1)
      ),
      collapse = ""
    )
  }
  if (!nzchar(text %||% "")) {
    return(invisible())
  }
  committed <- list()
  scanner <- citation_scanner(on_artifact = function(event) {
    if (identical(event$type, "close")) {
      committed[[length(committed) + 1L]] <<- c(
        list(id = event$id),
        artifact_commit(store, event$id, event$title, event$body)
      )
    }
    NULL
  })
  scanner$feed(text)
  scanner$finish()

  for (item in committed) {
    if (!is.null(item$error)) {
      artifact_remind(store, artifact_rejected_reminder(item$id, item$error))
      cli::cli_warn("Document {.val {item$id}} was not saved: {item$error}")
      next
    }
    result <- wait_for_promise(item$rendered)
    dir <- artifact_latest_dir(artifact_get(store, item$id))
    if (is.null(result$error)) {
      cli::cli_inform("Rendered {.val {item$id}} to {.file {file.path(dir, 'report.html')}}.")
    } else {
      artifact_remind(
        store,
        artifact_render_reminder(item$id, item$version, result$error)
      )
      cli::cli_warn(c(
        "Document {.val {item$id}} failed to render; its source is in {.file {dir}}.",
        i = "{result$error}"
      ))
    }
  }
  invisible()
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
