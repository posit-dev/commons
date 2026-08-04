new_review_event <- function(
  trajectories,
  key,
  action,
  user,
  source = trajectory_source(trajectories),
  note = NULL
) {
  exchange <- key$exchange
  record <- list(
    schema_version = 1L,
    event_id = new_review_event_id(),
    time = review_timestamp(),
    user = user,
    source = source,
    conversation = names(trajectories)[[key$conversation]],
    exchange = exchange,
    action = action,
    note = note
  )

  if (!is.null(exchange)) {
    turns <- split_exchanges(trajectories[[key$conversation]])[[exchange]]
    provenance <- exchange_provenance(turns)
    record$question <- turns[[1]]@text
    record$tag <- if (is.na(provenance$tag)) "none" else provenance$tag
  }

  record
}

new_review_event_id <- function() {
  suffix <- paste(sample(c(letters, 0:9), 12, replace = TRUE), collapse = "")
  paste0(format(Sys.time(), "%Y%m%dt%H%M%OS6", tz = "UTC"), "-", suffix)
}

review_timestamp <- function() {
  format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
}

review_user <- function(session) {
  user <- session$user
  if (!rlang::is_string(user) || !nzchar(user)) {
    return("unknown")
  }
  user
}

trajectory_source <- function(trajectories) {
  attr(trajectories, "source") %||% list(kind = "unknown")
}

append_review_record <- function(file, record) {
  line <- jsonlite::toJSON(drop_nulls(record), auto_unbox = TRUE)
  cat(line, "\n", file = file, sep = "", append = TRUE)
}

read_review_records <- function(file) {
  if (!file.exists(file)) {
    return(list())
  }

  records <- list()
  invalid <- integer()
  lines <- readLines(file, warn = FALSE)
  for (i in seq_along(lines)) {
    record <- tryCatch(
      jsonlite::fromJSON(lines[[i]], simplifyVector = FALSE),
      error = function(err) NULL
    )
    if (!is_review_record(record)) {
      invalid <- c(invalid, i)
      next
    }
    records[[length(records) + 1]] <- record
  }

  if (length(invalid) > 0) {
    cli::cli_warn(
      "Ignoring {cli::qty(invalid)}invalid review record{?s} on line{?s}
       {invalid} of {.file {file}}."
    )
  }
  records
}

is_review_record <- function(record) {
  if (
    !is.list(record) ||
      !rlang::is_string(record$conversation) ||
      !rlang::is_string(record$action) ||
      !record$action %in% c("flag", "unflag", "note")
  ) {
    return(FALSE)
  }
  exchange <- record$exchange
  if (
    !is.null(exchange) &&
      (!is.numeric(exchange) ||
        length(exchange) != 1 ||
        !is.finite(exchange) ||
        exchange < 1 ||
        exchange != trunc(exchange))
  ) {
    return(FALSE)
  }
  !identical(record$action, "note") || rlang::is_string(record$note)
}

actionable_review_records <- function(records) {
  note_indices <- integer()
  latest_flag_indices <- integer()

  for (i in seq_along(records)) {
    record <- records[[i]]
    if (identical(record$action, "note")) {
      note_indices <- c(note_indices, i)
    } else {
      key <- review_key(record$conversation, record$exchange)
      latest_flag_indices[[key]] <- i
    }
  }

  active_flag_indices <- unname(latest_flag_indices)
  active_flag_indices <- active_flag_indices[vapply(
    records[active_flag_indices],
    function(record) identical(record$action, "flag"),
    logical(1)
  )]
  records[sort(c(note_indices, active_flag_indices))]
}

# The latest flag or unflag event determines each key's state.
review_flags <- function(records) {
  active <- Filter(
    function(record) identical(record$action, "flag"),
    actionable_review_records(records)
  )
  vapply(
    active,
    function(record) review_key(record$conversation, record$exchange),
    character(1)
  )
}

review_notes <- function(records) {
  Filter(
    function(record) identical(record$action, "note"),
    records
  )
}

review_key <- function(id, exchange = NULL) {
  paste(c(id, exchange), collapse = "#")
}

parse_review_time <- function(x) {
  time <- as.POSIXct(
    x,
    format = "%Y-%m-%dT%H:%M:%SZ",
    tz = "UTC"
  )
  if (!is.na(time)) {
    return(time)
  }
  as.POSIXct(x, format = "%Y-%m-%dT%H:%M:%S%z")
}
