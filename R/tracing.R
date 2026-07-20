# Trajectory capture rides on OpenTelemetry: ellmer emits GenAI-semconv chat
# spans carrying the full message history, and commons adds a per-turn wrapper
# span carrying `gen_ai.conversation.id` so spans can be grouped back into
# conversations. On Posit Connect, spans land in the content observability
# store (enable Content Observability in the content's Advanced settings);
# locally, they land in NDJSON files via otelsdk's file exporter.

# Called once per Commons instance. Returns TRUE when tracing is live and
# conversation spans should be stamped.
new_trajectory_tracing <- function(
  log,
  share_with = NULL,
  call = rlang::caller_env()
) {
  if (!rlang::is_bool(log)) {
    cli::cli_abort(
      "{.arg log} must be {.code TRUE} or {.code FALSE}.",
      call = call
    )
  }
  if (!is.null(share_with) && !is.character(share_with)) {
    cli::cli_abort(
      "{.arg share_with} must be a character vector of Connect usernames.",
      call = call
    )
  }

  if (!log) {
    if (!is.null(share_with)) {
      cli::cli_warn(
        "{.arg share_with} only applies when {.code log = TRUE}; ignoring it."
      )
    }
    return(FALSE)
  }

  if (!is_installed("otel")) {
    cli::cli_warn(c(
      "Trajectory logging requires the {.pkg otel} package.",
      i = "Install {.pkg otel} (and {.pkg otelsdk}) to enable it."
    ))
    return(FALSE)
  }

  enable_content_capture()

  if (!is.null(share_with)) {
    share_trajectory_access(share_with)
  }

  if (!otel::is_tracing_enabled() && !is_connect_runtime()) {
    enable_local_tracing()
  }

  if (!otel::is_tracing_enabled()) {
    warn_tracing_disabled()
    return(FALSE)
  }

  TRUE
}

#' @noRd
new_conversation_id <- function() {
  suffix <- paste(sample(c(letters, 0:9), 10, replace = TRUE), collapse = "")
  paste0(format(Sys.time(), "%Y%m%dt%H%M%OS3"), "-", suffix)
}

# Start a conversation-turn span, activate it for `envir`'s lifetime, and end
# it when `envir` exits. ellmer creates its `invoke_agent` span synchronously
# on the first pull of a chat/stream, while this span is active, so it becomes
# the parent; everything below it uses explicit parents. The promise domain
# swaps the active span in and out around promise callbacks so concurrent
# conversations (e.g. multiple Shiny sessions) don't cross-parent.
local_conversation_turn_span <- function(
  conversation_id,
  envir = parent.frame()
) {
  if (!is_installed("otel") || !otel::is_tracing_enabled()) {
    return(invisible(NULL))
  }

  span <- otel::start_span(
    "commons_conversation_turn",
    attributes = list("gen_ai.conversation.id" = conversation_id),
    tracer = otel::get_tracer("co.posit.r-package.commons")
  )
  if (is_installed("promises")) {
    promises::local_otel_promise_domain(envir)
  }
  otel::local_active_span(span, activation_scope = envir)
  defer(otel::end_span(span), envir)

  invisible(span)
}

# HACK: ellmer snapshots its tracer and the GenAI content-capture flag once,
# in its .onLoad (`otel_cache_tracer()` in ellmer's R/otel.R). Because ellmer
# loads as a commons dependency, that snapshot is always taken before any
# commons code runs, and ellmer exports no way to refresh it. So after
# changing the OTEL_* environment, reach into ellmer and re-run its caching
# function. If ellmer's internals change, capture silently stays off for the
# session; setting the env vars before R starts (as `warn_tracing_disabled()`
# suggests) remains the manual path.
refresh_ellmer_otel_cache <- function() {
  tryCatch(
    ellmer:::otel_cache_tracer(),
    error = function(err) NULL
  )
  invisible(NULL)
}

enable_content_capture <- function() {
  Sys.setenv(OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT = "true")
  refresh_ellmer_otel_cache()
}

# Configure otelsdk's file exporter for a local session that hasn't set up
# OTel itself. Only steps in when no exporter is configured at all: a user's
# explicit OTEL_TRACES_EXPORTER (even "none") is respected.
enable_local_tracing <- function() {
  if (nzchar(Sys.getenv("OTEL_TRACES_EXPORTER"))) {
    return(invisible(FALSE))
  }
  if (!is_installed("otelsdk")) {
    cli::cli_warn(c(
      "Local trajectory logging requires the {.pkg otelsdk} package.",
      i = "Install {.pkg otelsdk} to enable it."
    ))
    return(invisible(FALSE))
  }

  dir <- commons_traces_dir()
  if (!dir.exists(dir)) {
    dir.create(dir, recursive = TRUE)
  }
  Sys.setenv(
    OTEL_TRACES_EXPORTER = "otlp/file",
    OTEL_EXPORTER_OTLP_TRACES_FILE = file.path(dir, "trace-%N.jsonl")
  )
  reset_otel_tracer_provider()
  refresh_ellmer_otel_cache()
  invisible(TRUE)
}

# HACK: the otel package builds its default tracer provider from the OTEL_*
# environment on the first `otel::get_tracer()` call -- which ellmer's .onLoad
# triggers, before any commons code can run -- and caches it in the internal
# `otel:::the` environment. There is no public API to reconfigure it, so to
# honor env vars set after load, clear the cached provider and let the next
# `get_tracer()` rebuild it. Ordering matters: set the env vars first, then
# reset here, then refresh ellmer's snapshot (which calls `get_tracer()`).
# If otel's internals change, this quietly does nothing and
# `warn_tracing_disabled()` tells the user to configure `.Renviron` instead.
reset_otel_tracer_provider <- function() {
  tryCatch(
    {
      the <- asNamespace("otel")$the
      if (is.environment(the)) {
        the$tracer_provider <- NULL
      }
    },
    error = function(err) NULL
  )
  invisible(NULL)
}

warn_tracing_disabled <- function() {
  if (is_connect_runtime()) {
    cli::cli_warn(c(
      "Trajectory logging is enabled but OpenTelemetry tracing is not active.",
      i = "Enable {.emph Content Observability} in this content's
           {.emph Settings > Advanced} panel on Posit Connect, then redeploy
           or restart the content.",
      i = "A server administrator may first need to set
           {.code OpenTelemetry.AllowContentInstrumentation = true} in the
           Connect configuration."
    ))
  } else {
    cli::cli_warn(c(
      "Trajectory logging is enabled but OpenTelemetry tracing is not active.",
      i = "Configure an exporter before R starts, e.g. in {.file .Renviron}:",
      " " = "{.code OTEL_TRACES_EXPORTER=otlp/file}",
      " " = "{.code OTEL_EXPORTER_OTLP_TRACES_FILE={file.path(commons_traces_dir(), 'trace-%N.jsonl')}}",
      " " = "{.code OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true}"
    ))
  }
  invisible(NULL)
}

commons_traces_dir <- function() {
  Sys.getenv("COMMONS_TRACES_DIR", unset = file.path(tempdir(), "commons-traces"))
}

# Grant `share_with` users access to this content's traces. Reading traces
# requires editor-level access, so users are added as collaborators; see
# connect_add_collaborator(). Grants are durable, so failures only warn.
share_trajectory_access <- function(share_with) {
  if (!is_connect_runtime()) {
    cli::cli_warn(c(
      "{.arg share_with} only applies when running on Posit Connect.",
      i = "Ignoring {.arg share_with}."
    ))
    return(invisible(NULL))
  }

  tryCatch(
    {
      client <- connect_client()
      guid <- connect_content_guid()
      existing <- connect_permission_principals(client, guid)
      for (username in share_with) {
        user_guid <- connect_user_guid(client, username)
        if (user_guid %in% existing) {
          next
        }
        connect_add_collaborator(client, guid, user_guid)
      }
    },
    error = function(err) {
      cli::cli_warn(c(
        "Could not share trajectory access with {.arg share_with}.",
        i = conditionMessage(err)
      ))
    }
  )
  invisible(NULL)
}
