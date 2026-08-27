#' Create a semantic layer
#'
#' `semantic_layer()` collects governed R measures for a [commons()] agent.
#' Data dictionary definitions and warehouse semantic models contribute through
#' [data_source()].
#'
#' @param ... [measure()] objects, lists of measures, or paths to R scripts or
#'   directories containing R scripts. Directory searches are not recursive.
#'   File and inline measures can be freely mixed.
#'
#' @section Measures from files:
#' Character paths can name R scripts or directories containing them. Functions
#' marked with `@measure` become measures; other functions in those files can be
#' used as helpers.
#'
#' The roxygen title, description, and `@return` text describe the measure.
#' Each `@param` marks a model-supplied argument and can declare its type:
#' `string`, `integer`, `number`, `boolean`, `enum[value, ...]`, or an array
#' such as `string[]`. Without a declaration, commons infers the type from the
#' default, falling back to `string`.
#'
#' Measure and helper source is visible in the agent's R session; evaluating a
#' measure's name there prints its definition. Function environments,
#' connections, and credentials are not shared with that session.
#'
#' @section Measure arguments:
#' A measure function can take two kinds of arguments:
#'
#' * Arguments documented with `@param` (or listed in `arguments`, for inline
#'   [measure()]s) are supplied by the model.
#' * Undocumented arguments are supplied by [commons()] when the measure runs.
#'   An argument named after a data source receives its connection, even if
#'   the argument has a default. Any other undocumented argument keeps its
#'   default; if it has no default, [commons()] errors. The model never sees
#'   these arguments.
#'
#' This means a measure can take the connection it needs as an argument
#' rather than relying on a variable defined elsewhere, and you can create a
#' semantic layer before connecting to a database.
#'
#' For objects that aren't data sources, such as a pins board or an API
#' client, give the argument a default that builds the object, e.g.
#' `board = pins::board_connect()`. Write the default as a call rather than a
#' reference to a variable defined elsewhere, so the measure doesn't depend on
#' where the semantic layer is created.
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
#' # In R/semantic_layer.R, `warehouse` has no @param, so commons supplies it:
#' #
#' # #' @param region `string` The sales region.
#' # #' @measure
#' # revenue <- function(region, warehouse) {
#' #   DBI::dbGetQuery(warehouse, ...)
#' # }
#'
#' agent <- commons(
#'   ellmer::chat_anthropic(),
#'   data_sources = list(warehouse = data_source(DBI::dbConnect(...))),
#'   semantic_layer = semantic_layer("R/semantic_layer.R")
#' )
#' }
#'
#' @export
semantic_layer <- function(...) {
  expanded <- expand_measures(rlang::list2(...), rlang::caller_env())
  measures <- expanded$measures

  check_measures(measures)
  names(measures) <- vapply(measures, tool_name, character(1))

  duplicated <- names(measures)[duplicated(names(measures))]
  if (length(duplicated)) {
    cli::cli_abort(
      "Measure names must be unique; duplicated name{?s}: {.val {unique(duplicated)}}."
    )
  }

  # Measures that didn't come from files (so no harvested source) still get a
  # readable, if comment-free, deparse.
  fn_sources <- expanded$fn_sources
  for (nm in setdiff(names(measures), names(fn_sources))) {
    fn_sources[[nm]] <- fn_source_text(tool_fn(measures[[nm]]))
  }

  new_semantic_layer(measures, fn_sources)
}

# Expand each `...` element into measures: character vectors are read from disk,
# lists of measures are spliced in, and a lone measure is kept as is. `env` is
# the caller of semantic_layer(), so measures read from disk close over the data
# the user defined there rather than only the global environment. Function
# sources harvested by read_measures() ride along as an attribute on each
# measure list; they're gathered here before unlist() drops attributes.
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
  fn_sources <- unlist(lapply(expanded, attr, "fn_sources"))
  fn_sources <- fn_sources[!duplicated(names(fn_sources))] %||% character()
  list(
    measures = unlist(expanded, recursive = FALSE) %||% list(),
    fn_sources = fn_sources
  )
}

#' Create a measure
#'
#' A measure is a governed calculation inside a [semantic_layer()]. Its function
#' body is ordinary R; its `arguments` schema tells the model what inputs it can
#' supply.
#'
#' Two return types receive special display handling: ggplots and [gt::gt()]
#' tables are shown directly to the user in the opened measure result. The model
#' is told that the plot or table has already been shown, so it can interpret the
#' result without repeating it.
#'
#' For full control over a result, `fn` can return an
#' [ellmer::ContentToolResult]. Its `value` is sent to the model and its
#' `extra$display` controls the shinychat display. When the display includes
#' HTML, Markdown, or text, the model is told that the result is already visible
#' to the user. An optional `extra$data` value is made available in the agent's
#' R session and removed from the result before it is returned to ellmer.
#'
#' @param name Measure name.
#' @param description What the measure computes.
#' @param fn Function that computes the measure.
#' @param arguments A named list of [ellmer::type_string()] and friends
#'   describing the arguments the model supplies. Arguments of `fn` not listed
#'   here are hidden from the model: they receive a matching data source's
#'   connection or keep their defaults. See [semantic_layer()].
#' @param title Human-readable measure title to show in user interfaces. If
#'   `NULL`, a title is derived from `name`.
#'
#' @return A measure object.
#'
#' @examples
#' table <- data.frame(term = c("Headache", "Nausea"), count = c(7, 5))
#' table_measure <- measure(
#'   "adverse_events",
#'   "Summarize adverse events.",
#'   function() {
#'     ellmer::ContentToolResult(
#'       value = "Headache: 7; Nausea: 5",
#'       extra = list(
#'         display = shinychat::tool_result_display(
#'           html = paste0(
#'             "<table><tr><td>Headache</td><td>7</td></tr>",
#'             "<tr><td>Nausea</td><td>5</td></tr></table>"
#'           )
#'         ),
#'         data = table
#'       )
#'     )
#'   }
#' )
#'
#' @seealso [semantic_layer()] to collect measures into a layer.
#'
#' @export
measure <- function(name, description, fn, arguments = list(), title = NULL) {
  rlang::check_string(name)
  rlang::check_string(description)
  rlang::check_string(title, allow_null = TRUE)
  title <- title %||% humanize_name(name)
  ellmer::tool(
    fn,
    description,
    arguments = fill_injected_arguments(arguments, fn),
    name = name,
    annotations = ellmer::tool_annotations(title = title)
  )
}

# Arguments of `fn` not described in `arguments` are supplied by commons(),
# not the model. type_ignore() satisfies ellmer's check that `arguments`
# matches formals(fn) but stays out of the model-visible schema, which is how
# measure_injection_names() tells the two kinds of argument apart.
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

# Look up each measure's undocumented arguments among the agent's named
# data_sources entries. An unmatched argument keeps its default; one with no
# default is an error.
resolve_injections <- function(
  registry,
  injectables,
  call = rlang::caller_env()
) {
  lapply(registry, function(td) {
    needed <- measure_injection_names(td)
    unmatched <- setdiff(needed, names(injectables))
    no_default <- unmatched[vapply(
      unmatched,
      function(nm) identical(formals(td)[[nm]], quote(expr = )),
      logical(1)
    )]
    if (length(no_default)) {
      available <- if (length(injectables)) {
        cli::format_inline("Available sources: {.val {names(injectables)}}.")
      } else {
        "{.arg data_sources} has no named sources."
      }
      cli::cli_abort(
        c(
          "Measure {.val {tool_name(td)}} has undocumented {cli::qty(no_default)}argument{?s} {.arg {no_default}} matching no data source.",
          i = available
        ),
        call = call
      )
    }
    injectables[intersect(needed, names(injectables))]
  })
}

new_semantic_layer <- function(measures = list(), fn_sources = character()) {
  structure(
    list(measures = measures, fn_sources = fn_sources),
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

measure_schema_text <- function(td, source_names = character()) {
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
    "### %s\n%s\n\n%sarguments:\n%s",
    tool_name(td),
    tool_description(td),
    measure_sources_line(td, source_names),
    args
  )
}

# When an agent has several data sources, noting which one(s) a measure
# queries points the SQL fallback at the right source. `source_names` is empty
# for single-source agents, so the line never appears there.
measure_sources_line <- function(td, source_names) {
  used <- intersect(measure_injection_names(td), source_names)
  if (length(used) == 0) {
    return("")
  }
  sprintf("sources: %s\n", paste(used, collapse = ", "))
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
tool_fn <- function(td) S7::S7_data(td)
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
