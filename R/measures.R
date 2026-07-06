#' Create a semantic layer
#'
#' A semantic layer is a collection of governed measures available to a
#' [commons()] agent.
#'
#' @param ... [measure()] objects, lists of measures, or paths to R scripts or
#'   directories. File and inline measures can be freely mixed.
#'
#' @details
#' A measure function's formals split into two groups:
#'
#' * Formals documented with `@param` (or, for inline [measure()]s, named in
#'   `arguments`) are the measure's arguments, supplied by the model.
#' * Formals without documentation are injection parameters. When the agent
#'   runs the measure, [commons()] supplies each one by name: the name of a
#'   [data_sources()] entry receives that source's connection, and the name of
#'   a `resources` entry receives that object. Injection parameters are never
#'   shown to the model.
#'
#' So a measure that queries a database declares the connection it needs
#' rather than closing over one, and the semantic layer can be created before
#' any connection exists; binding happens when the agent is assembled.
#'
#' @return A `commons_semantic_layer` object.
#'
#' @seealso [measure()] to define a measure.
#'
#' @examples
#' semantic_layer(
#'   measure(
#'     "order_count",
#'     "Count of orders.",
#'     function() 10,
#'     arguments = list()
#'   )
#' )
#'
#' \dontrun{
#' # In R/semantic_layer.R, `warehouse` has no @param, so it's an injection
#' # parameter:
#' #
#' # #' @param region `string` The sales region.
#' # #' @measure
#' # revenue <- function(region, warehouse) {
#' #   DBI::dbGetQuery(warehouse, ...)
#' # }
#'
#' agent <- commons(
#'   ellmer::chat_anthropic(),
#'   data_sources = data_sources(
#'     warehouse = data_source(DBI::dbConnect(...))
#'   ),
#'   semantic_layer = semantic_layer("R/semantic_layer.R")
#' )
#' }
#'
#' @export
semantic_layer <- function(...) {
  measures <- expand_measures(rlang::list2(...), rlang::caller_env())

  check_measures(measures)
  names(measures) <- vapply(measures, tool_name, character(1))

  duplicated <- names(measures)[duplicated(names(measures))]
  if (length(duplicated)) {
    cli::cli_abort(
      "Measure names must be unique; duplicated name{?s}: {.val {unique(duplicated)}}."
    )
  }

  new_semantic_layer(measures)
}

# Expand each `...` element into measures: character vectors are read from disk,
# lists of measures are spliced in, and a lone measure is kept as is. `env` is
# the caller of semantic_layer(), so measures read from disk close over the data
# the user defined there rather than only the global environment.
expand_measures <- function(args, env = rlang::caller_env()) {
  expanded <- lapply(args, function(arg) {
    if (is.character(arg)) {
      read_measures(arg, env)
    } else if (is_measure_list(arg)) {
      arg
    } else {
      list(arg)
    }
  })
  unlist(expanded, recursive = FALSE) %||% list()
}

#' Create a measure
#'
#' A measure is a governed calculation inside a [semantic_layer()]. Its function
#' body is ordinary R; its `arguments` schema tells the model what inputs it can
#' supply.
#'
#' @param name Measure name.
#' @param description What the measure computes.
#' @param fn Function that computes the measure.
#' @param arguments A named list of [ellmer::type_string()] and friends, one per
#'   model-supplied formal of `fn`. Formals of `fn` not named here are
#'   injection parameters: hidden from the model and supplied by [commons()]
#'   from its named [data_sources()] and `resources`.
#' @param title Human-readable measure title to show in user interfaces. If
#'   `NULL`, a title is derived from `name`.
#'
#' @return A measure object.
#'
#' @seealso [semantic_layer()] to collect measures into a layer.
#'
#' @export
measure <- function(name, description, fn, arguments = list(), title = NULL) {
  title <- title %||% humanize_name(name)
  ellmer::tool(
    fn,
    description,
    arguments = fill_injected_arguments(arguments, fn),
    name = name,
    annotations = ellmer::tool_annotations(title = title)
  )
}

# Formals of `fn` absent from `arguments` are injection parameters. Typing them
# as ignored keeps ellmer's arguments-match-formals check satisfied while
# excluding them from the model-visible schema, so they're recoverable later as
# setdiff(formals, schema properties).
fill_injected_arguments <- function(arguments, fn) {
  injected <- setdiff(names(formals(fn)), names(arguments))
  for (nm in injected) {
    arguments[[nm]] <- ellmer::type_ignore()
  }
  arguments
}

measure_injection_names <- function(td) {
  setdiff(names(formals(td)), names(tool_properties(td)))
}

# Match each measure's injection parameters against the agent's named data
# sources and resources, erroring on names that match neither.
resolve_injections <- function(registry, injectables, call = rlang::caller_env()) {
  lapply(registry, function(td) {
    needed <- measure_injection_names(td)
    unmatched <- setdiff(needed, names(injectables))
    if (length(unmatched)) {
      available <- if (length(injectables)) {
        cli::format_inline("Available names: {.val {names(injectables)}}.")
      } else {
        "No named data sources or resources are available."
      }
      cli::cli_abort(
        c(
          "Measure {.val {tool_name(td)}} declares undocumented {cli::qty(unmatched)}argument{?s} {.arg {unmatched}} matching no data source or resource name.",
          i = available
        ),
        call = call
      )
    }
    injectables[needed]
  })
}

new_semantic_layer <- function(measures = list()) {
  structure(
    list(measures = measures),
    class = "commons_semantic_layer"
  )
}

check_semantic_layer <- function(semantic_layer, call = rlang::caller_env()) {
  if (!inherits(semantic_layer, "commons_semantic_layer")) {
    cli::cli_abort(
      "{.arg semantic_layer} must be a {.fn semantic_layer}.",
      call = call
    )
  }
}

check_measures <- function(measures, call = rlang::caller_env()) {
  ok <- vapply(measures, inherits, logical(1), "ellmer::ToolDef")
  if (!all(ok)) {
    cli::cli_abort(
      "Every item in {.arg semantic_layer} must be created by {.fn measure}.",
      call = call
    )
  }
}

is_measure_list <- function(x) {
  is.list(x) && !inherits(x, "ellmer::ToolDef")
}

search_measures_text <- function(registry, query) {
  if (length(registry) == 0) {
    return("No measures are registered.")
  }

  catalog <- vapply(
    registry,
    function(td) paste(tool_name(td), tool_description(td)),
    character(1)
  )
  hits <- lexical_rank(query, catalog, n = 5)
  if (length(hits) == 0) {
    return(sprintf(
      "No measure matches \"%s\". Consider writing a SQL query.",
      query
    ))
  }

  blocks <- vapply(registry[hits], measure_schema_text, character(1))
  paste(blocks, collapse = "\n\n")
}

measure_schema_text <- function(td) {
  props <- tool_properties(td)
  args <- if (length(props) == 0) {
    "  (no arguments)"
  } else {
    paste(
      vapply(
        names(props),
        function(nm) arg_schema_line(nm, props[[nm]]),
        character(1)
      ),
      collapse = "\n"
    )
  }
  sprintf(
    "### %s\n%s\n\narguments:\n%s",
    tool_name(td),
    tool_description(td),
    args
  )
}

arg_schema_line <- function(name, type) {
  kind <- type_kind(type)
  required <- if (isTRUE(S7::prop(type, "required"))) "required" else "optional"
  detail <- switch(
    kind,
    enum = sprintf("one of {%s}", paste(type_values(type), collapse = ", ")),
    array = sprintf(
      "array of {%s}",
      paste(type_values(S7::prop(type, "items")), collapse = ", ")
    ),
    kind
  )
  desc <- S7::prop(type, "description") %||% ""
  sprintf("  - %s (%s, %s) %s", name, detail, required, desc)
}

# The provider sees only `call_measure`, so measure arguments are checked here.
validate_measure_args <- function(td, args, call = rlang::caller_env()) {
  props <- tool_properties(td)
  args <- args %||% list()

  unknown <- setdiff(names(args), names(props))
  if (length(unknown)) {
    cli::cli_abort(
      c(
        "Unknown {cli::qty(unknown)}argument{?s} for measure {.val {tool_name(td)}}: {.val {unknown}}.",
        i = "Valid arguments: {.val {names(props)}}."
      ),
      call = call
    )
  }

  for (nm in names(props)) {
    type <- props[[nm]]
    if (is.null(args[[nm]])) {
      if (isTRUE(S7::prop(type, "required"))) {
        cli::cli_abort(
          "Measure {.val {tool_name(td)}} requires argument {.arg {nm}}.",
          call = call
        )
      }
      next
    }
    args[[nm]] <- coerce_arg(td, nm, type, args[[nm]], call = call)
  }

  args
}

coerce_arg <- function(td, nm, type, value, call = rlang::caller_env()) {
  kind <- type_kind(type)

  if (kind %in% c("enum", "array")) {
    allowed <- if (kind == "enum") {
      type_values(type)
    } else {
      type_values(S7::prop(type, "items"))
    }
    bad <- setdiff(as.character(value), allowed)
    if (length(bad)) {
      cli::cli_abort(
        c(
          "Invalid {cli::qty(bad)}value{?s} for {.arg {nm}} of measure {.val {tool_name(td)}}: {.val {bad}}.",
          i = "Allowed: {.val {allowed}}."
        ),
        call = call
      )
    }
    return(as.character(value))
  }

  switch(
    kind,
    number = as.numeric(value),
    integer = as.integer(value),
    boolean = as.logical(value),
    as.character(value)
  )
}

# Isolate the ellmer internals used by registered measure tools.
tool_name <- function(td) S7::prop(td, "name")
tool_description <- function(td) S7::prop(td, "description")
tool_title <- function(td) {
  annotations <- S7::prop(td, "annotations")
  annotations$title %||% humanize_name(tool_name(td))
}
tool_properties <- function(td) {
  S7::prop(S7::prop(td, "arguments"), "properties")
}
type_values <- function(type) S7::prop(type, "values")

type_kind <- function(type) {
  cls <- class(type)[[1]]
  switch(
    cls,
    "ellmer::TypeEnum" = "enum",
    "ellmer::TypeArray" = "array",
    "ellmer::TypeBasic" = S7::prop(type, "type"),
    "string"
  )
}

humanize_name <- function(x) {
  gsub("_", " ", x, fixed = TRUE)
}
