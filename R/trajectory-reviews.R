#' Read trajectory reviews
#'
#' `read_trajectory_reviews()` reads the append-only JSONL event log written by
#' [view_trajectories()]. It returns every note and only the currently active
#' flags: superseded `flag` events and all `unflag` events are folded away.
#'
#' When `trajectories` is supplied, each returned record gains a `turns` field
#' containing the reviewed conversation or question-and-answer exchange. This
#' makes the result ready for analysis by a person or coding agent. Records
#' whose trajectory is no longer available retain their logged question, tag,
#' source, and identifiers.
#'
#' Review logs written before schema version 1 remain readable. Those legacy
#' records do not have source, user, or question metadata.
#'
#' @param review_file Path to the review JSONL file. Defaults to the
#'   `COMMONS_REVIEW_FILE` environment variable when set, and otherwise to
#'   `"commons-review.jsonl"`.
#' @param trajectories An optional named list of conversations returned by
#'   [read_trajectories()]. When supplied, review records are joined to their
#'   conversation or exchange.
#'
#' @return A list of actionable review records in file order: all notes and
#'   currently active flags. When `trajectories` is supplied, each record also
#'   contains `turns`.
#' @export
read_trajectory_reviews <- function(
  review_file = Sys.getenv(
    "COMMONS_REVIEW_FILE",
    unset = "commons-review.jsonl"
  ),
  trajectories = NULL
) {
  rlang::check_string(review_file)
  if (!is.null(trajectories)) {
    check_trajectories(trajectories)
  }

  records <- actionable_review_records(read_review_records(review_file))
  if (is.null(trajectories)) {
    return(records)
  }
  lapply(records, enrich_review_record, trajectories = trajectories)
}

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
  if (
    !is.character(user) || length(user) != 1 || is.na(user) || !nzchar(user)
  ) {
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
      "Ignoring invalid review record{?s} on line{?s} {invalid} of
       {.file {file}}."
    )
  }
  records
}

is_review_record <- function(record) {
  if (
    !is.list(record) ||
      !is_scalar_character(record$conversation) ||
      !is_scalar_character(record$action) ||
      !record$action %in% c("flag", "unflag", "note")
  ) {
    return(FALSE)
  }
  if (
    !is.null(record$exchange) &&
      (!is.numeric(record$exchange) ||
        length(record$exchange) != 1 ||
        is.na(record$exchange))
  ) {
    return(FALSE)
  }
  !identical(record$action, "note") || is_scalar_character(record$note)
}

is_scalar_character <- function(x) {
  is.character(x) && length(x) == 1 && !is.na(x)
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

enrich_review_record <- function(record, trajectories) {
  record["turns"] <- list(NULL)
  conversation <- match(record$conversation, names(trajectories))
  if (is.na(conversation)) {
    return(record)
  }

  turns <- trajectories[[conversation]]
  if (!is.null(record$exchange)) {
    exchanges <- split_exchanges(turns)
    exchange <- as.integer(record$exchange)
    if (!exchange %in% seq_along(exchanges)) {
      return(record)
    }
    turns <- exchanges[[exchange]]
    if (is.null(record$question)) {
      record$question <- turns[[1]]@text
    }
    if (is.null(record$tag)) {
      tag <- exchange_provenance(turns)$tag
      record$tag <- if (is.na(tag)) "none" else tag
    }
  }
  record$turns <- turns
  record
}

# Flags persist as flag/unflag events; the latest event per key wins.
review_flags <- function(records) {
  flags <- character()
  for (record in records) {
    key <- review_key(record$conversation, record$exchange)
    if (identical(record$action, "flag")) {
      flags <- union(flags, key)
    } else if (identical(record$action, "unflag")) {
      flags <- setdiff(flags, key)
    }
  }
  flags
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
