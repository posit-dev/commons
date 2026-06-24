new_trajectory_logger <- function(log, call = rlang::caller_env()) {
  if (is.null(log) || identical(log, FALSE)) {
    return(new_noop_logger())
  }

  conversation_id <- new_conversation_id()

  if (identical(log, TRUE)) {
    if (is_connect_runtime()) {
      return(new_pin_logger(conversation_id))
    }
    return(new_local_logger(conversation_id, commons_log_dir()))
  }

  if (is.character(log) && length(log) == 1) {
    return(new_local_logger(conversation_id, log))
  }

  cli::cli_abort(
    "{.arg log} must be {.code TRUE}, {.code FALSE}, {.code NULL}, or a single directory path.",
    call = call
  )
}

record_trajectory <- function(logger, chat) {
  tryCatch(
    {
      logger$record(chat)
      invisible(NULL)
    },
    error = function(err) {
      cli::cli_warn(
        c(
          "Could not write commons trajectory log.",
          i = conditionMessage(err)
        )
      )
      invisible(NULL)
    }
  )
}

new_noop_logger <- function() {
  list(
    conversation_id = NA_character_,
    record = function(chat) invisible(NULL)
  )
}

new_local_logger <- function(conversation_id, path) {
  state <- new_trajectory_state(conversation_id)
  list(
    conversation_id = conversation_id,
    record = function(chat) {
      state$trajectory <- update_trajectory(state$trajectory, chat)
      write_local_trajectory(path, state$trajectory)
    }
  )
}

new_pin_logger <- function(conversation_id) {
  if (!requireNamespace("pins", quietly = TRUE)) {
    cli::cli_warn(
      c(
        "Trajectory logging with Connect pins requires the {.pkg pins} package.",
        i = "Install {.pkg pins} or set {.arg log} to a local directory path."
      )
    )
    return(new_noop_logger())
  }

  board <- tryCatch(
    pins::board_connect(auth = "envvar"),
    error = function(err) {
      cli::cli_warn(
        c(
          "Could not create a Connect pins board for trajectory logging.",
          i = conditionMessage(err)
        )
      )
      NULL
    }
  )

  if (is.null(board)) {
    return(new_noop_logger())
  }

  name <- trajectory_pin_name(conversation_id)
  state <- new_trajectory_state(conversation_id)
  list(
    conversation_id = conversation_id,
    record = function(chat) {
      state$trajectory <- update_trajectory(state$trajectory, chat)
      write_pin_trajectory(board, name, state$trajectory)
    }
  )
}

new_trajectory_state <- function(conversation_id) {
  state <- new.env(parent = emptyenv())
  state$trajectory <- init_trajectory(conversation_id)
  state
}

init_trajectory <- function(conversation_id) {
  now <- trajectory_time()
  list(
    schema = "commons.trajectory.v1",
    conversation_id = conversation_id,
    content_guid = connect_content_guid(),
    created_at = now,
    updated_at = now,
    ellmer_turns = list()
  )
}

update_trajectory <- function(trajectory, chat) {
  now <- trajectory_time()
  turns <- chat$get_turns(include_system_prompt = TRUE)
  trajectory$updated_at <- now
  trajectory$ellmer_turns <- lapply(turns, record_turn)
  trajectory
}

record_turn <- function(turn) {
  ellmer::contents_record(turn)
}

write_local_trajectory <- function(path, trajectory) {
  if (!dir.exists(path)) {
    dir.create(path, recursive = TRUE)
  }

  file <- file.path(
    path,
    sprintf("commons-trajectory-%s.rds", trajectory$conversation_id)
  )
  tmp <- paste0(file, ".tmp")
  saveRDS(trajectory, tmp)
  file.rename(tmp, file)
  invisible(file)
}

write_pin_trajectory <- function(board, name, trajectory) {
  suppressMessages(
    do.call(pins::pin_write, pin_trajectory_write_args(board, name, trajectory))
  )
  invisible(name)
}

pin_trajectory_write_args <- function(board, name, trajectory) {
  args <- list(
    board = board,
    x = trajectory,
    name = name,
    type = "rds",
    title = sprintf("commons trajectory %s", trajectory$conversation_id),
    description = "A commons conversation trajectory.",
    metadata = trajectory_metadata(trajectory),
    force_identical_write = TRUE
  )

  if (inherits(board, "pins_board_connect")) {
    args$access_type <- "acl"
  }

  args
}

trajectory_metadata <- function(trajectory) {
  list(
    commons_schema = trajectory$schema,
    commons_content_guid = trajectory$content_guid,
    commons_conversation_id = trajectory$conversation_id,
    commons_created_at = trajectory$created_at,
    commons_updated_at = trajectory$updated_at,
    commons_version = as.character(utils::packageVersion("commons"))
  )
}

trajectory_pin_name <- function(conversation_id) {
  guid <- substr(sanitize_pin_part(connect_content_guid()), 1, 8)
  parts <- c("commons-trajectory", guid, conversation_id)
  paste(sanitize_pin_part(parts), collapse = "-")
}

sanitize_pin_part <- function(x) {
  x <- tolower(x)
  x <- gsub("[^a-z0-9]+", "-", x)
  x <- gsub("(^-+|-+$)", "", x)
  x[nchar(x) == 0] <- "unknown"
  x
}

new_conversation_id <- function() {
  suffix <- paste(sample(c(letters, 0:9), 10, replace = TRUE), collapse = "")
  sanitize_pin_part(paste0(format(Sys.time(), "%Y%m%dT%H%M%OS3"), "-", suffix))
}

trajectory_time <- function() {
  format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3%z")
}

is_connect_runtime <- function() {
  identical(Sys.getenv("POSIT_PRODUCT"), "CONNECT") ||
    nzchar(Sys.getenv("CONNECT_CONTENT_GUID"))
}

connect_content_guid <- function() {
  Sys.getenv("CONNECT_CONTENT_GUID", unset = "local")
}

commons_log_dir <- function() {
  Sys.getenv("COMMONS_LOG_DIR", unset = file.path(tempdir(), "commons-logs"))
}

#' Read commons trajectories
#'
#' `read_trajectories()` reads conversation trajectories written by
#' [commons()] when `log = TRUE` or `log` is a local directory path.
#'
#' @section Agent skill:
#' commons includes an agent skill scaffold for iterating on a deployed agent.
#' To locate it:
#'
#' ```r
#' system.file("skills", "iterate", "SKILL.md", package = "commons")
#' ```
#'
#' To use it, copy the skill directory into your agent's skills directory,
#' like `./.agents/skills`:
#'
#' ```r
#' skill <- system.file("skills", "iterate", package = "commons")
#' dir.create("./.agents/skills", recursive = TRUE, showWarnings = FALSE)
#' file.copy(skill, "./.agents/skills", recursive = TRUE)
#' ```
#'
#' @param x A `pins` board or a local directory path. If `NULL`, reads from the
#'   local [commons()] log directory.
#' @param ... Reserved for future extensions.
#'
#' @return A list of lists of ellmer turns, one list per conversation.
#' @export
read_trajectories <- function(x = NULL, ...) {
  if (is.null(x)) {
    x <- commons_log_dir()
  }

  trajectories <- if (is.character(x) && length(x) == 1) {
    read_local_trajectories(x)
  } else if (inherits(x, "pins_board")) {
    read_pin_trajectories(x)
  } else {
    cli::cli_abort(
      "{.arg x} must be a local directory path, a pins board, or {.code NULL}."
    )
  }

  lapply(trajectories, replay_trajectory)
}

read_local_trajectories <- function(path) {
  if (!dir.exists(path)) {
    return(list())
  }

  files <- list.files(
    path,
    pattern = "^commons-trajectory-.*[.]rds$",
    full.names = TRUE
  )
  lapply(files, read_trajectory_file)
}

read_pin_trajectories <- function(board) {
  rlang::check_installed("pins")
  pins <- pins::pin_list(board)
  pins <- pins[is_trajectory_pin(pins)]
  lapply(pins, function(pin) pins::pin_read(board, pin))
}

is_trajectory_pin <- function(x) {
  grepl("(^|/)commons-trajectory-", x)
}

read_trajectory_file <- function(path) {
  readRDS(path)
}

replay_trajectory <- function(trajectory) {
  trajectory$turns <- replay_recorded_turns(trajectory$ellmer_turns)
  trajectory$ellmer_turns <- NULL
  trajectory
}

replay_recorded_turns <- function(turns) {
  lapply(turns, function(turn) {
    ellmer::contents_replay(normalize_recorded_for_replay(turn))
  })
}

normalize_recorded_for_replay <- function(x) {
  if (is_recorded_ellmer_object(x)) {
    x$version <- as.numeric(x$version)
    x$props <- lapply(x$props, normalize_recorded_for_replay)
    if (x$class %in% c(
      "ellmer::SystemTurn",
      "ellmer::UserTurn",
      "ellmer::AssistantTurn",
      "ellmer::AssistantPartialTurn"
    )) {
      x$props <- normalize_turn_contents(x$props)
    }
    if (x$class %in% c("ellmer::SystemTurn", "ellmer::UserTurn")) {
      x$props <- x$props["contents"]
    } else if (x$class %in% c("ellmer::AssistantTurn", "ellmer::AssistantPartialTurn")) {
      x$props <- normalize_assistant_props(x$props)
    }
    return(x)
  }

  if (is.list(x)) {
    return(lapply(x, normalize_recorded_for_replay))
  }

  x
}

normalize_turn_contents <- function(props) {
  if (is_recorded_ellmer_object(props$contents)) {
    props$contents <- list(props$contents)
  }
  props
}

normalize_assistant_props <- function(props) {
  if (is_nullish_recorded_value(props$tokens) || is_null_list(props$tokens)) {
    props$tokens <- NULL
  } else if (is.list(props$tokens)) {
    props$tokens <- as.numeric(unlist(props$tokens, use.names = FALSE))
  }
  if (is_nullish_recorded_value(props$cost)) {
    props$cost <- NULL
  }
  if (is_nullish_recorded_value(props$duration)) {
    props$duration <- NULL
  }
  props
}

is_nullish_recorded_value <- function(x) {
  is.null(x) || (is.atomic(x) && (length(x) == 0 || all(is.na(x))))
}

is_null_list <- function(x) {
  is.list(x) && length(x) > 0 && all(vapply(x, is.null, logical(1)))
}

is_recorded_ellmer_object <- function(x) {
  is.list(x) && all(c("version", "class", "props") %in% names(x))
}
