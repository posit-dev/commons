#' Read commons trajectories
#'
#' @description
#' `trajectory_read()` reads conversation trajectories captured by
#' [commons()] when `log = TRUE`. Trajectories are recorded as OpenTelemetry
#' spans—see the `log` argument of [commons()] for how capture is
#' enabled—and read back from Posit Connect's content observability store or
#' from local trace files.
#'
#' @param source Where to read trajectories from:
#'
#'   * `NULL` (the default) resolves automatically: on Posit Connect, this
#'     content's own traces; in a project that has been deployed with
#'     rsconnect, the deployed content's traces; otherwise, the local trace
#'     directory that [commons()] writes to.
#'   * A Connect content GUID, a content URL (`.../content/<guid>/`), or a
#'     dashboard URL (`.../connect/#/apps/<guid>/`).
#'   * A directory of OTLP NDJSON trace files (`trace-*.jsonl`).
#' @param ... These dots are for future extensions and must be empty.
#' @param n Keep only the `n` most recent conversations, after `from`/`to`
#'   filtering. `NULL` (the default) keeps all of them.
#' @param from,to Keep only conversations with chat activity at or after
#'   `from` and before `to`. Each is a `POSIXct`, a `Date`, or a single
#'   string in a standard format like `"2026-07-22"` or
#'   `"2026-07-22 14:30:00"`; dates and strings are interpreted in local
#'   time. A conversation that continues past `to` is returned with its
#'   history as of `to`.
#'
#' @details
#' Reading traces from Connect requires the `CONNECT_API_KEY` environment
#' variable (and `CONNECT_SERVER`, when the server can't be inferred from the
#' project's deployment record), and editor-level access to the content: you
#' must own it or be a collaborator. See the `share_with` argument of
#' [commons()].
#'
#' @return A list of conversations, named by conversation id and ordered
#'   oldest-first. Each conversation is a list of [ellmer::Turn]s and carries
#'   a `last_active` attribute: a `POSIXct` giving the time of the
#'   conversation's most recent chat activity. The list carries a `source`
#'   attribute identifying the local trace directory or Connect content from
#'   which it was read.
#'
#' @examples
#' \dontrun{
#' # Read all of the app's local or deployed trajectories, using the
#' # automatically resolved source.
#' trajectories <- trajectory_read()
#'
#' # Read a recent subset.
#' recent <- trajectory_read(n = 20, from = "2026-07-01")
#'
#' # Read trajectories for a specific Connect content item or a local trace
#' # directory.
#' deployed <- trajectory_read(
#'   "https://connect.example.com/content/01234567-89ab-cdef-0123-456789abcdef/"
#' )
#' local <- trajectory_read("path/to/traces")
#' }
#'
#' @export
trajectory_read <- function(
  source = NULL,
  ...,
  n = NULL,
  from = NULL,
  to = NULL
) {
  rlang::check_dots_empty()
  rlang::check_number_whole(n, min = 1, allow_null = TRUE)
  from <- check_window_bound(from)
  to <- check_window_bound(to)
  resolved <- resolve_trajectory_source(source)
  spans <- switch(
    resolved$kind,
    local = read_local_spans(resolved$path),
    connect = read_connect_spans(resolved$client, resolved$guid, n, from, to)
  )
  spans <- filter_chat_spans(spans, from, to)
  trajectories <- drop_contentless(build_trajectories(spans))
  if (!is.null(n)) {
    trajectories <- utils::tail(trajectories, n)
  }
  attr(trajectories, "source") <- trajectory_source_record(resolved)
  trajectories
}

trajectory_source_record <- function(resolved) {
  if (identical(resolved$kind, "connect")) {
    return(list(
      kind = "connect",
      server = resolved$client$server,
      content_guid = resolved$guid
    ))
  }
  list(
    kind = "local",
    path = normalizePath(resolved$path, mustWork = FALSE)
  )
}

# Dates and date strings both resolve to local midnight; as.POSIXct() alone
# would silently read a Date as UTC midnight.
check_window_bound <- function(
  x,
  arg = rlang::caller_arg(x),
  call = rlang::caller_env()
) {
  if (is.null(x)) {
    return(NULL)
  }
  if (length(x) == 1) {
    if (inherits(x, "POSIXct") && !is.na(x)) {
      return(x)
    }
    if (inherits(x, "Date") && !is.na(x)) {
      return(as.POSIXct(format(x)))
    }
    if (is.character(x)) {
      parsed <- parse_window_bound(x)
      if (!is.null(parsed)) {
        return(parsed)
      }
    }
  }
  cli::cli_abort(
    "{.arg {arg}} must be a {.cls POSIXct}, a {.cls Date}, or a single
     datetime string like {.val 2026-07-22 14:30:00}.",
    call = call
  )
}

# as.POSIXct()'s default formats accept any parseable prefix -- reading
# "2026-07-22T14:30:00" as midnight and "2026-07-22oops" as valid -- so try
# explicit formats and require that formatting back reproduces the input.
parse_window_bound <- function(x) {
  formats <- c(
    "%Y-%m-%d %H:%M:%S",
    "%Y-%m-%dT%H:%M:%S",
    "%Y-%m-%d %H:%M",
    "%Y-%m-%dT%H:%M",
    "%Y-%m-%d"
  )
  for (fmt in formats) {
    parsed <- as.POSIXct(x, format = fmt)
    if (!is.na(parsed) && identical(format(parsed, fmt), x)) {
      return(parsed)
    }
  }
  NULL
}

# The `from`/`to` window and `n` limit are passed down to Connect so a
# filtered read doesn't transfer the whole trace store. The server-side
# `from` filter can still drop ancestor spans (see connect_window_param()),
# severing turn-ancestor resolution; when that happens, refetch without
# `from`.
read_connect_spans <- function(
  client,
  guid,
  n,
  from,
  to,
  call = rlang::caller_env()
) {
  spans <- fetch_connect_spans(client, guid, from, n, from, to, call)
  if (
    !is.null(from) && has_severed_ancestry(filter_chat_spans(spans, from, to))
  ) {
    spans <- fetch_connect_spans(client, guid, NULL, n, from, to, call)
  }
  spans
}

fetch_connect_spans <- function(
  client,
  guid,
  from_pushdown,
  n,
  from,
  to,
  call
) {
  parse_otlp_lines(connect_trace_lines(
    client,
    guid,
    from = from_pushdown,
    to = to,
    enough = if (!is.null(n)) enough_trace_lines(n, from, to),
    call = call
  ))
}

# Builds connect_trace_lines()'s early-stop check: TRUE once the lines
# fetched so far reconstruct `n` complete conversations in the window.
enough_trace_lines <- function(n, from, to) {
  state <- new.env(parent = emptyenv())
  state$spans <- list()
  state$n_seen <- 0
  function(lines) {
    new_lines <- lines[rlang::seq2(state$n_seen + 1, length(lines))]
    state$n_seen <- length(lines)
    state$spans <- c(state$spans, parse_otlp_lines(new_lines))
    kept <- filter_chat_spans(state$spans, from, to)
    if (has_severed_ancestry(kept)) {
      return(FALSE)
    }
    latest <- latest_chat_spans(Filter(is_chat_span, kept))
    if (length(latest) < n) {
      return(FALSE)
    }
    sum(lengths(lapply(latest, trajectory_turns)) > 0) >= n
  }
}

# Chat spans emitted without message content -- capture was off, or the spans
# came from a non-commons emitter -- reconstruct to zero turns. Returning
# them as empty conversations reads like data loss, so drop them, pointing
# at the likely cause when nothing at all carried content.
drop_contentless <- function(trajectories) {
  empty <- vapply(trajectories, function(turns) length(turns) == 0, logical(1))
  if (length(trajectories) > 0 && all(empty)) {
    cli::cli_warn(c(
      "Found {length(trajectories)} conversation{?s} of spans, but none carry
       message content; returning none.",
      i = "Message content is captured only when the agent runs with
           {.code log = TRUE} while OpenTelemetry tracing is active. On Posit
           Connect, check the app's startup log for warnings from
           {.fn commons}."
    ))
  } else if (any(empty)) {
    cli::cli_inform(
      "Dropping {sum(empty)} conversation{?s} whose spans carry no message
       content."
    )
  }
  trajectories[!empty]
}

resolve_trajectory_source <- function(source, call = rlang::caller_env()) {
  if (is.null(source)) {
    return(resolve_default_source(call))
  }

  if (is.character(source) && length(source) == 1) {
    if (is_content_guid(source)) {
      return(list(
        kind = "connect",
        guid = source,
        client = connect_client(call = call)
      ))
    }
    if (grepl("^https?://", source)) {
      url_guid <- content_url_guid(source)
      if (is.null(url_guid)) {
        cli::cli_abort(
          c(
            "Can't find a content GUID in {.url {source}}.",
            i = "Supported URLs contain {.code /content/<guid>} (a content
                 URL) or {.code #/apps/<guid>} (a dashboard URL)."
          ),
          call = call
        )
      }
      return(list(
        kind = "connect",
        guid = url_guid$guid,
        client = connect_client(server = url_guid$server, call = call)
      ))
    }
    return(list(kind = "local", path = source))
  }

  cli::cli_abort(
    "{.arg source} must be {.code NULL}, a directory path, a Connect content
     GUID, or a Connect content URL.",
    call = call
  )
}

resolve_default_source <- function(call = rlang::caller_env()) {
  if (is_connect_runtime()) {
    return(list(
      kind = "connect",
      guid = connect_content_guid(),
      client = connect_client(call = call)
    ))
  }

  deployment <- find_rsconnect_deployment()
  if (!is.null(deployment)) {
    return(list(
      kind = "connect",
      guid = deployment$guid,
      client = connect_client(server = deployment$server, call = call)
    ))
  }

  list(kind = "local", path = local_traces_dir())
}

# The write side may have pointed the file exporter somewhere via
# OTEL_EXPORTER_OTLP_TRACES_FILE; read from there when it did.
local_traces_dir <- function() {
  file <- Sys.getenv("OTEL_EXPORTER_OTLP_TRACES_FILE")
  if (nzchar(file)) {
    return(dirname(file))
  }
  commons_traces_dir()
}

is_content_guid <- function(x) {
  grepl(
    "^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$",
    x
  )
}

content_url_guid <- function(x) {
  if (!grepl("^https?://", x)) {
    return(NULL)
  }
  guid <- "([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})"
  match <- regmatches(x, regexec(paste0("^(.*?)/content/", guid), x))[[1]]
  if (length(match) > 0) {
    return(list(server = match[2], guid = match[3]))
  }
  # Dashboard URLs: <server>[/connect]/#/apps/<guid>/...; the dashboard path
  # (default "/connect") is not part of the API base URL.
  match <- regmatches(
    x,
    regexec(paste0("^(.*?)(?:/connect)?/#/apps/", guid), x)
  )[[1]]
  if (length(match) > 0) {
    return(list(server = match[2], guid = match[3]))
  }
  NULL
}

# Find the project's Connect deployment record (written by rsconnect under
# rsconnect/). The record's `url` field carries the content GUID.
find_rsconnect_deployment <- function(dir = getwd()) {
  files <- rsconnect_record_files(dir)
  if (length(files) == 0) {
    return(NULL)
  }

  deployments <- drop_nulls(lapply(files, read_deployment_record))
  if (length(deployments) == 0) {
    return(NULL)
  }

  if (length(deployments) > 1) {
    mtimes <- vapply(
      deployments,
      function(dep) as.numeric(file.mtime(dep$file)),
      numeric(1)
    )
    deployments <- deployments[order(mtimes, decreasing = TRUE)]
    cli::cli_inform(
      "Reading trajectories for the most recent deployment,
       {.val {deployments[[1]]$name}} on {.url {deployments[[1]]$server}}."
    )
  }

  deployments[[1]]
}

# Walk a few levels down looking for rsconnect/ directories rather than
# listing every file under `dir`: projects routinely carry trees (renv/,
# data/) that a full recursive listing would crawl.
rsconnect_record_files <- function(dir, max_depth = 3) {
  files <- character()
  level <- dir
  for (depth in seq_len(max_depth)) {
    hits <- file.path(level, "rsconnect")
    hits <- hits[dir.exists(hits)]
    files <- c(
      files,
      list.files(hits, pattern = "[.]dcf$", recursive = TRUE, full.names = TRUE)
    )
    level <- unlist(
      lapply(level, list.dirs, recursive = FALSE),
      use.names = FALSE
    )
    keep <- !grepl("^[.]", basename(level)) &
      !basename(level) %in% c("rsconnect", "renv", "packrat", "node_modules")
    level <- level[keep]
    if (length(level) == 0) {
      break
    }
  }
  files
}

read_deployment_record <- function(file) {
  fields <- tryCatch(
    as.list(as.data.frame(read.dcf(file), stringsAsFactors = FALSE)),
    error = function(err) NULL
  )
  if (is.null(fields) || is.null(fields$url)) {
    return(NULL)
  }

  match <- regmatches(
    fields$url,
    regexec(
      "/content/([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})",
      fields$url
    )
  )[[1]]
  if (length(match) == 0) {
    return(NULL)
  }

  server <- fields$hostUrl %||% ""
  server <- sub("/__api__/?$", "", server)
  if (!nzchar(server)) {
    return(NULL)
  }

  list(
    guid = match[2],
    server = server,
    name = fields$name %||% basename(file),
    file = file
  )
}

# OTLP NDJSON parsing ---------------------------------------------------

read_local_spans <- function(path) {
  if (!dir.exists(path)) {
    return(list())
  }
  files <- list.files(
    path,
    pattern = local_traces_pattern(),
    full.names = TRUE
  )
  lines <- unlist(lapply(files, readLines, warn = FALSE))
  parse_otlp_lines(lines)
}

# Numbered rotation files only: the exporter also writes a
# trace-latest.jsonl hardlink to the newest file, which would duplicate its
# spans. Mirrors Connect's own glob. When the file exporter was pointed at a
# custom filename template, files named from that template match too.
local_traces_pattern <- function() {
  patterns <- "trace(-[0-9]+)?[.]jsonl"
  template <- basename(Sys.getenv("OTEL_EXPORTER_OTLP_TRACES_FILE"))
  if (nzchar(template)) {
    escaped <- gsub("([][{}()+*^$|\\\\?.])", "\\\\\\1", template)
    patterns <- c(patterns, gsub("%N", "[0-9]+", escaped, fixed = TRUE))
  }
  paste0("^(", paste(unique(patterns), collapse = "|"), ")$")
}

# Each NDJSON line is a full OTLP envelope: {"resourceSpans": [{"scopeSpans":
# [{"spans": [...]}]}]}. Malformed lines are skipped, matching Connect's own
# reader.
parse_otlp_lines <- function(lines) {
  spans <- list()
  for (line in lines) {
    envelope <- tryCatch(
      jsonlite::fromJSON(line, simplifyVector = FALSE),
      error = function(err) NULL
    )
    if (is.null(envelope)) {
      next
    }
    for (resource_spans in envelope$resourceSpans) {
      for (scope_spans in resource_spans$scopeSpans) {
        for (span in scope_spans$spans) {
          spans[[length(spans) + 1]] <- otlp_span(span)
        }
      }
    }
  }
  spans
}

otlp_span <- function(span) {
  list(
    trace_id = span$traceId %||% "",
    span_id = span$spanId %||% "",
    parent_span_id = span$parentSpanId %||% "",
    name = span$name %||% "",
    start_time = as.character(span$startTimeUnixNano %||% ""),
    end_time = as.character(span$endTimeUnixNano %||% ""),
    attributes = otlp_attributes(span$attributes)
  )
}

otlp_attributes <- function(attributes) {
  values <- lapply(
    attributes,
    function(attribute) otlp_attribute_value(attribute$value)
  )
  rlang::set_names(
    values,
    vapply(attributes, function(attribute) attribute$key, character(1))
  )
}

otlp_attribute_value <- function(value) {
  if (!is.null(value$stringValue)) {
    return(value$stringValue)
  }
  if (!is.null(value$intValue)) {
    return(as.numeric(value$intValue))
  }
  if (!is.null(value$doubleValue)) {
    return(value$doubleValue)
  }
  if (!is.null(value$boolValue)) {
    return(value$boolValue)
  }
  if (!is.null(value$arrayValue)) {
    return(lapply(value$arrayValue$values, otlp_attribute_value))
  }
  value
}

# Reconstruction ---------------------------------------------------------

# Matches Connect's own from/to filter: span start time, `from` inclusive,
# `to` exclusive. Only chat spans are filtered; parent spans must survive
# regardless, since they carry the conversation ids that group the rest.
filter_chat_spans <- function(spans, from, to) {
  if (is.null(from) && is.null(to)) {
    return(spans)
  }
  from_key <- if (!is.null(from)) pad_nano_time(posixct_nanos(from))
  to_key <- if (!is.null(to)) pad_nano_time(posixct_nanos(to))
  Filter(
    function(span) {
      if (!is_chat_span(span)) {
        return(TRUE)
      }
      start <- pad_nano_time(span$start_time)
      (is.null(from_key) || start >= from_key) &&
        (is.null(to_key) || start < to_key)
    },
    spans
  )
}

is_chat_span <- function(span) {
  identical(span$attributes[["gen_ai.operation.name"]], "chat")
}

split_exchanges <- function(turns) {
  out <- list()
  current <- NULL
  for (turn in turns) {
    if (identical(turn@role, "user") && !turn_has_tool_result(turn)) {
      if (!is.null(current)) {
        out[[length(out) + 1]] <- current
      }
      current <- list(turn)
    } else if (!is.null(current)) {
      current[[length(current) + 1]] <- turn
    }
  }
  if (!is.null(current)) {
    out[[length(out) + 1]] <- current
  }
  out
}

turn_has_tool_result <- function(turn) {
  any(vapply(turn@contents, is_tool_result_content, logical(1)))
}

# Edited histories make exchange ordinals unstable, so match reconstructed content.
exchange_signature <- function(exchange) {
  lapply(exchange, turn_signature)
}

turn_signature <- function(turn) {
  list(
    role = turn@role,
    contents = lapply(turn@contents, content_signature)
  )
}

content_signature <- function(content) {
  if (S7::S7_inherits(content, ellmer::ContentText)) {
    return(list(type = "text", text = content@text))
  }
  if (S7::S7_inherits(content, ellmer::ContentToolRequest)) {
    return(list(
      type = "tool_request",
      id = content@id,
      name = content@name,
      arguments = canonical_semantic_value(content@arguments)
    ))
  }
  if (S7::S7_inherits(content, ellmer::ContentToolResult)) {
    request_id <- if (is.null(content@request)) {
      NA_character_
    } else {
      content@request@id
    }
    return(list(
      type = "tool_result",
      id = request_id,
      value = canonical_semantic_value(content@value)
    ))
  }
  list(type = class(content)[[1]])
}

canonical_semantic_value <- function(value) {
  if (!is.list(value)) {
    return(value)
  }
  value <- lapply(value, canonical_semantic_value)
  if (!is.null(names(value))) {
    value <- value[order(names(value))]
  }
  value
}

exchange_prefix_matches <- function(candidate, canonical) {
  length(candidate) > 0 &&
    length(candidate) <= length(canonical) &&
    identical(candidate, canonical[seq_along(candidate)])
}

exchange_is_complete <- function(exchange) {
  if (length(exchange) < 2) {
    return(FALSE)
  }
  final <- exchange[[length(exchange)]]
  identical(final@role, "assistant") &&
    !any(vapply(
      final@contents,
      function(content) {
        S7::S7_inherits(content, ellmer::ContentToolRequest)
      },
      logical(1)
    ))
}

posixct_nanos <- function(time) {
  sprintf("%.0f", as.numeric(time) * 1e9)
}

# ellmer's chat spans repeat the full message history, so the latest chat
# span in a conversation carries the whole trajectory: group chat spans by
# conversation, keep the last one, and parse its GenAI-semconv messages.
build_trajectories <- function(spans) {
  index <- span_index(spans)
  chat_spans <- Filter(is_chat_span, spans)
  if (length(chat_spans) == 0) {
    return(list())
  }
  latest <- latest_chat_spans(chat_spans)
  provenance_spans <- latest_provenance_spans(spans, index)
  calls <- latest_recorded_call_spans(chat_spans, index, provenance_spans)
  selected <- c(
    unname(latest),
    lapply(calls, function(call) call$chat_span)
  )
  parsed <- parse_chat_spans_once(selected)
  candidates <- recorded_call_candidates(calls, parsed)

  Map(
    function(span, id) {
      turns <- parsed[[exchange_key(span)]]
      exchanges <- split_exchanges(turns)
      attr(turns, "last_active") <- nano_posixct(span_time(span))
      attr(turns, "provenance") <- associate_exchange_provenance(
        exchanges,
        candidates[[id]],
        id
      )
      turns
    },
    latest,
    names(latest)
  )
}

# Second precision is sufficient; the origin supports R < 4.3.
nano_posixct <- function(time) {
  as.POSIXct(as.numeric(time) / 1e9, origin = "1970-01-01")
}

# The latest chat span per conversation, named by conversation id and
# ordered oldest-first.
latest_chat_spans <- function(chat_spans) {
  if (length(chat_spans) == 0) {
    return(list())
  }

  latest <- list()
  for (span in chat_spans) {
    id <- span_conversation_id(span)
    prev <- latest[[id]]
    if (is.null(prev) || span_time(span) > span_time(prev)) {
      latest[[id]] <- span
    }
  }

  latest[order(vapply(latest, span_time, character(1)))]
}

empty_turn_provenance <- function() {
  list(provenance_tag = NA_character_, citation_decisions = list())
}

latest_provenance_spans <- function(spans, index) {
  latest <- list()
  provenance_spans <- Filter(
    function(span) identical(span$name, "commons_provenance"),
    spans
  )
  for (span in provenance_spans) {
    turn_span <- conversation_turn_ancestor(span, index)
    if (is.null(turn_span)) {
      next
    }
    key <- exchange_key(turn_span)
    previous <- latest[[key]]
    if (is.null(previous) || span_time(span) > span_time(previous)) {
      latest[[key]] <- span
    }
  }
  latest
}

latest_recorded_call_spans <- function(
  chat_spans,
  index,
  provenance_spans = list()
) {
  latest <- list()
  for (span in chat_spans) {
    turn_span <- conversation_turn_ancestor(span, index)
    if (is.null(turn_span)) {
      next
    }
    key <- exchange_key(turn_span)
    previous <- latest[[key]]
    if (
      is.null(previous) ||
        span_time(span) > span_time(previous$chat_span)
    ) {
      latest[[key]] <- list(
        conversation_id = span_conversation_id(span),
        turn_span = turn_span,
        provenance_span = provenance_spans[[key]] %||% turn_span,
        chat_span = span
      )
    }
  }
  latest
}

parse_chat_spans_once <- function(spans) {
  keys <- vapply(spans, exchange_key, character(1))
  spans <- spans[!duplicated(keys)]
  rlang::set_names(lapply(spans, trajectory_turns), keys[!duplicated(keys)])
}

recorded_call_candidates <- function(call_spans, parsed_turns) {
  candidates <- list()
  for (call in call_spans) {
    turns <- parsed_turns[[exchange_key(call$chat_span)]]
    exchanges <- split_exchanges(turns)
    if (
      length(exchanges) == 0 ||
        !exchange_is_complete(exchanges[[length(exchanges)]])
    ) {
      next
    }
    id <- call$conversation_id
    candidates[[id]] <- c(
      candidates[[id]],
      list(list(
        signature = lapply(exchanges, exchange_signature),
        provenance = turn_span_provenance(call$provenance_span)
      ))
    )
  }
  candidates
}

associate_exchange_provenance <- function(
  exchanges,
  candidates,
  conversation_id
) {
  records <- rep(list(empty_turn_provenance()), length(exchanges))
  canonical <- lapply(exchanges, exchange_signature)
  claims <- vector("list", length(exchanges))

  for (candidate in candidates %||% list()) {
    if (!exchange_prefix_matches(candidate$signature, canonical)) {
      next
    }
    index <- length(candidate$signature)
    claims[[index]] <- c(claims[[index]], list(candidate$provenance))
  }

  ambiguous <- FALSE
  for (i in seq_along(claims)) {
    distinct <- distinct_provenance_records(claims[[i]])
    if (length(distinct) == 1) {
      records[[i]] <- distinct[[1]]
    } else if (length(distinct) > 1) {
      ambiguous <- TRUE
    }
  }

  if (ambiguous) {
    cli::cli_warn(
      "Ignoring conflicting audit records in conversation
       {.val {conversation_id}}."
    )
  }
  records
}

distinct_provenance_records <- function(records) {
  out <- list()
  for (record in records) {
    duplicate <- any(vapply(
      out,
      function(existing) identical(existing, record),
      logical(1)
    ))
    if (!duplicate) {
      out[[length(out) + 1]] <- record
    }
  }
  out
}

exchange_key <- function(span) {
  paste(span$trace_id, span$span_id)
}

# Read provenance from managed spans; missing data fails closed.
turn_span_provenance <- function(turn_span) {
  tag <- turn_span$attributes[["commons.provenance.tag"]]
  candidates <- turn_span$attributes[["commons.citation.candidates"]]
  list(
    provenance_tag = if (is.null(tag)) NA_character_ else as.character(tag),
    citation_decisions = if (is.null(candidates)) {
      list()
    } else {
      tryCatch(
        jsonlite::fromJSON(candidates, simplifyVector = FALSE) %||% list(),
        error = function(...) list()
      )
    }
  )
}

conversation_turn_ancestor <- function(span, index) {
  current <- span
  for (i in seq_len(length(index))) {
    if (identical(current$name, "commons_conversation_turn")) {
      return(current)
    }
    if (!nzchar(current$parent_span_id)) {
      return(NULL)
    }
    current <- index[[paste(span$trace_id, current$parent_span_id)]]
    if (is.null(current)) {
      return(NULL)
    }
  }
  NULL
}

span_index <- function(spans) {
  rlang::set_names(
    spans,
    vapply(
      spans,
      function(span) paste(span$trace_id, span$span_id),
      character(1)
    )
  )
}

# ellmer stamps the conversation id on its own chat spans (from the client's
# `conversation_id` binding, allocated by shinychat). Chat spans with no
# id—e.g. emitted outside shinychat—fall back to their trace id, which
# still groups per turn.
span_conversation_id <- function(span) {
  id <- span$attributes[["gen_ai.conversation.id"]]
  if (is.null(id)) span$trace_id else as.character(id)
}

# A chain is severed when a parent is absent from `index` -- ancestry cut
# off by a partial fetch -- as opposed to reaching its root, which no wider
# fetch would fix. Turn-level data (provenance, recorded calls) resolves
# through `conversation_turn_ancestor()`, which stops at the turn wrapper,
# so ancestors above it (added by instrumented hosts) don't count.
ancestry_severed <- function(span, index) {
  current <- span
  for (i in seq_len(length(index))) {
    if (identical(current$name, "commons_conversation_turn")) {
      return(FALSE)
    }
    if (!nzchar(current$parent_span_id)) {
      return(FALSE)
    }
    current <- index[[paste(span$trace_id, current$parent_span_id)]]
    if (is.null(current)) {
      return(TRUE)
    }
  }
  FALSE
}

has_severed_ancestry <- function(spans) {
  index <- span_index(spans)
  chat_spans <- Filter(is_chat_span, spans)
  any(vapply(
    chat_spans,
    function(span) ancestry_severed(span, index),
    logical(1)
  ))
}

span_time <- function(span) {
  time <- if (nzchar(span$end_time)) span$end_time else span$start_time
  pad_nano_time(time)
}

# Unix-nano timestamps overflow doubles, so compare them as zero-padded
# strings, which order lexicographically like the numbers they encode.
# (Zero- rather than space-padded: some locales' collation ignores spaces.)
pad_nano_time <- function(time) {
  paste0(strrep("0", max(0, 32 - nchar(time))), time)
}

trajectory_turns <- function(span) {
  requests <- new.env(parent = emptyenv())
  attributes <- span$attributes
  turns <- c(
    semconv_system_turns(attributes[["gen_ai.system_instructions"]]),
    semconv_message_turns(attributes[["gen_ai.input.messages"]], requests),
    semconv_message_turns(attributes[["gen_ai.output.messages"]], requests)
  )
  unname(turns)
}

semconv_system_turns <- function(json) {
  parts <- parse_semconv_json(json)
  if (is.null(parts)) {
    return(list())
  }
  contents <- drop_nulls(lapply(parts, semconv_part_content))
  if (length(contents) == 0) {
    return(list())
  }
  list(ellmer::SystemTurn(contents = contents))
}

semconv_message_turns <- function(json, requests) {
  messages <- parse_semconv_json(json)
  if (is.null(messages)) {
    return(list())
  }
  drop_nulls(lapply(messages, semconv_turn, requests = requests))
}

parse_semconv_json <- function(json) {
  if (is.null(json) || !nzchar(json)) {
    return(NULL)
  }
  tryCatch(
    jsonlite::fromJSON(json, simplifyVector = FALSE),
    error = function(err) NULL
  )
}

# Tool-result turns are emitted with role "tool" (matching Python's GenAI
# instrumentations); ellmer represents them as UserTurns.
semconv_turn <- function(message, requests) {
  contents <- drop_nulls(
    lapply(message$parts, semconv_part_content, requests = requests)
  )
  if (length(contents) == 0) {
    return(NULL)
  }
  switch(
    message$role %||% "",
    assistant = ellmer::AssistantTurn(contents = contents),
    user = ,
    tool = ellmer::UserTurn(contents = contents),
    system = ellmer::SystemTurn(contents = contents),
    NULL
  )
}

# The inverse of ellmer's as_otel_part(). `generic` parts (content classes
# with no semconv representation) don't carry enough to rebuild and are
# dropped.
semconv_part_content <- function(part, requests = NULL) {
  switch(
    part$type %||% "",
    text = ellmer::ContentText(as.character(part$content %||% "")),
    tool_call = semconv_tool_request(part, requests),
    tool_call_response = semconv_tool_result(part, requests),
    NULL
  )
}

semconv_tool_request <- function(part, requests) {
  request <- ellmer::ContentToolRequest(
    id = as.character(part$id %||% ""),
    name = as.character(part$name %||% ""),
    arguments = as.list(part$arguments)
  )
  if (!is.null(requests) && nzchar(request@id)) {
    assign(request@id, request, envir = requests)
  }
  request
}

semconv_tool_result <- function(part, requests) {
  request <- NULL
  if (!is.null(requests) && !is.null(part$id)) {
    request <- get0(as.character(part$id), envir = requests)
  }
  ellmer::ContentToolResult(value = part$response, request = request)
}
