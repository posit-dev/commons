#' Configure where commons logs conversation trajectories
#'
#' Pass one of these to the `log` argument of [commons()] for control over where
#' trajectories are written. `log_pins()` writes to private Connect pins;
#' `log_local()` writes to a local directory.
#'
#' @param share_with An optional character vector of Connect usernames to grant
#'   viewer access to logged trajectory pins. Requires the \pkg{connectapi}
#'   package. Access is granted as each conversation's pin is created, so named
#'   users retain ongoing access to new trajectories.
#' @param path A directory to write trajectory files to. Defaults to the
#'   `COMMONS_LOG_DIR` environment variable, or a temporary directory.
#'
#' @return A logging spec to pass to the `log` argument of [commons()].
#' @export
log_pins <- function(share_with = NULL) {
  if (!is.null(share_with) && !is.character(share_with)) {
    cli::cli_abort(
      "{.arg share_with} must be a character vector of Connect usernames."
    )
  }
  structure(
    list(kind = "pins", share_with = share_with),
    class = c("commons_log_pins", "commons_log_spec")
  )
}

#' @rdname log_pins
#' @export
log_local <- function(path = NULL) {
  if (!is.null(path) && !(is.character(path) && length(path) == 1)) {
    cli::cli_abort("{.arg path} must be a single directory path.")
  }
  structure(
    list(kind = "local", path = path),
    class = c("commons_log_local", "commons_log_spec")
  )
}

new_trajectory_logger <- function(log, call = rlang::caller_env()) {
  spec <- normalize_log_spec(log, call = call)

  if (spec$kind == "off") {
    return(new_noop_logger())
  }

  conversation_id <- new_conversation_id()

  if (spec$kind == "pins" && is_connect_runtime()) {
    return(new_pin_logger(conversation_id, spec$share_with))
  }

  if (spec$kind == "pins") {
    if (!is.null(spec$share_with)) {
      cli::cli_warn(c(
        "{.arg share_with} only applies when logging to Connect pins.",
        i = "Not running on Connect; logging locally and ignoring {.arg share_with}."
      ))
    }
    return(new_local_logger(conversation_id, commons_log_dir()))
  }

  if (spec$kind == "auto") {
    if (is_connect_runtime()) {
      return(new_pin_logger(conversation_id, NULL))
    }
    return(new_local_logger(conversation_id, commons_log_dir()))
  }

  new_local_logger(conversation_id, spec$path %||% commons_log_dir())
}

normalize_log_spec <- function(log, call = rlang::caller_env()) {
  if (is.null(log) || identical(log, FALSE)) {
    return(list(kind = "off"))
  }
  if (identical(log, TRUE)) {
    return(list(kind = "auto"))
  }
  if (is.character(log) && length(log) == 1) {
    return(log_local(log))
  }
  if (inherits(log, "commons_log_spec")) {
    return(log)
  }

  cli::cli_abort(
    c(
      "{.arg log} must be {.code TRUE}, {.code FALSE}, {.code NULL}, a directory path, or a logging spec.",
      i = "Create a spec with {.fn log_pins} or {.fn log_local}."
    ),
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

new_pin_logger <- function(conversation_id, share_with = NULL) {
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
  share <- new_trajectory_sharer(board, share_with)
  list(
    conversation_id = conversation_id,
    record = function(chat) {
      state$trajectory <- update_trajectory(state$trajectory, chat)
      write_pin_trajectory(board, name, state$trajectory)
      share(name)
    }
  )
}

# Grant viewer access once the pin's Connect content exists, then latch so we
# don't re-grant on every turn. A transient failure on one turn is retried on
# the next; the warning is emitted at most once so a persistent failure doesn't
# warn on every turn.
new_trajectory_sharer <- function(board, share_with) {
  if (length(share_with) == 0) {
    return(function(name) invisible(NULL))
  }

  if (!requireNamespace("connectapi", quietly = TRUE)) {
    cli::cli_warn(c(
      "Sharing trajectories with {.arg share_with} requires the {.pkg connectapi} package.",
      i = "Install {.pkg connectapi} or unset {.arg share_with}."
    ))
    return(function(name) invisible(NULL))
  }

  state <- new.env(parent = emptyenv())
  state$shared <- FALSE
  state$warned <- FALSE
  function(name) {
    if (state$shared) {
      return(invisible(NULL))
    }
    tryCatch(
      {
        share_trajectory_pin(board, name, share_with)
        state$shared <- TRUE
      },
      error = function(err) {
        if (!state$warned) {
          state$warned <- TRUE
          cli::cli_warn(c(
            "Could not share the trajectory pin with {.arg share_with}.",
            i = conditionMessage(err)
          ))
        }
      }
    )
    invisible(NULL)
  }
}

share_trajectory_pin <- function(board, name, share_with) {
  # connectapi grants permissions via its own client, built from the same
  # CONNECT_* env vars as the pins board.
  client <- connectapi::connect()
  user_guids <- vapply(
    share_with,
    function(username) connectapi::user_guid_from_username(client, username),
    character(1)
  )
  content <- trajectory_content_item(client, board, name)
  connectapi::content_add_user(content, guid = user_guids, role = "viewer")
  invisible(NULL)
}

# pins already knows the pin's Connect content GUID, so resolve the content item
# from it directly. This avoids connectapi::get_content(), whose response parsing
# is incompatible with some Connect server versions.
trajectory_content_item <- function(client, board, name) {
  guid <- pins::pin_meta(board, connect_pin_name(board, name))$local$content_id
  if (is.null(guid) || !nzchar(guid)) {
    cli::cli_abort("Could not resolve the Connect content GUID for pin {.val {name}}.")
  }
  connectapi::content_item(client, guid)
}

# The logger writes with a bare pin name (pins prepends the account on write),
# but board_connect reads want the fully qualified "account/name".
connect_pin_name <- function(board, name) {
  account <- board$account
  if (is.null(account) || !nzchar(account) || grepl("/", name, fixed = TRUE)) {
    return(name)
  }
  paste0(account, "/", name)
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
#' [commons()] when logging is enabled via its `log` argument (for example
#' `log = TRUE`, a local directory path, or a [log_local()] or [log_pins()]
#' spec).
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
  unname(replay_recorded_turns(trajectory$ellmer_turns))
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
