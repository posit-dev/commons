# @staticimports pkg:staticimports
#   is_installed

# Trajectory capture rides on OpenTelemetry: ellmer emits GenAI-semconv chat
# spans carrying the full message history, stamped with
# `gen_ai.conversation.id` from the client's `conversation_id` binding
# (allocated by shinychat at first submission), and commons adds a per-turn
# wrapper span so each turn's spans parent together. On Posit Connect, spans
# land in the content observability
# store (enable Content Observability in the content's Advanced settings);
# locally, they land in NDJSON files via otelsdk's file exporter.

# Called once per agent. Returns TRUE when tracing is live and
# conversation spans should be stamped.
new_trajectory_tracing <- function(
  log,
  share_with = NULL,
  call = rlang::caller_env()
) {
  rlang::check_bool(log, call = call)
  check_share_with(share_with, call = call)
  repair_connect_trace_routing()

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

  if (
    is_installed("promises") && !is_installed("promises", version = "1.5.0")
  ) {
    cli::cli_warn(c(
      "Concurrent conversations may be logged under the wrong conversation
       with {.pkg promises} older than 1.5.0.",
      i = "Update {.pkg promises} to 1.5.0 or later."
    ))
  }

  enable_content_capture()

  if (!otel::is_tracing_enabled() && !is_connect_runtime()) {
    enable_local_tracing()
  }

  if (!otel::is_tracing_enabled()) {
    if (is_connect_runtime()) {
      enable_content_observability()
    } else {
      warn_tracing_disabled()
    }
    return(FALSE)
  }

  if (!is.null(share_with)) {
    share_trajectory_access(share_with)
  }

  TRUE
}

# Connect 2026.07 can overwrite content routing with its server attributes.
repair_connect_trace_routing <- function() {
  if (!is_connect_runtime() || !is_installed("otel")) {
    return(invisible(FALSE))
  }

  guid <- Sys.getenv("CONNECT_CONTENT_GUID")
  job_key <- Sys.getenv("CONNECT_CONTENT_JOB_KEY")
  if (!nzchar(guid) || !nzchar(job_key)) {
    return(invisible(FALSE))
  }

  current <- Sys.getenv("OTEL_RESOURCE_ATTRIBUTES")
  pairs <- strsplit(current, ",", fixed = TRUE)[[1]]
  pairs <- pairs[nzchar(pairs)]
  names <- sub("=.*$", "", pairs)
  values <- sub("^[^=]*=", "", pairs)

  correctly_routed <-
    any(names == "content.guid" & values == guid) &&
    any(names == "job.key" & values == job_key)
  if (correctly_routed) {
    return(invisible(FALSE))
  }

  pairs <- pairs[!names %in% c("content.guid", "job.key")]
  pairs <- c(
    pairs,
    paste0("content.guid=", guid),
    paste0("job.key=", job_key)
  )
  Sys.setenv(OTEL_RESOURCE_ATTRIBUTES = paste(pairs, collapse = ","))
  reset_otel_tracer_provider()
  refresh_ellmer_otel_cache()
  invisible(TRUE)
}

# Start and activate a span for the calling frame's lifetime, ending when it
# exits. Unlike trajectory logging, these setup spans aren't gated behind
# `log = TRUE`: they cover product setup (data source and agent construction),
# not conversation content, and otel's default tracer provider is a no-op
# until an exporter is configured, so this is cheap even when tracing is off.
local_commons_span <- function(
  name,
  attributes = NULL,
  envir = parent.frame()
) {
  if (!is_installed("otel")) {
    return(invisible(NULL))
  }
  otel::start_local_active_span(
    name,
    attributes = attributes,
    tracer = otel::get_tracer("co.posit.r-package.commons"),
    activation_scope = envir
  )
}

# Attributes are best set at span creation (samplers can only see those), but
# some, like a row count, are only known after the work the span covers has
# started. `span` is NULL when otel isn't installed; no-op then.
commons_span_set_attribute <- function(span, name, value) {
  if (!is.null(span)) {
    span$set_attribute(name, value)
  }
  invisible(NULL)
}

# Connect can snapshot attributes when a span starts, before late mutations.
record_provenance_span <- function(tag, decisions) {
  attributes <- list(
    "commons.citation.candidates" = jsonlite::toJSON(
      decisions,
      auto_unbox = TRUE
    )
  )
  if (!is.na(tag)) {
    attributes[["commons.provenance.tag"]] <- tag
  }
  span <- otel::start_span(
    "commons_provenance",
    attributes = attributes,
    tracer = otel::get_tracer("co.posit.r-package.commons")
  )
  otel::end_span(span)
  invisible(NULL)
}

check_share_with <- function(share_with, call = rlang::caller_env()) {
  if (!is.null(share_with) && !is.character(share_with)) {
    cli::cli_abort(
      "{.arg share_with} must be a character vector of Connect usernames.",
      call = call
    )
  }
  invisible(NULL)
}

# Start a conversation-turn span, activate it for `envir`'s lifetime, and end
# it when `envir` exits. ellmer creates its `invoke_agent` span synchronously
# on the first pull of a chat/stream, while this span is active, so it becomes
# the parent; everything below it uses explicit parents. The promise domain
# swaps the active span in and out around promise callbacks so concurrent
# conversations (e.g. multiple Shiny sessions) don't cross-parent.
local_conversation_turn_span <- function(envir = parent.frame()) {
  if (!is_installed("otel") || !otel::is_tracing_enabled()) {
    return(invisible(NULL))
  }

  span <- otel::start_span(
    "commons_conversation_turn",
    tracer = otel::get_tracer("co.posit.r-package.commons")
  )
  if (is_installed("promises", version = "1.5.0")) {
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

# ellmer captures message content only when this semconv env var is truthy
# ("true"/"1", matching ellmer's parsing). An explicit pre-set value is
# respected -- a deliberate opt-out must not be flipped process-wide -- like
# enable_local_tracing() respects an explicit OTEL_TRACES_EXPORTER.
enable_content_capture <- function() {
  current <- Sys.getenv("OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT")
  if (nzchar(current)) {
    if (!tolower(current) %in% c("true", "1")) {
      cli::cli_warn(c(
        "{.envvar OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT} is set
         to {.val {current}}, so logged trajectories will not include message
         content.",
        i = "Unset it or set it to {.val true} to capture full trajectories."
      ))
    }
    return(invisible(FALSE))
  }
  Sys.setenv(OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT = "true")
  refresh_ellmer_otel_cache()
  invisible(TRUE)
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

# Tracing is off on Connect either because this content's Content
# Observability setting is off or because the server disallows content
# instrumentation. The setting is editable over the API with the ephemeral,
# owner-scoped CONNECT_API_KEY that Connect provides to running content
# (Applications.DefaultAPIKeyEnv, on by default), so flip it on here rather
# than sending the publisher to the dashboard. This process still can't
# trace -- Connect only injects the exporter configuration into processes
# started after enablement -- so warn about the restart and leave tracing
# off. Attempted once per process: agents are typically constructed per
# Shiny session, and each would otherwise repeat the API calls.
enable_content_observability <- function() {
  if (isTRUE(observability$attempted)) {
    return(invisible(NULL))
  }
  observability$attempted <- TRUE

  toggled <- tryCatch(
    {
      client <- connect_client()
      guid <- connect_content_guid()
      already_on <- isTRUE(connect_content(client, guid)$otel_enabled)
      if (!already_on) {
        connect_enable_otel(client, guid)
      }
      if (already_on) "already_on" else "toggled"
    },
    error = function(err) NULL
  )

  if (is.null(toggled)) {
    warn_tracing_disabled()
    return(invisible(NULL))
  }

  cli::cli_warn(c(
    if (toggled == "toggled") {
      "Enabled {.emph Content Observability} for this content, but this
       process started without it."
    } else {
      "{.emph Content Observability} is enabled for this content, but this
       process started without OpenTelemetry tracing."
    },
    i = "Trajectory logging will begin once the content restarts.",
    i = "If it doesn't, a server administrator may need to set
         {.code OpenTelemetry.AllowContentInstrumentation = true} in the
         Connect configuration."
  ))
  invisible(NULL)
}

observability <- new.env(parent = emptyenv())

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
  Sys.getenv(
    "COMMONS_TRACES_DIR",
    unset = file.path(tempdir(), "commons-traces")
  )
}

# Grant `share_with` users access to this content's traces. Reading traces
# requires editor-level access, so users are added as collaborators; see
# connect_add_collaborator(). Grants are durable, so failures only warn, and
# usernames this process has already handled are skipped -- agents are
# typically constructed once per Shiny session, and the grant API calls
# shouldn't tax every session start.
share_trajectory_access <- function(share_with) {
  if (!is_connect_runtime()) {
    cli::cli_warn(c(
      "{.arg share_with} only applies when running on Posit Connect.",
      i = "Ignoring {.arg share_with}."
    ))
    return(invisible(NULL))
  }

  guid <- connect_content_guid()
  share_with <- share_with[
    !vapply(share_key(guid, share_with), exists, logical(1), envir = granted)
  ]
  if (length(share_with) == 0) {
    return(invisible(NULL))
  }

  tryCatch(
    {
      client <- connect_client()
      existing <- connect_permission_principals(client, guid)
      for (username in share_with) {
        user_guid <- connect_user_guid(client, username)
        if (!user_guid %in% existing) {
          connect_add_collaborator(client, guid, user_guid)
        }
        assign(share_key(guid, username), TRUE, envir = granted)
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

granted <- new.env(parent = emptyenv())

share_key <- function(guid, username) {
  paste(guid, tolower(username))
}
