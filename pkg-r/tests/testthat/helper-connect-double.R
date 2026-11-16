connect_fixture_line <- function(line) {
  if (is.character(line)) line else otlp_test_line(lapply(line, trajectory_fixture_span))
}

connect_fixture_window <- function(x) {
  if (is.null(x)) NULL else as.numeric(as.POSIXct(x, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"))
}

# A Connect server double for httr2::local_mocked_responses(), as
# tests/shared/connect.json's `traces.double` describes it.
connect_fixture_responses <- function(server, state, content = list(), settings = list(), search = NULL) {
  state$requests <- list()
  json_response <- function(req, body) {
    httr2::new_response("GET", req$url, 200L, list(`Content-Type` = "application/json"),
      charToRaw(jsonlite::toJSON(body, auto_unbox = TRUE)), request = req)
  }
  status_response <- function(req, status) {
    httr2::new_response("GET", req$url, as.integer(status), list(), raw(), request = req)
  }
  serve_lines <- function(req, lines, query) {
    if (!is.null(lines[["status"]])) return(status_response(req, lines[["status"]]))
    from <- connect_fixture_window(query[["from"]] %||% query[["since"]])
    to <- connect_fixture_window(query[["to"]])
    keep <- Filter(function(line) {
      if (is.character(line)) return(TRUE)
      start <- as.numeric(line[[1]][["start"]] %||% "1") / 1e9
      (is.null(from) || start >= from) && (is.null(to) || start < to)
    }, lines)
    page <- keep[rlang::seq2(as.integer(query[["offset"]] %||% "0") + 1, length(keep))]
    if (!is.null(server[["page_size"]])) page <- utils::head(page, server[["page_size"]])
    headers <- list()
    if (!is.null(server[["version"]])) headers$Server <- paste0("Posit Connect v", server[["version"]])
    total <- server[["total"]] %||% length(keep)
    headers$`X-Total-Count` <- as.character(total)
    body <- paste0(vapply(page, connect_fixture_line, character(1)), "\n", collapse = "")
    httr2::new_response("GET", req$url, 200L, headers, charToRaw(body), request = req)
  }
  function(req) {
    url <- httr2::url_parse(req$url)
    query <- url$query %||% list()
    state$requests <- c(state$requests, list(list(path = url$path, query = query)))
    if (url$path == "/__api__/server_settings") {
      return(if (is.null(settings)) status_response(req, 500) else json_response(req, settings))
    }
    if (grepl("/search/content$", url$path)) {
      return(json_response(req, search[[as.integer(query[["page_number"]])]]))
    }
    rel <- sub("^.*/__api__/v1/content/[^/]+/?", "", url$path)
    if (rel == "") {
      return(if (is.null(content)) status_response(req, 500) else json_response(req, content))
    }
    if (rel == "traces") return(serve_lines(req, server[["traces"]], query))
    jobs <- server[["jobs"]] %||% list()
    if (rel == "jobs") {
      if (!is.null(jobs[["status"]])) return(status_response(req, jobs[["status"]]))
      return(json_response(req, lapply(jobs, function(job) list(key = job[["key"]]))))
    }
    key <- sub("^jobs/([^/]+)/traces$", "\\1", rel)
    for (job in jobs) {
      if (identical(job[["key"]], key)) return(serve_lines(req, job[["traces"]], query))
    }
    stop("Unexpected request to ", url$path)
  }
}

connect_fixture_request_key <- function(path, query) {
  pairs <- if (length(query) == 0) {
    character()
  } else {
    sort(paste0(names(query), "=", unlist(query, use.names = FALSE)))
  }
  paste(path, paste(pairs, collapse = "&"))
}

# Each request as its path relative to the content and its sorted query.
connect_fixture_request_keys <- function(requests) {
  vapply(
    requests,
    function(request) {
      connect_fixture_request_key(
        sub("^.*/__api__/v1/content/[^/]+/?", "", request[["path"]]),
        request[["query"]]
      )
    },
    character(1)
  )
}

expect_trace_lines_member <- function(member, spec) {
  expect_gt(length(member[["cases"]]), 0)
  for (case in member[["cases"]]) {
    info <- case[["name"]]
    state <- new.env()
    httr2::local_mocked_responses(connect_fixture_responses(case[["server"]], state))
    read <- function() {
      connect_trace_lines(
        list(server = "https://connect.example.com", api_key = "key"),
        "ea3c1445-cb71-42df-a2f2-bdb18874ef41",
        from = fixture_instant(case[["since"]]),
        to = fixture_instant(case[["until"]]),
        enough = if (isTRUE(case[["enough"]])) function(lines) TRUE
      )
    }
    if (identical(case[["error"]], "access")) {
      expect_error(read(), spec[["access_error"]], fixed = TRUE, info = info)
      next
    }
    if (identical(case[["error"]], "failed")) {
      err <- expect_error(read(), info = info)
      expect_false(
        startsWith(conditionMessage(err), spec[["access_error"]]),
        info = info
      )
      next
    }
    expect_identical(read(), unlist(case[["lines"]]) %||% character(), info = info)
    expected <- vapply(
      case[["requests"]],
      function(request) connect_fixture_request_key(request[["path"]], request[["query"]]),
      character(1)
    )
    expect_identical(
      sort(connect_fixture_request_keys(state$requests)),
      sort(expected),
      info = info
    )
  }
}
