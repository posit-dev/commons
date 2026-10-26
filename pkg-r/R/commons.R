#' Gather trusted calculations and context
#'
#' `commons()` gathers a team's data sources, semantic layer, and context layer
#' into one object, "the commons", that code can call directly without a model.
#' Pass it to [agent()] to build an agent in R, or place it in an R session
#' that a coding agent already controls.
#'
#' All arguments must be named.
#'
#' @param ... These dots are for future extensions and must be empty.
#' @param data_sources A [data_source()], or a named list of them. Measures
#'   can take a source's connection as an argument named after the source; see
#'   [semantic_layer()].
#' @param semantic_layer An optional [semantic_layer()].
#' @param context_layer An optional [context_layer()].
#'
#' @return A `commons` object with methods:
#'
#' * `$search(query)` searches trusted calculations.
#' * `$measure(name, arguments)` runs a measure.
#' * `$metrics(metrics, dimensions, filters, where, arguments, source)`
#'   computes governed metrics. `where` takes simple conditions on documented
#'   columns, either as a string like
#'   `"project = 'dplyr' AND date >= '2026-06-01'"` or as a list of
#'   `c(column, op, value)` triples.
#' * `$calculation(name, arguments, source)` runs an exact trusted query.
#' * `$context(query)` searches trusted context.
#' * `$describe(table, source)` describes a table.
#' * `$connection(source)` returns a source's DBI connection, for queries
#'   that no trusted calculation answers.
#'
#' @section Using commons with other coding agents:
#' `commons()` is the entry point to use commons with external coding agents.
#' The approach depends on whether the coding agent already has a persistent
#' R session. For example, Posit Assistant connects to the user's R session.
#' Claude Code and Codex, by contrast, do not have a built-in connection to a
#' persistent R REPL.
#'
#' **For agents that already have an R session, like Posit Assistant**, create
#' a `commons()` object in the relevant `.Rprofile` and then add a line telling
#' the agent to print it out before doing data analysis:
#'
#' ```markdown
#' The R session has an object called `commons` that holds this team's trusted
#' code and context. Before analyzing data, run `print(commons)`, and use its
#' calculations where they apply in favor of writing analysis code ad-hoc.
#' ```
#'
#' **Claude Code and Codex have no persistent R session of their own.** They can
#' get one through [MCP Console](https://t-kalinowski.github.io/mcp-console/).
#' MCP Console can be configured to run code at startup (which we'll use to
#' build `commons`), and we'll also edit the console tool's description to tell
#' the model to print out `commons` before analyzing data.
#'
#' To use MCP console, register it for the project, from the project directory:
#'
#' ```bash
#' uvx mcp-console configure-client claude --directory .
#' uvx mcp-console configure-client codex --directory .
#' ```
#'
#' Then configure MCP Console to build `commons` at startup and to mention it
#' in its tool description. A configured description replaces the one MCP
#' Console generates, so start from an export of the resolved configuration:
#'
#' ```bash
#' uvx mcp-console config resolve --full > .agents/console/config.yaml
#' ```
#'
#' In that file, set the startup code, and add the same sentence to the end of
#' the exported description:
#'
#' ```yaml
#' startup:
#'   language: r
#'   code: |
#'     commons <- acme.metrics::commons()
#'     .console$sql_connection(commons$connection())
#' tool:
#'   description: |-
#'     # ...the exported description, unchanged...
#'
#'     The R session has an object called `commons` that holds this team's
#'     trusted code and context. Before analyzing data, run
#'     `print(commons)`, and use its calculations where they apply in favor of
#'     writing analysis code ad-hoc.
#' ```
#'
#' Claude Code shows the tool description only once the agent loads the tool,
#' so add the sentence to the end of `tool.instructions` as well.
#'
#' If the commons has a context layer, `$context()` needs one more step for
#' now. It relies on DuckDB's `fts` extension, which MCP Console's sandbox
#' can't download. MCP Console can install the extension itself, but only
#' into its own cache, which R's duckdb doesn't read by default. Point R at
#' that cache with an absolute path (`~` and environment variables aren't
#' expanded):
#'
#' ```yaml
#' environment:
#'   # macOS; on Linux, /home/you/.cache/mcp-console/dependencies/duckdb
#'   DUCKDB_R_HOME: /Users/you/Library/Caches/mcp-console/dependencies/duckdb
#' ```
#'
#' Then add one more sentence to both `tool.description` and
#' `tool.instructions`, so the agent asks MCP Console to install the
#' extension:
#'
#' ```markdown
#' The first time you run `commons$context()`, include
#' `"requirements": {"duckdb": ["fts"]}` in the same call.
#' ```
#'
#' @section Lifecycle:
#' Before commons 0.2.0, `commons()` built the agent itself, taking `client`
#' as its first argument. Calls in that form still work, with a deprecation
#' warning, and return an agent as before. Use [agent()] instead.
#'
#' @examples
#' \dontrun{
#' commons <- commons(
#'   data_sources = data_source(warehouse = con),
#'   semantic_layer = sem,
#'   context_layer = context_layer(files = "notes.md")
#' )
#' commons
#' commons$search("revenue by region")
#' commons$measure("revenue_by_region", arguments = list(region = "West"))
#'
#' # The same object backs an agent:
#' agent <- agent(ellmer::chat_anthropic(), commons = commons)
#' }
#' @export
commons <- function(
  ...,
  data_sources,
  semantic_layer = NULL,
  context_layer = NULL
) {
  if (is_legacy_commons_call(...)) {
    args <- c(
      rlang::list2(...),
      if (!missing(data_sources)) list(data_sources = data_sources),
      if (!missing(semantic_layer)) list(semantic_layer = semantic_layer),
      if (!missing(context_layer)) list(context_layer = context_layer)
    )
    return(rlang::exec(
      commons_legacy,
      !!!args,
      call = rlang::current_env(),
      user_env = rlang::caller_env()
    ))
  }
  rlang::check_dots_empty()
  rlang::check_required(data_sources)
  new_commons(data_sources, semantic_layer, context_layer)
}

# Before 0.2.0, commons() took a client first and returned the agent.
is_legacy_commons_call <- function(...) {
  dots <- rlang::list2(...)
  if ("client" %in% names(dots)) {
    return(TRUE)
  }
  unnamed <- dots[!nzchar(rlang::names2(dots))]
  length(unnamed) > 0 && inherits(unnamed[[1]], "Chat")
}

commons_legacy <- function(
  client,
  data_sources,
  semantic_layer = NULL,
  context_layer = NULL,
  ...,
  instructions = NULL,
  mode = c("normal", "trusted only"),
  network = c("none", "full"),
  log = FALSE,
  share_with = NULL,
  call,
  user_env
) {
  lifecycle::deprecate_warn(
    "0.2.0",
    "commons(client)",
    "agent()",
    details = paste(
      "Build the commons with `commons(data_sources = ...)`, then pass it to",
      "`agent(client, commons = commons)`."
    ),
    env = call,
    user_env = user_env
  )
  rlang::check_dots_empty(call = call)
  commons <- new_commons(data_sources, semantic_layer, context_layer, call = call)
  agent(
    client,
    commons = commons,
    instructions = instructions,
    mode = mode,
    network = network,
    log = log,
    share_with = share_with
  )
}

new_commons <- function(
  data_sources,
  semantic_layer = NULL,
  context_layer = NULL,
  call = rlang::caller_env()
) {
  data_sources <- as_data_sources(data_sources, call = call)
  check_context_layer(context_layer, call = call)
  semantic_layer <- semantic_layer %||% new_semantic_layer()
  check_semantic_layer(semantic_layer, call = call)
  TheCommons$new(commons_state(data_sources, semantic_layer, context_layer, call))
}

TheCommons <- R6::R6Class(
  "commons",
  public = list(
    initialize = function(state) {
      private$state <- state
    },

    print = function(...) {
      cat(commons_overview(private$state), sep = "\n")
      invisible(self)
    },

    search = function(query) {
      s <- private$state
      commons_text(search_pool_text(
        s$registry,
        s$definitions,
        query,
        if (length(s$sources) > 1) names(s$sources) else character(),
        semantic_models = s$semantic_models,
        calculations = s$calculations,
        methods = TRUE
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
        where = as_where_triples(where),
        source_name = source,
        arguments = arguments
      )$result
    },

    calculation = function(name, arguments = list(), source = NULL) {
      run_calculation(private$state$sources, name, arguments, source)$result
    },

    context = function(query) {
      result <- search_context_tool(private$state$context_layer, query)
      commons_text(tool_result_text(result))
    },

    describe = function(table, source = NULL) {
      src <- resolve_sql_source(private$state$sources, source)
      commons_text(tool_result_text(describe_table_tool(src, table)))
    },

    connection = function(source = NULL) {
      src <- resolve_sql_source(private$state$sources, source)
      source_ensure_all(src)
      data_source_state(src)$con
    }
  ),
  private = list(state = NULL)
)

commons_state_of <- function(x) object_private(x)$state

commons_state <- function(data_sources, semantic_layer, context_layer, call) {
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

commons_overview <- function(state) {
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
  runners <- c("measure", "metrics", "calculation")[
    c(length(measures) > 0, n_metrics > 0, length(state$calculations) > 0)
  ]
  run_with <- cli::ansi_collapse(
    sprintf("`$%s()`", runners),
    sep2 = " or ",
    last = ", or "
  )
  c(
    "<commons>",
    sprintf(
      "Sources: %s. Tables: %s.",
      paste(names(state$sources) %||% "1 unnamed", collapse = ", "),
      if (length(tables)) paste(tables, collapse = ", ") else "none listed"
    ),
    if (length(measures)) c("Measures:", measures),
    if (n_metrics) {
      sprintf("Governed metrics: %d. Find them with `$search()`.", n_metrics)
    },
    if (length(state$calculations)) {
      sprintf(
        "Exact trusted queries: %d. Find them with `$search()`.",
        length(state$calculations)
      )
    },
    if (state$has_context_layer) "Business context is available.",
    "Methods:",
    commons_method_signatures(
      hide = setdiff(c("measure", "metrics", "calculation"), runners)
    ),
    strwrap(paste(
      "This object provides access to trusted code and context.",
      if (length(runners)) {
        paste(
          "Before writing your own analysis code or SQL, look for existing",
          "code with `$search()` and run it with", paste0(run_with, "."),
          "When none fits, check `$context(\"your query\")` for guidance on",
          "the approach."
        )
      } else {
        paste(
          "Before writing your own analysis code or SQL, check",
          "`$context(\"your query\")` for guidance on the approach."
        )
      },
      "Say in your answer which numbers came from trusted calculations and",
      "which didn't."
    ))
  )
}

# Methods that run a kind of calculation the object has none of are hidden.
commons_method_signatures <- function(hide = character()) {
  methods <- TheCommons$public_methods
  methods <- methods[
    setdiff(names(methods), c("initialize", "print", "clone", hide))
  ]
  vapply(
    names(methods),
    function(name) {
      formals <- formals(methods[[name]])
      args <- vapply(
        names(formals),
        function(arg) {
          if (rlang::is_missing(formals[[arg]])) {
            arg
          } else {
            paste(arg, "=", deparse(formals[[arg]]))
          }
        },
        character(1)
      )
      sprintf("  $%s(%s)", name, paste(args, collapse = ", "))
    },
    character(1),
    USE.NAMES = FALSE
  )
}

tool_result_text <- function(result) {
  if (S7::S7_inherits(result, ellmer::ContentToolResult)) result@value else result
}

commons_text <- function(text) {
  structure(paste(text, collapse = "\n"), class = "commons_text")
}

#' @export
print.commons_text <- function(x, ...) {
  cat(x, "\n", sep = "")
  invisible(x)
}

# Accepts the shapes models write first: a SQL-like string or unnamed triples.
as_where_triples <- function(where, call = rlang::caller_env()) {
  if (is.null(where) || is.data.frame(where) || !is.null(names(where))) {
    return(where)
  }
  if (rlang::is_string(where)) {
    return(parse_where_string(where, call = call))
  }
  if (is.character(where) && length(where) == 3) {
    where <- list(where)
  }
  lapply(where, function(triple) {
    if (!is.null(names(triple))) {
      return(triple)
    }
    if (length(triple) != 3) {
      abort_where(call)
    }
    rlang::set_names(as.list(triple), c("column", "op", "value"))
  })
}

parse_where_string <- function(where, call = rlang::caller_env()) {
  condition <- paste0(
    "^\\s*\"?([A-Za-z_][A-Za-z0-9_]*)\"?\\s*(<=|>=|!=|<>|=|<|>)\\s*",
    "('(?:[^']|'')*'|-?[0-9]+(?:\\.[0-9]+)?)\\s*(?:(?i:AND)\\s+|$)"
  )
  rest <- where
  triples <- list()
  while (nzchar(trimws(rest))) {
    match <- regmatches(rest, regexec(condition, rest, perl = TRUE))[[1]]
    if (length(match) == 0) {
      abort_where(call)
    }
    value <- match[[4]]
    quoted <- startsWith(value, "'")
    if (quoted) {
      value <- gsub("''", "'", substr(value, 2, nchar(value) - 1))
    }
    op <- if (identical(match[[3]], "<>")) "!=" else match[[3]]
    triples[[length(triples) + 1]] <- list(
      column = match[[2]],
      op = op,
      value = value,
      quoted = quoted
    )
    rest <- substring(rest, nchar(match[[1]]) + 1)
  }
  triples
}

abort_where <- function(call) {
  cli::cli_abort(
    c(
      "{.arg where} must be simple conditions on documented columns.",
      i = "Pass a string like {.code \"project = 'dplyr' AND date >= '2026-06-01'\"},
           or a list of {.code c(column, op, value)} triples.",
      i = "Operators: {.code {where_ops}}, joined by {.code AND}."
    ),
    call = call
  )
}
