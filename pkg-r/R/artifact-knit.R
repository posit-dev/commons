# Documents are knitted piece by piece as they stream rather than rendered by
# Quarto: each R cell runs through knitr in a sandboxed worker as soon as its
# closing fence arrives, and each inline expression as soon as its closing
# backtick does. The view is the knitted Markdown, converted to HTML a piece
# at a time.
#
# The first version rendered each saved version with `quarto render` inside
# the sandboxed worker and showed the resulting HTML. That meant a streamed
# document showed placeholders for its code until the stream ended and then
# waited about eight seconds for Quarto (mostly Deno and Pandoc starting up),
# every edit paid the same cost, and Quarto's runtime needed more than the
# Linux sandbox grants (`/proc/self/exe`, a large address space, device
# nodes). Knitting cells as they arrive removes the wait and keeps execution
# in the same kind of worker as run_r. The cost is that the view is commons'
# rendering of knitted Markdown rather than Quarto's HTML; the saved source is
# still a Quarto document. This is close in spirit to Quarto 2's preview,
# which renders in the browser and replays code outputs it executed
# separately, and that renderer could replace this one once it's embeddable.

# A run executes one version of a document. Outputs are kept per code unit (a
# cell or an inline expression, in document order), so a later version whose
# code and inputs are unchanged can reuse them.
new_artifact_run <- function(store, artifact) {
  run <- new.env(parent = emptyenv())
  run$store <- store
  run$artifact <- artifact
  run$dir <- tempfile("commons-run-")
  dir.create(file.path(run$dir, "figs"), recursive = TRUE)
  run$worker <- NULL
  run$tail <- promises::promise_resolve(NULL)
  run$front <- NULL
  run$front_error <- NULL
  run$units <- list()
  run$queued <- 0L
  run$sent <- character()
  run$cache <- new.env(parent = emptyenv())
  run$cancelled <- FALSE
  run
}

# Brings the run up to date with the source received so far: validates the
# frontmatter and loads inputs once it closes, queues every newly complete
# code unit, and sends the pieces whose HTML changed.
artifact_run_update <- function(run, source, complete = FALSE) {
  if (run$cancelled) {
    return(invisible(run))
  }
  if (is.null(run$front) && is.null(run$front_error)) {
    split <- split_artifact_source(source)
    if (is.null(split)) {
      return(invisible(run))
    }
    run$front <- tryCatch(
      artifact_run_load(run, split$yaml),
      error = function(err) {
        run$front_error <- conditionMessage(err)
        NULL
      }
    )
    if (!is.null(run$front_error)) {
      artifact_run_status(run, "failed", run$front_error)
      return(invisible(run))
    }
  }
  if (!is.null(run$front_error)) {
    return(invisible(run))
  }

  body <- split_artifact_source(source)$body
  pieces <- segment_artifact_body(body, complete = complete)
  units <- artifact_units(pieces)
  for (i in seq_along(units)) {
    if (i > run$queued) {
      run$units[[i]] <- c(units[[i]], list(status = "pending"))
      run$queued <- i
      artifact_run_queue(run, i)
    } else if (!identical(run$units[[i]]$text, units[[i]]$text)) {
      run$units[[i]] <- c(units[[i]], list(status = "pending"))
      artifact_run_queue(run, i)
    }
  }
  run$pieces <- segment_with_units(pieces, units)
  artifact_run_emit(run)
  invisible(run)
}

# Resolves once every queued unit has run. The result holds each piece's HTML
# and the errors to report to the model.
artifact_run_finish <- function(run, source) {
  artifact_run_update(run, source, complete = TRUE)
  if (!is.null(run$front_error)) {
    artifact_run_close(run)
    return(promises::promise_resolve(list(
      html = character(),
      errors = run$front_error
    )))
  }
  if (any(vapply(run$units, function(u) u$status == "pending", logical(1)))) {
    artifact_run_status(run, "running")
  }
  done <- promises::then(run$tail, function(...) {
    artifact_run_close(run)
    artifact_run_emit(run)
    list(html = run$sent, errors = artifact_run_errors(run))
  })
  promises::catch(done, function(err) {
    artifact_run_close(run)
    list(html = run$sent, errors = conditionMessage(err))
  })
}

artifact_run_cancel <- function(run) {
  run$cancelled <- TRUE
  artifact_run_close(run)
  invisible(run)
}

artifact_run_close <- function(run) {
  if (!is.null(run$worker)) {
    worker_close(run$worker)
    run$worker <- NULL
  }
  invisible(run)
}

# Inputs are written where the deployed document keeps them and loaded under
# the same names, so the session matches what Quarto would run.
artifact_run_load <- function(run, yaml_text) {
  front <- validate_artifact_frontmatter(yaml_text)
  data <- resolve_artifact_inputs(run$store, run$artifact, front$inputs)
  dir.create(file.path(run$dir, "data"), showWarnings = FALSE)
  for (input in front$inputs) {
    utils::write.csv(
      data[[input$name]],
      file.path(run$dir, input$path),
      row.names = FALSE,
      fileEncoding = "UTF-8"
    )
  }
  run$setup <- artifact_inputs_code(front$inputs)
  front
}

artifact_run_queue <- function(run, i) {
  force(i)
  run$tail <- promises::then(run$tail, function(...) {
    if (run$cancelled || !identical(run$units[[i]]$status, "pending")) {
      return(NULL)
    }
    promises::then(artifact_run_unit(run, run$units[[i]]), function(result) {
      run$units[[i]] <- c(
        run$units[[i]][c("kind", "text", "engine", "label", "ordinal")],
        result
      )
      artifact_run_emit(run)
      NULL
    })
  })
  invisible(run)
}

artifact_run_unit <- function(run, unit) {
  if (unit$kind == "cell" && !identical(unit$engine, "r")) {
    return(promises::promise_resolve(list(
      status = "error",
      error = sprintf("Only R cells run, not `%s`.", unit$engine),
      html = artifact_error_html(sprintf(
        "Only R cells run, not %s.",
        unit$engine
      ))
    )))
  }
  if (is.null(run$worker)) {
    run$worker <- new_r_worker(run$store$network, run$store$protection)
    worker_ensure(run$worker)
    worker_runtime_call(run$worker, "worker_knit_init", list(
      dir = run$dir,
      setup = run$setup
    ))
  }
  worker <- run$worker
  worker$rs$call(
    worker_call,
    args = list(
      runtime = worker$runtime,
      name = "worker_knit_unit",
      args = list(kind = unit$kind, text = unit$text)
    )
  )
  promises::then(
    worker_await(worker, getOption("commons.run_r_timeout", 60)),
    function(res) {
      if (!is.null(res$failure)) {
        return(list(
          status = "error",
          error = res$failure,
          html = artifact_error_html(res$failure),
          value = artifact_error_inline(res$failure)
        ))
      }
      error <- if (length(res$errors)) res$errors[[1]]
      if (unit$kind == "inline") {
        return(list(
          status = if (is.null(error)) "done" else "error",
          error = error,
          value = if (is.null(error)) res$output else artifact_error_inline(error)
        ))
      }
      list(
        status = if (is.null(error)) "done" else "error",
        error = error,
        html = markdown_fragment_html(embed_figures(res$output, res$figures))
      )
    }
  )
}

worker_runtime_call <- function(worker, name, args) {
  worker$rs$run(
    worker_call,
    args = list(runtime = worker$runtime, name = name, args = args)
  )
}

artifact_run_errors <- function(run) {
  failed <- Filter(function(u) identical(u$status, "error"), run$units)
  vapply(
    failed,
    function(u) {
      where <- if (u$kind == "cell") {
        if (is.null(u$label)) {
          sprintf("Cell %d", u$ordinal)
        } else {
          sprintf("Cell %d (`%s`)", u$ordinal, u$label)
        }
      } else {
        sprintf("Inline `r %s`", u$text)
      }
      paste0(where, ": ", u$error)
    },
    character(1)
  )
}

artifact_run_status <- function(run, status, error = NULL) {
  artifact_notify(run$store, list(
    type = "status",
    id = run$artifact$id,
    status = status,
    error = error
  ))
}

# Sends only the pieces whose HTML changed since the last call.
artifact_run_emit <- function(run) {
  if (run$cancelled) {
    return(invisible(run))
  }
  html <- c(
    artifact_header_html(run$front$frontmatter),
    vapply(
      run$pieces %||% list(),
      function(piece) artifact_piece_html(run, piece),
      character(1)
    )
  )
  old <- run$sent
  length(old) <- length(html)
  changed <- which(is.na(old) | html != old)
  shrunk <- length(html) < length(run$sent)
  run$sent <- html
  if (length(changed) || shrunk) {
    artifact_notify(run$store, list(
      type = "pieces",
      id = run$artifact$id,
      pieces = lapply(changed, function(i) {
        list(index = i - 1L, html = html[[i]])
      }),
      count = length(html)
    ))
  }
  invisible(run)
}

artifact_piece_html <- function(run, piece) {
  if (piece$kind == "cell") {
    unit <- if (!is.null(piece[["unit"]])) run$units[[piece[["unit"]]]]
    if (is.null(unit)) {
      return(artifact_pending_html("Writing code…"))
    }
    if (identical(unit$status, "pending")) {
      return(artifact_pending_html("Running…"))
    }
    return(unit$html)
  }
  values <- lapply(piece$units, function(i) {
    unit <- run$units[[i]]
    if (is.null(unit) || identical(unit$status, "pending")) {
      "<span class=\"commons-pending\">…</span>"
    } else {
      unit$value
    }
  })
  text <- substitute_inline(piece$text, piece$matches, values)
  key <- rlang::hash(text)
  cached <- run$cache[[key]]
  if (is.null(cached)) {
    cached <- markdown_fragment_html(convert_divs(text))
    assign(key, cached, envir = run$cache)
  }
  cached
}

# --- segmentation -------------------------------------------------------------

INLINE_PATTERN <- "`(?:r|\\{r\\}) ([^`]+)`"
CELL_OPEN <- "^(`{3,})[ \t]*\\{([A-Za-z][A-Za-z0-9_]*)([^}]*)\\}[ \t]*$"

# Splits the body into prose blocks (separated by blank lines, keeping fenced
# code and `:::` divs whole) and cells. A piece is complete once what follows
# it has arrived; only the last piece of an unfinished stream is not.
segment_artifact_body <- function(body, complete = TRUE) {
  lines <- strsplit(body, "\n", fixed = TRUE)[[1]]
  n <- length(lines)
  ends_line <- complete || endsWith(body, "\n")
  line_done <- function(i) i < n || ends_line

  pieces <- list()
  prose <- character()
  fence <- NULL
  divs <- 0L
  add <- function(piece) pieces[[length(pieces) + 1L]] <<- piece
  flush <- function(done) {
    if (any(nzchar(trimws(prose)))) {
      add(list(kind = "prose", text = paste(prose, collapse = "\n"), complete = done))
    }
    prose <<- character()
  }

  i <- 1L
  while (i <= n) {
    line <- lines[[i]]
    open <- regmatches(line, regexec(CELL_OPEN, line, perl = TRUE))[[1]]
    if (length(open) && is.null(fence) && line_done(i)) {
      flush(TRUE)
      close <- paste0("^`{", nchar(open[[2]]), ",}[ \t]*$")
      j <- i + 1L
      while (j <= n && !(grepl(close, lines[[j]]) && line_done(j))) {
        j <- j + 1L
      }
      cell_complete <- j <= n
      add(list(
        kind = "cell",
        text = paste(lines[i:min(j, n)], collapse = "\n"),
        engine = open[[3]],
        label = cell_label(open[[4]], lines[i:min(j, n)]),
        complete = cell_complete
      ))
      i <- j + 1L
      next
    }
    if (grepl("^(`{3,}|~{3,})", line)) {
      fence <- if (is.null(fence)) "open" else NULL
    } else if (is.null(fence) && grepl("^:{3,}[ \t]*\\S", line)) {
      divs <- divs + 1L
    } else if (is.null(fence) && grepl("^:{3,}[ \t]*$", line)) {
      divs <- max(0L, divs - 1L)
    }
    if (!nzchar(trimws(line)) && is.null(fence) && divs == 0L) {
      flush(line_done(i))
    } else {
      prose <- c(prose, line)
    }
    i <- i + 1L
  }
  flush(complete)
  pieces
}

cell_label <- function(header, lines) {
  label <- trimws(sub(",.*$", "", header))
  if (nzchar(label) && !grepl("=", label)) {
    return(label)
  }
  option <- grep("^#\\|[ \t]*label:", lines, value = TRUE)
  if (length(option)) trimws(sub("^#\\|[ \t]*label:", "", option[[1]])) else NULL
}

# Units run in document order, so the sequence stops at the first cell that
# hasn't finished arriving.
artifact_units <- function(pieces) {
  units <- list()
  ordinal <- 0L
  for (p in seq_along(pieces)) {
    piece <- pieces[[p]]
    if (piece$kind == "cell") {
      if (!piece$complete) {
        break
      }
      ordinal <- ordinal + 1L
      units[[length(units) + 1L]] <- list(
        kind = "cell",
        text = piece$text,
        engine = piece$engine,
        label = piece$label,
        ordinal = ordinal,
        piece = p
      )
    } else {
      found <- regmatches(piece$text, gregexpr(INLINE_PATTERN, piece$text, perl = TRUE))[[1]]
      for (match in found) {
        units[[length(units) + 1L]] <- list(
          kind = "inline",
          text = sub(INLINE_PATTERN, "\\1", match, perl = TRUE),
          piece = p
        )
      }
    }
  }
  units
}

# Attach each piece's units to it, so a piece knows which results it shows.
segment_with_units <- function(pieces, units) {
  for (p in seq_along(pieces)) {
    pieces[[p]]$units <- integer()
  }
  for (i in seq_along(units)) {
    p <- units[[i]]$piece
    if (pieces[[p]]$kind == "cell") {
      pieces[[p]]$unit <- i
    } else {
      pieces[[p]]$units <- c(pieces[[p]]$units, i)
    }
  }
  for (p in seq_along(pieces)) {
    if (pieces[[p]]$kind == "prose") {
      pieces[[p]]$matches <- gregexpr(INLINE_PATTERN, pieces[[p]]$text, perl = TRUE)[[1]]
    }
  }
  pieces
}

substitute_inline <- function(text, matches, values) {
  if (length(values) == 0 || matches[[1]] == -1L) {
    return(text)
  }
  starts <- as.integer(matches)[seq_along(values)]
  ends <- starts + attr(matches, "match.length")[seq_along(values)] - 1L
  out <- character()
  pos <- 1L
  for (k in seq_along(values)) {
    out <- c(out, substr(text, pos, starts[[k]] - 1L), values[[k]])
    pos <- ends[[k]] + 1L
  }
  paste(c(out, substr(text, pos, nchar(text))), collapse = "")
}

# --- HTML -----------------------------------------------------------------------

# commonmark has no fenced divs, so `:::` lines become HTML blocks; Markdown
# between HTML blocks separated by blank lines is still parsed.
convert_divs <- function(text) {
  lines <- strsplit(text, "\n", fixed = TRUE)[[1]]
  open <- grepl("^:{3,}[ \t]*\\S", lines)
  close <- grepl("^:{3,}[ \t]*$", lines)
  lines[open] <- vapply(lines[open], div_open_html, character(1))
  lines[close] <- "\n</div>\n"
  paste(lines, collapse = "\n")
}

div_open_html <- function(line) {
  attrs <- sub("^:{3,}[ \t]*", "", line)
  attrs <- sub("^\\{(.*)\\}[ \t]*$", "\\1", attrs)
  classes <- regmatches(attrs, gregexpr("\\.[A-Za-z][A-Za-z0-9_-]*", attrs))[[1]]
  classes <- c(sub("^\\.", "", classes), if (!grepl("^[{.]", attrs) && !grepl("=", attrs)) trimws(attrs))
  title <- regmatches(attrs, regexec("title=\"([^\"]*)\"", attrs))[[1]]
  callout <- any(startsWith(classes, "callout"))
  paste0(
    "\n<div class=\"", html_escape(paste(c(if (callout) "callout", classes), collapse = " ")), "\">\n",
    if (length(title)) {
      paste0("<p class=\"callout-title\">", html_escape(title[[2]]), "</p>\n")
    },
    "\n"
  )
}

markdown_fragment_html <- function(markdown) {
  commonmark::markdown_html(markdown, extensions = TRUE, footnotes = TRUE)
}

# Only figures the worker reports writing are embedded; a path the model typed
# stays a plain link the sandboxed view can't load.
embed_figures <- function(markdown, figures) {
  for (path in figures) {
    uri <- paste0(
      "data:image/png;base64,",
      gsub("\n", "", jsonlite::base64_enc(readBin(path, "raw", file.size(path))))
    )
    markdown <- gsub(path, uri, markdown, fixed = TRUE)
  }
  markdown
}

artifact_header_html <- function(frontmatter) {
  if (is.null(frontmatter$title)) {
    return(character())
  }
  paste0(
    "<header><h1>", html_escape(frontmatter$title), "</h1>",
    if (!is.null(frontmatter$subtitle)) {
      paste0("<p class=\"subtitle\">", html_escape(frontmatter$subtitle), "</p>")
    },
    "</header>"
  )
}

artifact_pending_html <- function(text) {
  sprintf("<div class=\"commons-pending\">%s</div>", text)
}

artifact_error_html <- function(message) {
  sprintf("<div class=\"commons-cell-error\">%s</div>", html_escape(message))
}

artifact_error_inline <- function(message) {
  sprintf(
    "<span class=\"commons-inline-error\" title=\"%s\">error</span>",
    escape_attr(message)
  )
}

# A standalone page for `$chat()`, which has no drawer to show the pieces in.
artifact_document_html <- function(title, pieces) {
  css <- read_utf8(system.file(
    "www", "commons-chat", "commons-document.css",
    package = "commons"
  ))
  paste0(
    "<!doctype html>\n<html><head><meta charset=\"utf-8\"><title>",
    html_escape(title),
    "</title><style>\n", css, "\n</style></head><body><main>\n",
    paste(pieces, collapse = "\n"),
    "\n</main></body></html>\n"
  )
}

read_utf8 <- function(path) {
  paste(readLines(path, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
}
