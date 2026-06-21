format_measure_catalog <- function(registry) {
  if (length(registry) == 0) {
    return("(no measures registered)")
  }
  lines <- vapply(
    registry,
    function(td) sprintf("- %s: %s", tool_name(td), tool_description(td)),
    character(1)
  )
  paste(lines, collapse = "\n")
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
