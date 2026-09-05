#' Create a commons agent
#'
#' `commons()` creates an [ellmer::Chat] subclass with tools and prompting that
#' allow the agent to navigate its data sources, semantic layer, and context
#' layer. Depending on the agent's choice of tools, responses can be
#' deterministically classified as based on a trusted calculation, cited, or
#' untrusted.
#'
#' The provider and model come from `client`; commons sets its own system prompt
#' and tools. Use `agent$chat()` to ask questions, [commons_theme()] and
#' [commons_server()] to embed the agent in Shiny, and [vitals::generate()]
#' to use the agent as a vitals solver.
#'
#' @param client An [ellmer::Chat] giving the provider and model to use, e.g.
#'   [ellmer::chat_anthropic()]. A system prompt already set on the client is
#'   ignored, with a warning; use `instructions` to add to commons' prompt.
#' @param data_sources A [data_source()], or a named list of them. Measures
#'   can take a source's connection as an argument named after the source; see
#'   [semantic_layer()].
#' @param semantic_layer An optional [semantic_layer()].
#' @param context_layer An optional [context_layer()].
#' @param ... These dots are for future extensions and must be empty.
#' @param instructions Optional instructions placed under an
#'   `## Additional instructions` heading at the end of commons' built-in
#'   system prompt, as a single string or the path to a text or Markdown file.
#'
#'   ```r
#'   commons(
#'     # ...
#'     instructions = "Use the organization's fiscal-year conventions."
#'   )
#'   ```
#' @param network Whether the agent's R session has network access. One
#'   of
#'   `"none"` (the default) or `"full"`. The session uses OS sandboxing on
#'   Linux and macOS. On unsupported hosts, local development can opt in to
#'   best-effort R guardrails with
#'   `options(commons.allow_unsafe_fallback = TRUE)`. These guardrails
#'   are not a security boundary.
#' @param log Whether to capture conversation trajectories with OpenTelemetry
#'   (default `FALSE`). When `TRUE`, commons enables GenAI message-content
#'   capture in \pkg{ellmer} and tags each turn's spans with a conversation
#'   id; the spans go wherever OTel is configured to export. On Posit Connect,
#'   traces land in Connect's observability store (browsable in its Trace
#'   Viewer); commons switches on the content's *Content Observability*
#'   setting itself when needed, though capture only starts once the content
#'   restarts. Locally, commons configures \pkg{otelsdk}'s file exporter
#'   automatically when no exporter is set up. Read trajectories back with
#'   [trajectory_read()].
#' @param share_with An optional character vector of Connect usernames granted
#'   access to this content's trajectories when running on Posit Connect.
#'   Reading traces requires editor-level access, so named users are added as
#'   collaborators on the content. Note that users whose Connect *account*
#'   role is viewer cannot read traces even when named here; trace readers
#'   need at least a publisher account.
#'
#' @section Cache pre-warming:
#' A commons agent builds its context search index and downloads uncached pins
#' the first time it needs them. [commons_server()] and [commons_app()] call the
#' agent's `prewarm()` method automatically during post-startup idle time.
#'
#' To warm the caches before deployment, call `agent$prewarm()` in a
#' pre-deploy script. The context index is cached on disk once per version of 
#' the context documents; pin downloads populate the local pins cache.
#'
#' To ship a pre-built context index with an app, configure a directory inside
#' the app in both the pre-deploy script and the deployed app, then prewarm the
#' agent before deploying:
#'
#' ```r
#' options(commons.context_cache = "commons-cache")
#' agent <- commons(
#'   ellmer::chat_anthropic(),
#'   data_sources = data_source(sales = sales)
#' )
#' agent$prewarm()
#' ```
#'
#' Do not use `app_cache/` for this workflow because rsconnect excludes it from
#' deployed bundles. Without explicit configuration, commons uses Connect's
#' persistent content data directory when available, an `app_cache/` directory
#' beside hosted apps, or the per-user cache directory. Set the cache directory
#' with `options(commons.context_cache = "path/to/dir")` or the
#' `COMMONS_CONTEXT_CACHE` environment variable. Set the option to `FALSE` to
#' disable persistence. The cache is capped at 256 MB with least-recently-used
#' eviction; change the cap with `options(commons.context_cache_max_size)`.
#'
#' @section Agent tools:
#' Depending on its semantic layer, context layer, and data sources, a commons
#' agent receives some combination of these tools:
#'
#' * `search_pool` searches trusted calculations and semantic models.
#' * `search_catalog` searches a warehouse catalog.
#' * `call_measure` invokes an R measure.
#' * `call_metrics` invokes governed or warehouse-native metrics.
#' * `call_calculation` invokes an exact trusted query.
#' * `search_context` retrieves relevant business context.
#' * `describe_table` inspects a table or semantic model.
#' * `run_sql` executes a read-only SQL query.
#' * `run_r` executes R code to analyze results and render plots in the agent's
#'   R session.
#'
#' These model-facing tools should be considered private. Their constructors
#' are intentionally not exported, and their names, arguments, availability,
#' and behavior may change without notice. Application code should configure
#' an agent through `commons()` and its layer constructors rather than depend
#' on individual tools.
#'
#' @return An [ellmer::Chat] subclass.
#'
#' @examples
#' \dontrun{
#' # A measure over local data computes directly in R.
#' sem <- semantic_layer(
#'   measure(
#'     "order_count",
#'     "Count of orders.",
#'     function() nrow(my_sales),
#'     arguments = list()
#'   )
#' )
#' agent <- commons(
#'   ellmer::chat_anthropic(),
#'   data_sources = data_source(sales = my_sales),
#'   semantic_layer = sem
#' )
#' agent$chat("How many orders are there?")
#'
#' # A measure takes a connection as an argument named after a data source.
#' # `warehouse` isn't in `arguments`, so the model never sees it; commons
#' # supplies it when the measure runs. Interpolate model-supplied arguments
#' # with glue::glue_sql() so they're quoted safely.
#' con <- DBI::dbConnect(duckdb::duckdb())
#' sem <- semantic_layer(
#'   measure(
#'     "revenue_by_region",
#'     "Total revenue for a region.",
#'     function(region, warehouse) {
#'       DBI::dbGetQuery(
#'         warehouse,
#'         glue::glue_sql(
#'           "SELECT sum(revenue) AS revenue FROM sales WHERE region = {region}",
#'           .con = warehouse
#'         )
#'       )
#'     },
#'     arguments = list(region = ellmer::type_string("Sales region."))
#'   )
#' )
#' agent <- commons(
#'   ellmer::chat_anthropic(),
#'   data_sources = list(warehouse = data_source(con)),
#'   semantic_layer = sem
#' )
#'
#' # Objects that aren't data sources (a pins board, an API client) come from
#' # argument defaults in the measure, e.g. `board = pins::board_connect()`.
#' # See ?semantic_layer.
#' }
#'
#' @export
commons <- function(
  client,
  data_sources,
  semantic_layer = NULL,
  context_layer = NULL,
  ...,
  instructions = NULL,
  network = c("none", "full"),
  log = FALSE,
  share_with = NULL
) {
  rlang::check_dots_empty()
  if (!inherits(client, "Chat")) {
    cli::cli_abort(
      "{.arg client} must be an {.cls ellmer::Chat}, e.g. from {.fn ellmer::chat_anthropic}."
    )
  }
  if (!is.null(client$get_system_prompt())) {
    cli::cli_warn(
      c(
        "The system prompt set on {.arg client} is ignored; commons builds
         its own.",
        i = "Use {.arg instructions} to add to commons' prompt."
      )
    )
  }
  data_sources <- as_data_sources(data_sources)
  check_context_layer(context_layer)
  semantic_layer <- semantic_layer %||% new_semantic_layer()
  check_semantic_layer(semantic_layer)
  network <- rlang::arg_match(network)
  protection <- run_r_protection_mode()
  check_instructions(instructions)
  rlang::check_bool(log)
  check_share_with(share_with)

  Commons$new(
    client = client,
    data_sources = data_sources,
    context_layer = context_layer,
    semantic_layer = semantic_layer,
    network = network,
    protection = protection,
    instructions = instructions,
    log = log,
    share_with = share_with
  )
}

ellmer_chat_class <- function() {
  # Chat is exported in dev ellmer; use ellmer::Chat after its next release.
  utils::getFromNamespace("Chat", "ellmer")
}

Commons <- R6::R6Class(
  "Commons",
  inherit = ellmer_chat_class(),
  public = list(
    initialize = function(
      client,
      data_sources,
      semantic_layer = NULL,
      context_layer = NULL,
      ...,
      instructions = NULL,
      network = c("none", "full"),
      protection = run_r_protection_mode(),
      log = FALSE,
      share_with = NULL
    ) {
      rlang::check_dots_empty()
      do.call(super$initialize, ellmer_chat_initialize_args(client))
      semantic_layer <- semantic_layer %||% new_semantic_layer()
      network <- rlang::arg_match(network)

      sources <- as_data_sources(data_sources)

      private$sources <- sources
      private$context_layer <- augment_context_layer(context_layer, sources)
      private$first_touch <- new.env(parent = emptyenv())
      private$definitions <- definitions_registry(sources)
      private$semantic_models <- semantic_models_registry(sources)
      private$calculations <- calculations_registry(sources)
      semantic_state <- semantic_layer_state(semantic_layer)
      private$registry <- semantic_state$measures
      private$fn_sources <- semantic_state$fn_sources
      private$measure_provenance <- semantic_state$measure_provenance
      private$injections <- resolve_injections(
        private$registry,
        measure_injectables(sources)
      )
      private$tracing <- new_trajectory_tracing(log, share_with)

      # Created after new_trajectory_tracing() so a fresh `log = TRUE` local
      # exporter is already configured; otherwise otel::get_tracer() below
      # would resolve and cache a no-op provider before tracing turns on.
      local_commons_span(
        "commons_agent_create",
        attributes = list(
          "commons.agent.n_data_sources" = length(sources),
          "commons.agent.has_context_layer" = !is.null(context_layer),
          "commons.agent.n_measures" = length(semantic_state$measures),
          "commons.agent.n_definitions" = nrow(private$definitions$defs),
          "commons.agent.n_semantic_members" = nrow(
            private$semantic_models$members
          ),
          "commons.agent.n_calculations" = length(private$calculations)
        )
      )

      private$handles <- new_handle_store()
      private$worker <- new_r_worker(network, protection)
      private$corpus <- build_citation_corpus(
        private$context_layer,
        private$registry,
        sources
      )
      private$citation_request <- new.env(parent = emptyenv())
      private$citation_request$reminder <- citation_reminder_text()
      private$restore_reminder_pending <- FALSE

      commons_tools <- build_commons_tools(self, private)
      self$register_tools(commons_tools)
      self$set_system_prompt(
        commons_system_prompt(
          private$sources,
          definitions = private$definitions,
          instructions = instructions,
          tools = commons_tools,
          model = self$get_model()
        )
      )
    },

    add_turn = function(user, assistant, log_tokens = TRUE) {
      if (turn_has_user_message(user)) {
        private$citation_request$requested <- FALSE
      }
      super$add_turn(user, assistant, log_tokens = log_tokens)
    },

    set_turns = function(value) {
      private$restore_reminder_pending <- FALSE
      super$set_turns(value)
    },

    chat = function(..., echo = NULL) {
      if (private$tracing) {
        local_conversation_turn_span()
      }
      restore_reminder_pending <- private$restore_reminder_pending
      inputs <- private$prepare_turn_inputs(rlang::list2(...))
      result <- withVisible(do.call(super$chat, c(inputs, list(echo = echo))))
      private$consume_restore_reminder(restore_reminder_pending)
      if (result$visible) result$value else invisible(result$value)
    },

    stream_async = function(
      ...,
      tool_mode = c("concurrent", "sequential"),
      stream = c("text", "content"),
      controller = NULL
    ) {
      from_index <- length(self$get_turns()) + 1L
      stream <- rlang::arg_match(stream)
      restore_reminder_pending <- private$restore_reminder_pending
      inputs <- private$prepare_turn_inputs(rlang::list2(...))
      raw_stream <- do.call(
        super$stream_async,
        c(
          inputs,
          list(
            tool_mode = tool_mode,
            stream = stream,
            controller = controller
          )
        )
      )

      tracing <- private$tracing
      corpus <- private$corpus
      as_content <- identical(stream, "content")

      # Always project citations so reserved model markup cannot reach the browser.
      coro::async_generator(function() {
        span <- NULL
        if (tracing) {
          span <- local_conversation_turn_span()
        }
        scanner <- citation_scanner(corpus)

        for (chunk in coro::await_each(raw_stream)) {
          if (is.character(chunk)) {
            out <- scanner$feed(chunk)
            if (nzchar(out)) yield(out)
          } else if (S7::S7_inherits(chunk, ellmer::ContentText)) {
            out <- scanner$feed(chunk@text)
            if (nzchar(out)) yield(ellmer::ContentText(out))
          } else {
            yield(chunk)
          }
        }

        private$consume_restore_reminder(restore_reminder_pending)

        tail <- scanner$finish()
        if (nzchar(tail)) {
          yield(if (as_content) ellmer::ContentText(tail) else tail)
        }

        decisions <- scanner$decisions()
        verified <- any(vapply(
          decisions,
          function(d) identical(d$status, "accepted"),
          logical(1)
        ))
        turns <- self$get_turns()
        tag <- derive_provenance_tag(
          collect_appended_tags(turns, from_index),
          verified
        )

        if (tracing) {
          # An absent provenance tag must not suppress the citation audit record.
          if (!is.na(tag)) {
            tryCatch(
              commons_span_set_attribute(span, "commons.provenance.tag", tag),
              error = function(err) NULL
            )
          }
          tryCatch(
            commons_span_set_attribute(
              span,
              "commons.citation.candidates",
              jsonlite::toJSON(decisions, auto_unbox = TRUE)
            ),
            error = function(err) NULL
          )
          tryCatch(
            record_provenance_span(tag, decisions),
            error = function(err) NULL
          )
        }

        aside <- provenance_aside(tag)
        if (nzchar(aside)) {
          yield(if (as_content) ellmer::ContentText(aside) else aside)
        }
        coro::exhausted()
      })()
    },

    citation_corpus = function() {
      private$corpus
    },

    queue_restore_reminder = function() {
      private$restore_reminder_pending <- TRUE
      invisible(self)
    },

    prewarm = function() {
      # A direct call is typically warming caches ahead of deployment, so
      # failures propagate: a cold cache should fail the deploy.
      # prewarm_on_idle() downgrades them to warnings.
      private$prewarm_context()
      private$prewarm_sources()
      invisible(self)
    }
  ),
  private = list(
    prewarm_context = function() {
      layer <- private$context_layer
      layer_state <- if (is.null(layer)) NULL else context_layer_state(layer)
      if (!is.null(layer_state) && length(layer_state$docs) > 0) {
        local_commons_span(
          "commons_context_prewarm",
          attributes = list(
            "commons.context.n_docs" = length(layer_state$docs),
            # tryCatch: telemetry must not abort prewarming (resolving the
            # cache dir can fail or warn on an unwritable root).
            "commons.context.cache_hit" =
              !is.null(layer_state$store) ||
              isTRUE(tryCatch(
                context_cache_enabled() &&
                  file.exists(context_store_path(layer_state$docs)),
                error = function(err) FALSE
              ))
          )
        )
        context_store(layer)
      }
      invisible(self)
    },

    prewarm_sources = function() {
      for (source in private$sources) {
        source_prewarm(source)
      }
      invisible(self)
    },

    sources = NULL,
    context_layer = NULL,
    registry = NULL,
    definitions = NULL,
    semantic_models = NULL,
    calculations = NULL,
    fn_sources = NULL,
    measure_provenance = NULL,
    injections = NULL,
    tracing = FALSE,
    first_touch = NULL,
    handles = NULL,
    worker = NULL,
    corpus = NULL,
    citation_request = NULL,
    restore_reminder_pending = FALSE,

    prepare_turn_inputs = function(inputs) {
      inputs <- append_turn_reminder(inputs, self$get_model())
      if (private$restore_reminder_pending) {
        inputs <- append_restored_conversation_reminder(inputs)
      }
      inputs
    },

    consume_restore_reminder = function(was_pending) {
      if (was_pending) {
        private$restore_reminder_pending <- FALSE
      }
      invisible(NULL)
    }
  )
)

ellmer_chat_initialize_args <- function(client) {
  args <- list(provider = client$get_provider())
  model <- tryCatch(
    client$get_model_object(),
    error = function(err) NULL
  )
  if (!is.null(model)) {
    args$model <- model
  }
  args$echo <- "none"
  args
}

turn_has_user_message <- function(turn) {
  any(!vapply(turn@contents, is_tool_result_content, logical(1)))
}

# Measures can take a named source's connection as an argument.
measure_injectables <- function(sources) {
  named <- sources[rlang::have_name(sources)]
  lapply(named, function(source) data_source_state(source)$con)
}
