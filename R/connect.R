# A minimal Posit Connect API client for the two things commons needs from
# Connect: reading content traces and granting collaborator access.

is_connect_runtime <- function() {
  identical(Sys.getenv("POSIT_PRODUCT"), "CONNECT") ||
    nzchar(Sys.getenv("CONNECT_CONTENT_GUID"))
}

connect_content_guid <- function() {
  Sys.getenv("CONNECT_CONTENT_GUID")
}

connect_client <- function(
  server = NULL,
  api_key = NULL,
  call = rlang::caller_env()
) {
  server <- server %||% Sys.getenv("CONNECT_SERVER")
  api_key <- api_key %||% Sys.getenv("CONNECT_API_KEY")
  if (!nzchar(server)) {
    cli::cli_abort(
      "Set the {.envvar CONNECT_SERVER} environment variable to your Posit
       Connect server URL.",
      call = call
    )
  }
  if (!nzchar(api_key)) {
    cli::cli_abort(
      "Set the {.envvar CONNECT_API_KEY} environment variable to a Posit
       Connect API key.",
      call = call
    )
  }
  server <- sub("/+$", "", server)
  server <- sub("/__api__$", "", server)
  list(server = server, api_key = api_key)
}

connect_req <- function(client, ...) {
  httr2::request(client$server) |>
    httr2::req_url_path_append("__api__", "v1", ...) |>
    httr2::req_headers_redacted(Authorization = paste("Key", client$api_key))
}

# Fetch trace rows for a content item as raw OTLP NDJSON lines, paging until
# the X-Total-Count header is exhausted or `enough(lines)` returns TRUE.
# Connect returns rows newest-first by span start time and filters `from`/`to`
# on span start time over `[from, to)`.
connect_trace_lines <- function(
  client,
  guid,
  from = NULL,
  to = NULL,
  enough = NULL,
  page_size = 1000,
  call = rlang::caller_env()
) {
  lines <- character()
  offset <- 0
  version <- NULL
  repeat {
    resp <- tryCatch(
      connect_req(client, "content", guid, "traces") |>
        httr2::req_url_query(
          limit = page_size,
          offset = offset,
          from = connect_window_param(from, -3600),
          to = connect_window_param(to, 1)
        ) |>
        httr2::req_perform(),
      httr2_http_401 = function(err) trace_access_abort(err, call),
      httr2_http_403 = function(err) trace_access_abort(err, call),
      httr2_http_404 = function(err) NULL
    )
    if (is.null(resp)) {
      return(connect_job_trace_lines(
        client, guid, from, enough, page_size, call
      ))
    }
    version <- version %||% connect_server_version(resp)
    page <- resp_trace_lines(resp)
    lines <- c(lines, page)
    total <- suppressWarnings(
      as.integer(httr2::resp_header(resp, "X-Total-Count"))
    )
    offset <- offset + length(page)
    if (length(lines) > 0 && !is.null(enough) && enough(lines)) {
      return(lines)
    }
    if (length(page) == 0 || is.na(total) || offset >= total) {
      break
    }
  }
  # Connect 2026.07 moved new traces without migrating the per-job files.
  if (is.null(version) || version >= numeric_version("2026.07.0")) {
    lines <- connect_job_trace_lines(
      client, guid, from, enough, page_size, call, lines
    )
  }
  unique(lines)
}

connect_job_trace_lines <- function(
  client,
  guid,
  from,
  enough,
  page_size,
  call,
  lines = character()
) {
  jobs <- tryCatch(
    connect_req(client, "content", guid, "jobs") |>
      httr2::req_perform() |>
      httr2::resp_body_json(),
    httr2_http_401 = function(err) trace_access_abort(err, call),
    httr2_http_403 = function(err) trace_access_abort(err, call)
  )
  starts <- vapply(jobs, function(job) job$start_time %||% "", character(1))
  jobs <- jobs[order(starts, decreasing = TRUE)]

  for (job in jobs) {
    offset <- 0
    repeat {
      resp <- tryCatch(
        connect_req(client, "content", guid, "jobs", job$key, "traces") |>
          httr2::req_url_query(
            limit = page_size,
            offset = offset,
            since = connect_window_param(from, -3600)
          ) |>
          httr2::req_perform(),
        httr2_http_401 = function(err) trace_access_abort(err, call),
        httr2_http_403 = function(err) trace_access_abort(err, call),
        httr2_http_404 = function(err) NULL
      )
      if (is.null(resp)) {
        break
      }
      page <- resp_trace_lines(resp)
      lines <- c(lines, page)
      total <- suppressWarnings(
        as.integer(httr2::resp_header(resp, "X-Total-Count"))
      )
      offset <- offset + length(page)
      if (length(lines) > 0 && !is.null(enough) && enough(lines)) {
        return(unique(lines))
      }
      if (length(page) == 0 || is.na(total) || offset >= total) {
        break
      }
    }
  }
  lines
}

resp_trace_lines <- function(resp) {
  if (!httr2::resp_has_body(resp)) {
    return(character())
  }
  page <- httr2::resp_body_string(resp)
  page <- strsplit(page, "\n", fixed = TRUE)[[1]]
  page[nzchar(page)]
}

connect_server_version <- function(resp) {
  server <- httr2::resp_header(resp, "Server")
  if (is.null(server)) {
    return(NULL)
  }
  match <- regexec("Posit Connect v([0-9]+(?:\\.[0-9]+){1,2})", server)
  version <- regmatches(server, match)[[1]]
  if (length(version) == 0) {
    return(NULL)
  }
  numeric_version(version[[2]])
}

# Connect silently ignores timestamps it can't parse, including any without
# an explicit timezone, so always format the query bounds here. The exact
# window is applied client-side, so bounds are padded outward: `from` by an
# hour, to keep the earlier-starting parent spans that carry conversation
# ids, and `to` by a second, to cover sub-second truncation in formatting.
connect_window_param <- function(time, pad) {
  if (is.null(time)) {
    return(NULL)
  }
  format(time + pad, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
}

connect_content <- function(client, guid) {
  connect_req(client, "content", guid) |>
    httr2::req_perform() |>
    httr2::resp_body_json()
}

connect_enable_otel <- function(client, guid) {
  connect_req(client, "content", guid) |>
    httr2::req_method("PATCH") |>
    httr2::req_body_json(list(otel_enabled = TRUE)) |>
    httr2::req_perform()
  invisible(NULL)
}

# An auth failure on the traces endpoint nearly always means the API key's
# user fails the endpoint's editor-level permission check, not that traces
# don't exist; say so rather than surfacing a bare 401/403.
trace_access_abort <- function(err, call) {
  cli::cli_abort(
    c(
      "Couldn't read this content's traces from Posit Connect.",
      i = "Reading traces requires editor access: the {.envvar
           CONNECT_API_KEY} user must own the content or be a collaborator.
           See the {.arg share_with} argument of {.fn commons}."
    ),
    parent = err,
    call = call
  )
}

# Prefix search over users, paging like Connect's own full-listing loop: a
# page shorter than page_size is the last one.
connect_user_guid <- function(client, username, call = rlang::caller_env()) {
  page_size <- 500
  page_number <- 1
  repeat {
    resp <- connect_req(client, "users") |>
      httr2::req_url_query(
        prefix = username,
        page_size = page_size,
        page_number = page_number
      ) |>
      httr2::req_perform() |>
      httr2::resp_body_json()
    for (user in resp$results) {
      if (identical(tolower(user$username), tolower(username))) {
        return(user$guid)
      }
    }
    if (length(resp$results) < page_size) {
      break
    }
    page_number <- page_number + 1
  }
  cli::cli_abort(
    "No Connect user with username {.val {username}}.",
    call = call
  )
}

connect_permission_principals <- function(client, guid) {
  perms <- connect_req(client, "content", guid, "permissions") |>
    httr2::req_perform() |>
    httr2::resp_body_json()
  vapply(perms, function(perm) perm$principal_guid, character(1))
}

# Reading a content item's traces requires editor-level access, which
# Connect's permissions API grants via the "owner" (collaborator) role;
# "editor" is not an accepted role string there.
connect_add_collaborator <- function(client, guid, principal_guid) {
  connect_req(client, "content", guid, "permissions") |>
    httr2::req_body_json(list(
      principal_guid = principal_guid,
      principal_type = "user",
      role = "owner",
      send_email = FALSE
    )) |>
    httr2::req_perform()
  invisible(NULL)
}
