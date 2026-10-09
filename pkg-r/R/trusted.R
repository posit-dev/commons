#' Trusted calculations and context
#'
#' `trusted()` gathers a team's data sources, semantic layer, and context layer
#' into one object that code can call directly, without a model. It's the part
#' of a [commons()] agent that doesn't depend on an LLM: pass it to `commons()`
#' to build an agent, or place it in an R session that a coding agent already
#' controls.
#'
#' @inheritParams commons
#'
#' @return A `commons_trusted` object with methods:
#'
#' * `$search(query)` searches trusted calculations.
#' * `$measure(name, arguments)` runs a measure.
#' * `$metrics(metrics, dimensions, filters, where, arguments, source)`
#'   computes governed metrics.
#' * `$calculation(name, arguments, source)` runs an exact trusted query.
#' * `$context(query)` searches business context.
#' * `$describe(table, source)` describes a table.
#' * `$connection(source)` returns a source's DBI connection, for queries
#'   that no trusted calculation answers.
#'
#' @examples
#' \dontrun{
#' tr <- trusted(
#'   data_source(warehouse = con),
#'   semantic_layer = sem,
#'   context_layer = context_layer(files = "notes.md")
#' )
#' tr
#' tr$search("revenue by region")
#' tr$measure("revenue_by_region", arguments = list(region = "West"))
#'
#' # The same object backs an agent:
#' agent <- commons(ellmer::chat_anthropic(), tr)
#' }
#' @export
trusted <- function(data_sources, semantic_layer = NULL, context_layer = NULL) {
  new_trusted(data_sources, semantic_layer, context_layer)
}

new_trusted <- function(
  data_sources,
  semantic_layer = NULL,
  context_layer = NULL,
  call = rlang::caller_env()
) {
  data_sources <- as_data_sources(data_sources, call = call)
  check_context_layer(context_layer, call = call)
  semantic_layer <- semantic_layer %||% new_semantic_layer()
  check_semantic_layer(semantic_layer, call = call)
  Trusted$new(trusted_state(data_sources, semantic_layer, context_layer, call))
}

Trusted <- R6::R6Class(
  "commons_trusted",
  public = list(
    initialize = function(state) {
      private$state <- state
    },

    print = function(...) {
      cat(trusted_overview(private$state), sep = "\n")
      invisible(self)
    },

    search = function(query) {
      s <- private$state
      trusted_text(search_pool_text(
        s$registry,
        s$definitions,
        query,
        if (length(s$sources) > 1) names(s$sources) else character(),
        semantic_models = s$semantic_models,
        calculations = s$calculations
      ))
    },

    measure = function(name, arguments = list()) {
      s <- private$state
      run_measure(s$registry, name, arguments, s$injections, s$sources)$value
    },

    metrics = function(
      metrics,
      dimensions = NULL,
      filters = NULL,
      where = NULL,
      arguments = list(),
      source = NULL
    ) {
      s <- private$state
      query_metrics(
        s$definitions,
        s$sources,
        metrics = metrics,
        dimensions = dimensions,
        filters = filters,
        where = where,
        source_name = source,
        arguments = arguments
      )$result
    },

    calculation = function(name, arguments = list(), source = NULL) {
      run_calculation(private$state$sources, name, arguments, source)$result
    },

    context = function(query) {
      result <- search_context_tool(private$state$context_layer, query)
      trusted_text(tool_result_text(result))
    },

    describe = function(table, source = NULL) {
      src <- resolve_sql_source(private$state$sources, source)
      trusted_text(tool_result_text(describe_table_tool(src, table)))
    },

    connection = function(source = NULL) {
      src <- resolve_sql_source(private$state$sources, source)
      data_source_state(src)$con
    }
  ),
  private = list(state = NULL)
)

trusted_state_of <- function(x) object_private(x)$state

trusted_state <- function(data_sources, semantic_layer, context_layer, call) {
  semantic_state <- semantic_layer_state(semantic_layer)
  list(
    sources = data_sources,
    context_layer = augment_context_layer(context_layer, data_sources),
    has_context_layer = !is.null(context_layer),
    definitions = definitions_registry(data_sources),
    semantic_models = semantic_models_registry(data_sources),
    calculations = calculations_registry(data_sources),
    registry = semantic_state$measures,
    fn_sources = semantic_state$fn_sources,
    measure_provenance = semantic_state$measure_provenance,
    measure_display = semantic_state$measure_display,
    injections = resolve_injections(
      semantic_state$measures,
      measure_injectables(data_sources),
      call = call
    )
  )
}

trusted_overview <- function(state) {
  tables <- unlist(lapply(state$sources, function(source) {
    tables <- data_source_state(source)$tables
    if (is.character(tables)) tables else names(tables)
  }))
  n_metrics <- nrow(registry_defs(state$definitions)) +
    nrow(registry_semantic_members(state$semantic_models))
  measures <- vapply(
    state$registry,
    function(td) sprintf("  - %s: %s", tool_name(td), tool_description(td)),
    character(1)
  )
  c(
    "<commons_trusted>",
    sprintf(
      "Sources: %s. Tables: %s.",
      paste(names(state$sources) %||% "1 unnamed", collapse = ", "),
      if (length(tables)) paste(tables, collapse = ", ") else "none listed"
    ),
    if (length(measures)) c("Measures:", measures),
    if (n_metrics) sprintf("Governed metrics: %d.", n_metrics),
    if (length(state$calculations)) {
      sprintf("Exact trusted queries: %d.", length(state$calculations))
    },
    if (state$has_context_layer) "Business context is available.",
    "This object provides access to trusted code and context. Before writing",
    "your own analysis code or SQL, look for existing code with `$search()` and run it",
    "with `$measure()`, `$metrics()`, or `$calculation()`. When none fits,",
    "check `$context()` for guidance on the approach. Say in your answer",
    "which numbers came from trusted calculations and which didn't."
  )
}

tool_result_text <- function(result) {
  if (S7::S7_inherits(result, ellmer::ContentToolResult)) result@value else result
}

trusted_text <- function(text) {
  structure(paste(text, collapse = "\n"), class = "commons_trusted_text")
}

#' @export
print.commons_trusted_text <- function(x, ...) {
  cat(x, "\n", sep = "")
  invisible(x)
}
