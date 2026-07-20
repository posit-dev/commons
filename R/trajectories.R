#' Read commons trajectories
#'
#' @description
#' `read_trajectories()` reads conversation trajectories captured by
#' [commons()] when `log = TRUE`. Trajectories are recorded as OpenTelemetry
#' spans—see the `log` argument of [commons()] for how capture is enabled—and
#' read back from Posit Connect's content observability store or from local
#' trace files.
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
#'
#' @details
#' Reading traces from Connect requires the `CONNECT_API_KEY` environment
#' variable (and `CONNECT_SERVER`, when the server can't be inferred from the
#' project's deployment record), and editor-level access to the content: you
#' must own it or be a collaborator. See the `share_with` argument of
#' [commons()].
#'
#' @section Agent skill:
#' commons includes an agent skill scaffold for iterating on a deployed agent.
#' To locate it:
#'
#' ```r
#' system.file("skills", "commons", "SKILL.md", package = "commons")
#' ```
#'
#' To use it, copy the skill directory into your agent's skills directory,
#' like `./.agents/skills`:
#'
#' ```r
#' skill <- system.file("skills", "commons", package = "commons")
#' dir.create("./.agents/skills", recursive = TRUE, showWarnings = FALSE)
#' file.copy(skill, "./.agents/skills", recursive = TRUE)
#' ```
#'
#' @return A list of conversations, named by conversation id and ordered
#'   oldest-first. Each conversation is a list of [ellmer::Turn]s.
#' @export
read_trajectories <- function(source = NULL) {
  resolved <- resolve_trajectory_source(source)
  spans <- switch(
    resolved$kind,
    local = read_local_spans(resolved$path),
    connect = parse_otlp_lines(
      connect_trace_lines(resolved$client, resolved$guid)
    )
  )
  drop_contentless(build_trajectories(spans))
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

# ellmer's chat spans repeat the full message history, so the latest chat
# span in a conversation carries the whole trajectory: group chat spans by
# conversation, keep the last one, and parse its GenAI-semconv messages.
build_trajectories <- function(spans) {
  chat_spans <- Filter(
    function(span) {
      identical(span$attributes[["gen_ai.operation.name"]], "chat")
    },
    spans
  )
  if (length(chat_spans) == 0) {
    return(list())
  }

  index <- span_index(spans)
  latest <- list()
  for (span in chat_spans) {
    id <- span_conversation_id(span, index)
    prev <- latest[[id]]
    if (is.null(prev) || span_time(span) > span_time(prev)) {
      latest[[id]] <- span
    }
  }

  latest <- latest[
    order(vapply(latest, span_time, character(1)))
  ]
  lapply(latest, trajectory_turns)
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

# The conversation id lives on the commons wrapper span, which is not
# necessarily the chat span's direct parent (ellmer's invoke_agent span sits
# between, and instrumented hosts like Shiny may add ancestors above), so
# walk the ancestor chain. Chat spans with no wrapper anywhere—e.g. emitted
# outside commons—fall back to their trace id, which still groups per turn.
span_conversation_id <- function(span, index) {
  current <- span
  for (i in seq_len(length(index))) {
    id <- current$attributes[["gen_ai.conversation.id"]]
    if (!is.null(id)) {
      return(as.character(id))
    }
    if (!nzchar(current$parent_span_id)) {
      break
    }
    current <- index[[paste(span$trace_id, current$parent_span_id)]]
    if (is.null(current)) {
      break
    }
  }
  span$trace_id
}

# Unix-nano timestamps overflow doubles, so compare them as zero-padded
# strings, which order lexicographically like the numbers they encode.
# (Zero- rather than space-padded: some locales' collation ignores spaces.)
span_time <- function(span) {
  time <- if (nzchar(span$end_time)) span$end_time else span$start_time
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
