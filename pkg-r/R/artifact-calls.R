# Documents get data by calling `commons$measure()`, `commons$metrics()`, or
# `commons$calculation()` in their code. Nothing defines `commons` where that
# code runs: before a unit is knitted, each call is resolved through its
# trusted path, its result is written under `data/`, and the call is replaced
# with a read of that file, so the saved document is plain R beside a
# manifest of where each file came from. Arguments must be literals, which is
# what lets the host resolve a call without running any of the document.

# Arguments mirror the call_measure, call_metrics, and call_calculation tools.
trusted_call_signatures <- list(
  measure = function(name, arguments = NULL) NULL,
  metrics = function(
    metrics,
    dimensions = NULL,
    filters = NULL,
    where = NULL,
    arguments = NULL,
    source = NULL
  ) {
    NULL
  },
  calculation = function(name, arguments = NULL, source = NULL) NULL
)

ARTIFACT_MAX_CALLS <- 20L

# The trusted calls in a unit's R code, each with its source text, its
# normalized call, and the name it's assigned to, if any. Code that doesn't
# parse has none; knitting reports the syntax error.
find_trusted_calls <- function(code, call = rlang::caller_env()) {
  exprs <- tryCatch(
    parse(text = code, keep.source = TRUE),
    error = function(err) NULL
  )
  if (length(exprs) == 0) {
    return(list())
  }
  data <- utils::getParseData(exprs, includeText = NA)
  uses <- data$parent[data$token == "SYMBOL" & data$text == "commons"]
  lapply(uses, trusted_call_at, data = data, call = call)
}

trusted_call_at <- function(data, symbol_expr, call = rlang::caller_env()) {
  dollar <- parse_parent(data, symbol_expr)
  outer <- parse_parent(data, dollar)
  method_call <- c("expr", "'$'", "SYMBOL_FUNCTION_CALL")
  if (
    !identical(parse_tokens(data, dollar), method_call) ||
      !identical(parse_tokens(data, outer)[1:2], c("expr", "'('"))
  ) {
    artifact_invalid(
      "reserved_name",
      "{.code commons} can only be used to call {.code commons$measure()},
       {.code commons$metrics()}, or {.code commons$calculation()}.",
      call = call
    )
  }
  text <- utils::getParseText(data, outer)
  lang <- str2lang(text)
  method <- as.character(lang[[1]][[3]])
  signature <- trusted_call_signatures[[method]]
  if (is.null(signature)) {
    artifact_invalid(
      "unknown_method",
      "{.code commons${method}()} doesn't exist. Use {.code commons$measure()},
       {.code commons$metrics()}, or {.code commons$calculation()}.",
      call = call
    )
  }
  matched <- tryCatch(match.call(signature, lang), error = function(err) err)
  if (inherits(matched, "error")) {
    artifact_invalid(
      "invalid_arguments",
      "{.code {text}} doesn't match {.code commons${method}()}'s arguments:
       {conditionMessage(matched)}",
      call = call
    )
  }
  args <- as.list(matched)[-1]
  for (name in names(args)) {
    if (!is_literal(args[[name]])) {
      artifact_invalid(
        "non_literal_argument",
        "{.arg {name}} in {.code {text}} must be written out as a literal,
         such as a string, a number, or {.code c()} or {.code list()} of
         them, not computed.",
        call = call
      )
    }
    args[name] <- list(eval(args[[name]], baseenv()))
  }
  c(
    list(text = text, target = assignment_target(data, outer)),
    normalize_trusted_call(method, args, call = call)
  )
}

parse_parent <- function(data, id) {
  data$parent[data$id == id]
}

parse_tokens <- function(data, id) {
  children <- data[data$parent == id, ]
  children <- children[order(children$line1, children$col1), ]
  children$token
}

assignment_target <- function(data, id) {
  parent <- parse_parent(data, id)
  children <- data[data$parent == parent, ]
  children <- children[order(children$line1, children$col1), ]
  if (
    nrow(children) != 3 ||
      !children$token[[2]] %in% c("LEFT_ASSIGN", "EQ_ASSIGN") ||
      children$id[[3]] != id
  ) {
    return(NULL)
  }
  symbol <- data[data$parent == children$id[[1]], ]
  if (nrow(symbol) == 1 && symbol$token == "SYMBOL") symbol$text else NULL
}

is_literal <- function(x) {
  if (is.null(x) || (is.atomic(x) && length(x) == 1)) {
    return(TRUE)
  }
  is.call(x) &&
    is.symbol(x[[1]]) &&
    as.character(x[[1]]) %in% c("c", "list", "-") &&
    all(vapply(as.list(x)[-1], is_literal, logical(1)))
}

normalize_trusted_call <- function(method, args, call = rlang::caller_env()) {
  extra <- setdiff(names(args), names(formals(trusted_call_signatures[[method]])))
  if (length(extra)) {
    artifact_invalid(
      "invalid_arguments",
      "{.code commons${method}()} has no argument {.arg {extra}}.",
      call = call
    )
  }
  invalid_value <- function(field) {
    artifact_invalid(
      "invalid_argument_value",
      "{.code commons${method}()} has an invalid {.arg {field}}.",
      call = call
    )
  }

  arguments <- args$arguments
  if (!is.null(arguments) && !is_mapping(arguments)) {
    invalid_value("arguments")
  }
  if (length(arguments) == 0) {
    arguments <- structure(list(), names = character())
  }
  if (!is.null(args$source) && !rlang::is_string(args$source)) {
    invalid_value("source")
  }
  strings <- function(field, required = FALSE) {
    value <- unlist(args[[field]])
    if (
      (is.null(value) && !required) ||
        (is.character(value) && length(value) > 0 && !anyNA(value))
    ) {
      return(as.list(value))
    }
    invalid_value(field)
  }

  fn_call <- switch(
    method,
    measure = ,
    calculation = {
      if (!rlang::is_string(args$name)) {
        invalid_value("name")
      }
      c(
        list(name = args$name, arguments = arguments),
        if (identical(method, "calculation")) list(source = args$source)
      )
    },
    metrics = {
      where <- args$where
      if (is_mapping(where) && length(where)) {
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
        source = args$source
      )
    }
  )
  list(kind = method, call = fn_call)
}

trusted_call_key <- function(x) {
  rlang::hash(x[c("kind", "call")])
}

# Gives a call its file: the name it's assigned to, or its kind, made unique.
# Identical calls share a file.
register_trusted_call <- function(calls, found, call = rlang::caller_env()) {
  key <- trusted_call_key(found)
  if (!is.null(calls[[key]])) {
    return(calls)
  }
  if (length(calls) >= ARTIFACT_MAX_CALLS) {
    artifact_invalid(
      "too_many_calls",
      "A document can make at most {ARTIFACT_MAX_CALLS} different trusted
       calls.",
      call = call
    )
  }
  target <- found$target
  stem <- if (!is.null(target) && grepl("^[A-Za-z][A-Za-z0-9_]{0,63}$", target)) {
    target
  } else {
    found$kind
  }
  taken <- tolower(vapply(calls, `[[`, character(1), "file"))
  file <- paste0(stem, ".csv")
  n <- 1L
  while (tolower(file) %in% taken) {
    n <- n + 1L
    file <- paste0(stem, "-", n, ".csv")
  }
  calls[[key]] <- list(kind = found$kind, call = found$call, file = file)
  calls
}

# Each call's result is resolved once per artifact, so every version and
# every reuse of the call sees the same data.
resolve_trusted_call <- function(store, artifact, found) {
  key <- trusted_call_key(found)
  result <- artifact$results[[key]]
  if (is.null(result)) {
    result <- tryCatch(
      store$resolve_input(found[c("kind", "call")]),
      error = function(err) {
        cli::cli_abort(
          "{.code commons${found$kind}()} failed: {conditionMessage(err)}",
          call = NULL
        )
      }
    )
    result$resolved <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
    artifact$results[[key]] <- result
  }
  result
}

trusted_call_read <- function(entry, result) {
  sprintf(
    "read.csv(\"data/%s\")%s",
    entry$file,
    if (isTRUE(result$scalar)) "$value" else ""
  )
}

# Calls are replaced by their text, so every occurrence of an identical call
# becomes the same read.
rewrite_trusted_text <- function(text, replacements) {
  for (i in seq_along(replacements)) {
    text <- gsub(names(replacements)[[i]], replacements[[i]], text, fixed = TRUE)
  }
  text
}

unit_code <- function(unit) {
  if (unit$kind == "inline") {
    return(unit$text)
  }
  lines <- strsplit(unit$text, "\n", fixed = TRUE)[[1]]
  paste(lines[-c(1, length(lines))], collapse = "\n")
}

rewrite_artifact_body <- function(body, calls, artifact) {
  replacements <- character()
  for (unit in artifact_units(segment_artifact_body(body))) {
    found <- tryCatch(find_trusted_calls(unit_code(unit)), error = function(err) list())
    for (x in found) {
      key <- trusted_call_key(x)
      if (!is.null(calls[[key]])) {
        replacements[[x$text]] <- trusted_call_read(calls[[key]], artifact$results[[key]])
      }
    }
  }
  rewrite_trusted_text(body, replacements)
}

write_trusted_result <- function(value, path) {
  utils::write.csv(value, path, row.names = FALSE, fileEncoding = "UTF-8")
}

trusted_call_manifest <- function(calls, artifact) {
  entries <- lapply(names(calls), function(key) {
    result <- artifact$results[[key]]
    drop_nulls(list(
      kind = calls[[key]]$kind,
      call = calls[[key]]$call,
      sql = result$sql,
      bindings = result$bindings,
      provenance = result$provenance,
      resolved = result$resolved
    ))
  })
  rlang::set_names(entries, vapply(calls, `[[`, character(1), "file"))
}
