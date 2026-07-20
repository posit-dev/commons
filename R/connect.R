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

# Fetch all trace rows for a content item as raw OTLP NDJSON lines, paging
# until the X-Total-Count header is exhausted.
connect_trace_lines <- function(client, guid, page_size = 1000) {
  lines <- character()
  offset <- 0
  repeat {
    resp <- connect_req(client, "content", guid, "traces") |>
      httr2::req_url_query(limit = page_size, offset = offset) |>
      httr2::req_perform()
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
  }
  lines
}

connect_user_guid <- function(client, username, call = rlang::caller_env()) {
  resp <- connect_req(client, "users") |>
    httr2::req_url_query(prefix = username, page_size = 500) |>
    httr2::req_perform() |>
    httr2::resp_body_json()
  for (user in resp$results) {
    if (identical(tolower(user$username), tolower(username))) {
      return(user$guid)
    }
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
