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
      httr2_http_403 = function(err) trace_access_abort(err, call)
    )
    page <- httr2::resp_body_string(resp)
    page <- strsplit(page, "\n", fixed = TRUE)[[1]]
    page <- page[nzchar(page)]
    lines <- c(lines, page)
    total <- suppressWarnings(
      as.integer(httr2::resp_header(resp, "X-Total-Count"))
    )
    offset <- offset + length(page)
    if (length(page) == 0 || is.na(total) || offset >= total) {
      break
    }
    if (!is.null(enough) && enough(lines)) {
      break
    }
  }
  lines
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
