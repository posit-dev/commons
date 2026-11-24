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
    if (identical(case[["error"]], "missing")) {
      err <- expect_error(read(), spec[["missing_error"]], fixed = TRUE, info = info)
      message <- conditionMessage(err)
      expect_match(message, "ea3c1445-cb71-42df-a2f2-bdb18874ef41", fixed = TRUE, info = info)
      expect_match(message, "https://connect.example.com", fixed = TRUE, info = info)
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

# Write a case's `files` into `dir`, then set each `mtime`.
write_fixture_files <- function(dir, case) {
  for (name in names(case[["files"]])) {
    path <- file.path(dir, name)
    dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
    writeLines(unlist(case[["files"]][[name]]), path)
  }
  for (name in names(case[["mtime"]])) {
    Sys.setFileTime(file.path(dir, name), .POSIXct(case[["mtime"]][[name]], tz = "UTC"))
  }
}

expect_deployment_member <- function(member) {
  expect_gt(length(member[["cases"]]), 0)
  for (case in member[["cases"]]) {
    info <- case[["name"]]
    dir <- withr::local_tempdir()
    write_fixture_files(dir, case)
    found <- record_notices(find_rsconnect_deployment(dir))
    notices <- found$notices
    found <- found$value
    actual <- if (is.null(found)) {
      NULL
    } else {
      list(guid = found$guid, server = sub("/+(__api__/*)?$", "", found$server))
    }
    expect_identical(actual, case[["expected"]], info = info)
    expect_identical(notices, unlist(case[["notice"]]) %||% character(), info = info)
  }
}

# `expr`'s value, and its warnings and messages in order, as `notice` names
# them.
record_notices <- function(expr) {
  notices <- character()
  value <- withCallingHandlers(
    expr,
    warning = function(cnd) {
      notices <<- c(notices, "warning")
      invokeRestart("muffleWarning")
    },
    message = function(cnd) {
      notices <<- c(notices, "message")
      invokeRestart("muffleMessage")
    }
  )
  list(value = value, notices = notices)
}

# The environment trajectories/connect.json starts each case with, then `env`.
connect_fixture_env <- function(env = list()) {
  values <- c(
    POSIT_PRODUCT = NA,
    CONNECT_CONTENT_GUID = NA,
    CONNECT_SERVER = NA,
    OTEL_EXPORTER_OTLP_TRACES_FILE = NA,
    COMMONS_TRACES_DIR = NA,
    CONNECT_API_KEY = "key"
  )
  for (name in names(env)) {
    values[[name]] <- env[[name]] %||% NA
  }
  values
}

expect_source_member <- function(member) {
  expect_gt(length(member[["cases"]]), 0)
  for (case in member[["cases"]]) {
    local({
      info <- case[["name"]]
      dir <- withr::local_tempdir()
      write_fixture_files(dir, case)
      withr::local_dir(dir)
      withr::local_envvar(connect_fixture_env(case[["env"]]))
      # Keeps a developer's rsconnect accounts out of the cases.
      registered <- unlist(case[["registered"]]) %||% character()
      local_mocked_bindings(registered_connect_servers = function() registered)
      if (!is.null(case[["search"]])) {
        httr2::local_mocked_responses(
          connect_fixture_responses(list(), new.env(), search = case[["search"]])
        )
      }
      expected <- case[["expected"]]
      if (!is.null(expected[["error"]])) {
        err <- expect_error(resolve_trajectory_source(case[["source"]]), info = info)
        expect_true(
          grepl(expected[["error"]], gsub("\\s+", " ", conditionMessage(err)), fixed = TRUE),
          info = info
        )
        return()
      }
      resolved <- record_notices(resolve_trajectory_source(case[["source"]]))
      expect_identical(
        resolved$notices,
        unlist(case[["notice"]]) %||% character(),
        info = info
      )
      resolved <- resolved$value
      expect_identical(resolved$kind, expected[["kind"]], info = info)
      if (identical(expected[["kind"]], "connect")) {
        expect_identical(resolved$guid, expected[["guid"]], info = info)
        expect_identical(resolved$client$server, expected[["server"]], info = info)
      }
    })
  }
}

connect_fixture_lines <- function(lines) {
  vapply(lines, connect_fixture_line, character(1))
}

# One enough_trace_lines() checker per case, called after each line with all
# the lines so far.
expect_enough_member <- function(member) {
  expect_gt(length(member[["cases"]]), 0)
  for (case in member[["cases"]]) {
    enough <- enough_trace_lines(
      case[["n"]],
      fixture_instant(case[["since"]]),
      fixture_instant(case[["until"]])
    )
    lines <- connect_fixture_lines(case[["lines"]])
    answers <- vapply(
      seq_along(lines),
      function(i) enough(lines[seq_len(i)]),
      logical(1)
    )
    expect_identical(answers, unlist(case[["expected"]]), info = case[["name"]])
  }
}

expect_connect_read_member <- function(member) {
  guid <- "ea3c1445-cb71-42df-a2f2-bdb18874ef41"
  expect_gt(length(member[["cases"]]), 0)
  for (case in member[["cases"]]) {
    local({
      info <- case[["name"]]
      withr::local_dir(withr::local_tempdir())
      withr::local_envvar(
        connect_fixture_env(list(CONNECT_SERVER = "https://connect.example.com"))
      )
      state <- new.env()
      empty_read <- !is.null(case[["hints"]])
      httr2::local_mocked_responses(if (empty_read) {
        connect_fixture_responses(
          list(version = "2026.09.0", traces = case[["traces"]] %||% list(), jobs = list()),
          state,
          content = case[["content"]],
          settings = case[["settings"]]
        )
      } else {
        connect_fixture_responses(case[["server"]], state)
      })
      notices <- character()
      warnings <- character()
      trajectories <- withCallingHandlers(
        trajectory_read(
          guid,
          n = case[["n"]],
          from = fixture_instant(case[["since"]]),
          to = fixture_instant(case[["until"]])
        ),
        warning = function(cnd) {
          notices <<- c(notices, "warning")
          warnings <<- c(warnings, conditionMessage(cnd))
          invokeRestart("muffleWarning")
        },
        message = function(cnd) {
          notices <<- c(notices, "message")
          invokeRestart("muffleMessage")
        }
      )

      if (empty_read) {
        hints <- unlist(case[["hints"]]) %||% character()
        expect_trajectories(trajectories, case[["trajectories"]] %||% list(), info)
        if (length(hints) == 0) {
          expect_identical(warnings, character(), info = info)
          return()
        }
        expect_equal(length(warnings), 1, info = info)
        text <- gsub("\\s+", " ", warnings[[1]])
        expect_true(startsWith(text, member[["message"]]), info = info)
        expect_identical(
          grepl("Settings > Monitoring", text, fixed = TRUE),
          "content" %in% hints,
          info = info
        )
        expect_identical(
          grepl("AllowContentInstrumentation", text, fixed = TRUE),
          "server" %in% hints,
          info = info
        )
        return()
      }

      traces_path <- paste0("/content/", guid, "/traces")
      queries <- lapply(
        Filter(function(r) endsWith(r[["path"]], traces_path), state$requests),
        function(r) r[["query"]]
      )
      expect_identical(queries, case[["trace_queries"]], info = info)
      if (!is.null(case[["job_queries"]])) {
        job_queries <- lapply(
          Filter(
            function(r) grepl("/jobs/[^/]+/traces$", r[["path"]]),
            state$requests
          ),
          function(r) r[["query"]]
        )
        expect_identical(job_queries, case[["job_queries"]], info = info)
      }
      expect_identical(
        notices,
        unlist(case[["notice"]]) %||% character(),
        info = info
      )
      expect_trajectories(trajectories, case[["trajectories"]], info)
    })
  }
}
