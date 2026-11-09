# Source code for a shared plot or table, assembled from the conversation's
# tool calls. Inputs are written with the public commons methods, the same
# shape `vignette("reproducibility")` uses, so the code runs against the app's
# commons object.

# Plots and tables in tool displays are wrapped so the browser can offer to
# share them and the server can find them again in the turns.
share_wrap <- function(html, kind, title = NULL) {
  id <- share_new_id(html)
  title <- share_clean_title(title)
  sprintf(
    paste0(
      "<div class=\"commons-shareable\" data-commons-share=\"%s\" ",
      "data-commons-share-kind=\"%s\"%s><!--commons-share:%s-->%s",
      "<!--/commons-share:%s--></div>"
    ),
    id,
    kind,
    if (is.null(title)) "" else sprintf(" data-commons-share-title=\"%s\"", html_escape(title)),
    id,
    html,
    id
  )
}

# A title fit for a page heading: one line of text, or NULL when there's none.
share_clean_title <- function(title) {
  if (is.null(title) || inherits(title, "waiver") || length(title) != 1) {
    return(NULL)
  }
  title <- gsub("<[^>]+>", "", as.character(title))
  title <- trimws(gsub("\\s+", " ", title))
  if (is.na(title) || !nzchar(title)) NULL else title
}

# The title a run_r plot's code gives it with labs() or ggtitle(), if any.
# Code that sets several titles likely draws several plots, and which title
# is whose isn't known, so none gets one.
plot_code_title <- function(code) {
  exprs <- tryCatch(parse(text = code, keep.source = FALSE), error = function(err) NULL)
  titles <- character()
  find <- function(expr) {
    if (!is.call(expr)) {
      return()
    }
    fn <- expr[[1]]
    if (is.call(fn) && identical(fn[[1]], as.symbol("::"))) {
      fn <- fn[[3]]
    }
    if (is.symbol(fn)) {
      fn <- as.character(fn)
      arg <- if (fn == "labs") {
        expr$title
      } else if (fn == "ggtitle") {
        if (!is.null(expr$label)) expr$label else if (length(expr) > 1) expr[[2]]
      }
      if (rlang::is_string(arg)) {
        titles <<- c(titles, arg)
      }
    }
    for (i in seq_along(expr)[-1]) {
      find(expr[[i]])
    }
  }
  for (expr in exprs) {
    find(expr)
  }
  titles <- unique(titles)
  if (length(titles) == 1) titles else NULL
}

gt_table_title <- function(value) {
  title <- value[["_heading"]]$title
  if (is.null(title)) NULL else as.character(title)
}

# Hashing rather than sampling leaves the session's random seed alone.
share_new_id <- function(html) {
  share_ids$n <- (share_ids$n %||% 0L) + 1L
  substr(rlang::hash(list(html, Sys.time(), share_ids$n, Sys.getpid())), 1, 16)
}

share_ids <- new.env(parent = emptyenv())

# Finds a wrapped output in the turns. Returns its kind, its HTML, the code
# that reproduces it, and the question that led to it, or NULL.
share_output_find <- function(turns, id) {
  if (!grepl("^[0-9a-f]+$", id)) {
    return(NULL)
  }
  calls <- share_tool_calls(turns)
  for (i in seq_along(calls)) {
    html <- share_result_html(calls[[i]]$result)
    open <- paste0("<!--commons-share:", id, "-->")
    start <- regexpr(open, html, fixed = TRUE)
    if (start < 0) {
      next
    }
    close <- regexpr(paste0("<!--/commons-share:", id, "-->"), html, fixed = TRUE)
    attrs <- regmatches(
      html,
      regexec(
        paste0(
          "data-commons-share=\"", id, "\" data-commons-share-kind=\"(\\w+)\"",
          "(?: data-commons-share-title=\"([^\"]*)\")?"
        ),
        html,
        perl = TRUE
      )
    )[[1]]
    title <- if (length(attrs) > 2 && nzchar(attrs[3])) html_unescape(attrs[3])
    return(list(
      kind = attrs[2],
      title = title,
      html = substr(html, start + attr(start, "match.length"), close - 1),
      code = share_code(calls, i),
      question = calls[[i]]$question
    ))
  }
  NULL
}

share_result_html <- function(result) {
  html <- if (!is.null(result)) result@extra$display$html
  if (is.null(html)) "" else paste(as.character(html), collapse = "")
}

# Each tool request paired with its result and the user question it answered.
share_tool_calls <- function(turns) {
  calls <- list()
  results <- list()
  question <- NULL
  for (turn in turns) {
    for (content in turn@contents) {
      if (S7::S7_inherits(content, ellmer::ContentToolRequest)) {
        calls[[length(calls) + 1L]] <- list(request = content, question = question)
      } else if (S7::S7_inherits(content, ellmer::ContentToolResult)) {
        if (!is.null(content@request)) {
          results[[content@request@id]] <- content
        }
      }
    }
    if (S7::S7_inherits(turn, ellmer::UserTurn)) {
      text <- turn_question(turn)
      if (!is.null(text)) {
        question <- text
      }
    }
  }
  lapply(calls, function(call) {
    call$result <- results[[call$request@id]]
    call
  })
}

turn_question <- function(turn) {
  texts <- Filter(
    function(x) identical(S7::S7_class(x), ellmer::ContentText),
    turn@contents
  )
  text <- trimws(gsub("\\s+", " ", paste(
    vapply(texts, function(x) x@text, character(1)),
    collapse = " "
  )))
  if (nzchar(text)) text else NULL
}

share_code <- function(calls, index) {
  request <- calls[[index]]$request
  switch(
    request@name,
    run_r = run_r_slice_code(calls, index),
    run_sql = sql_call_code(request@arguments),
    trusted_call_code(request@name, request@arguments)
  )
}

trusted_call_code <- function(tool, args) {
  args$arguments <- trusted_call_parameters(args$arguments)
  if (identical(tool, "call_metrics")) {
    for (field in intersect(c("metrics", "dimensions", "filters"), names(args))) {
      args[[field]] <- unlist(args[[field]], use.names = FALSE)
    }
    if (!is.null(args$where) && !is.character(args$where)) {
      args$where <- lapply(args$where, function(predicate) {
        unlist(predicate[c("column", "op", "value")], use.names = FALSE)
      })
    }
  }
  if (length(args$arguments) == 0) {
    args$arguments <- NULL
  }
  method <- sub("^call_", "", tool)
  call <- rlang::call2(method, !!!args)
  call[[1]] <- call("$", quote(commons), as.symbol(method))
  paste(deparse(call, width.cutoff = 80L), collapse = "\n")
}

trusted_call_parameters <- function(x) {
  if (is.null(x) || identical(x, "") || identical(x, "{}")) {
    return(list())
  }
  if (is.list(x)) {
    return(x)
  }
  jsonlite::fromJSON(x, simplifyVector = FALSE)
}

sql_call_code <- function(args) {
  source <- if (!is.null(args$source)) {
    paste0(", source = ", deparse1(args$source))
  }
  paste0("commons$run_sql(", sql_literal(args$sql), source, ")")
}

# Multi-line SQL reads best as written, which a raw string allows.
sql_literal <- function(sql) {
  if (grepl("\n", sql, fixed = TRUE) && !grepl(")\"", sql, fixed = TRUE)) {
    paste0("r\"(", sql, ")\"")
  } else {
    deparse1(sql)
  }
}

# The `run_r` code behind a plot, with only the earlier code it depends on:
# walking back from the plot's code, an earlier call is kept when it defines
# something a kept call uses. Results preloaded as `r1`, `r2`, ... become the
# calls that produced them.
run_r_slice_code <- function(calls, index) {
  chunks <- list()
  for (i in seq_len(index)) {
    call <- calls[[i]]
    if (!identical(call$request@name, "run_r")) {
      next
    }
    if (i < index && !run_r_succeeded(call$result)) {
      next
    }
    chunk <- run_r_chunk(call$request@arguments$code)
    if (!is.null(chunk)) {
      chunks[[as.character(i)]] <- chunk
    }
  }
  target <- chunks[[as.character(index)]]
  if (is.null(target)) {
    return(calls[[index]]$request@arguments$code)
  }

  needed <- target$uses
  kept <- list(target)
  for (chunk in rev(chunks[-length(chunks)])) {
    if (any(chunk$defs %in% needed)) {
      kept <- c(list(chunk), kept)
      needed <- union(setdiff(needed, chunk$defs), chunk$uses)
    }
  }

  handles <- share_handle_calls(calls[seq_len(index - 1L)])
  handles <- handles[names(handles) %in% needed]
  libraries <- unique(unlist(lapply(chunks, `[[`, "libraries")))
  sections <- c(
    if (length(libraries)) paste(libraries, collapse = "\n"),
    if (length(handles)) {
      paste(paste(names(handles), "<-", unlist(handles)), collapse = "\n")
    },
    vapply(kept, `[[`, character(1), "body")
  )
  paste(sections[nzchar(sections)], collapse = "\n\n")
}

# An error in a call's output means it stopped partway, so later code can't
# count on what it defines.
run_r_succeeded <- function(result) {
  if (is.null(result) || !is.null(result@error)) {
    return(FALSE)
  }
  !any(grepl("^Error: ", share_result_text(result)))
}

share_result_text <- function(result) {
  value <- result@value
  if (is.character(value)) {
    return(strsplit(paste(value, collapse = "\n"), "\n", fixed = TRUE)[[1]])
  }
  if (S7::S7_inherits(value, ellmer::Content)) {
    value <- list(value)
  }
  if (!is.list(value)) {
    return(character())
  }
  texts <- vapply(
    value,
    function(x) if (S7::S7_inherits(x, ellmer::ContentText)) x@text else "",
    character(1)
  )
  strsplit(paste(texts, collapse = "\n"), "\n", fixed = TRUE)[[1]]
}

# What a chunk defines and uses, its library calls, and its code without them.
run_r_chunk <- function(code) {
  exprs <- tryCatch(
    parse(text = code, keep.source = TRUE),
    error = function(err) NULL
  )
  if (is.null(exprs)) {
    return(NULL)
  }
  lines <- strsplit(code, "\r?\n")[[1]]
  is_library <- vapply(exprs, is_library_call, logical(1))
  spans <- lapply(attr(exprs, "srcref"), function(ref) ref[1]:ref[3])
  other_lines <- unlist(spans[!is_library])
  drop <- setdiff(unlist(spans[is_library]), other_lines)
  body <- lines[setdiff(seq_along(lines), drop)]
  list(
    defs = unique(unlist(lapply(exprs[!is_library], expr_defs))),
    uses = unique(unlist(lapply(exprs[!is_library], all.names))),
    libraries = vapply(
      exprs[is_library],
      function(e) paste(deparse(e), collapse = "\n"),
      character(1)
    ),
    body = trimws(paste(body, collapse = "\n"))
  )
}

is_library_call <- function(expr) {
  if (!is.call(expr) || !is.symbol(expr[[1]])) {
    return(FALSE)
  }
  fn <- as.character(expr[[1]])
  if (fn %in% c("suppressPackageStartupMessages", "suppressMessages")) {
    return(length(expr) == 2 && is_library_call(expr[[2]]))
  }
  fn %in% c("library", "require")
}

# Names assigned anywhere in an expression, except inside function bodies,
# whose assignments are local.
expr_defs <- function(expr) {
  if (!is.call(expr)) {
    return(character())
  }
  out <- character()
  if (is.symbol(expr[[1]])) {
    fn <- as.character(expr[[1]])
    if (fn == "function") {
      return(character())
    }
    if (fn %in% c("<-", "=", "<<-") && length(expr) == 3) {
      out <- assign_target(expr[[2]])
    } else if (fn == "assign" && length(expr) >= 2 && rlang::is_string(expr[[2]])) {
      out <- expr[[2]]
    }
  }
  # Only calls can assign, and checking first skips empty arguments, which
  # can't be bound to a variable.
  for (i in seq_along(expr)[-1]) {
    if (is.call(expr[[i]])) {
      out <- c(out, expr_defs(expr[[i]]))
    }
  }
  out
}

# `names(x)[2] <- ...` assigns to `x`.
assign_target <- function(lhs) {
  while (is.call(lhs)) {
    lhs <- lhs[[2]]
  }
  if (is.symbol(lhs)) as.character(lhs) else if (is.character(lhs)) lhs else character()
}

# The handles earlier calls registered, as the code that produces each.
share_handle_calls <- function(calls) {
  out <- list()
  for (call in calls) {
    if (is.null(call$result)) {
      next
    }
    handle <- regmatches(
      share_result_text(call$result),
      regexpr("Available to `run_r` as `r[0-9]+`", share_result_text(call$result))
    )
    if (length(handle) == 0) {
      next
    }
    name <- sub(".*`(r[0-9]+)`$", "\\1", handle[[1]])
    request <- call$request
    out[[name]] <- if (identical(request@name, "run_sql")) {
      sql_call_code(request@arguments)
    } else {
      trusted_call_code(request@name, request@arguments)
    }
  }
  out
}

html_unescape <- function(x) {
  x <- gsub("&lt;", "<", x, fixed = TRUE)
  x <- gsub("&gt;", ">", x, fixed = TRUE)
  x <- gsub("&quot;", "\"", x, fixed = TRUE)
  x <- gsub("&#39;", "'", x, fixed = TRUE)
  gsub("&amp;", "&", x, fixed = TRUE)
}
