#' Read measures from R scripts
#'
#' Reads [measure()] definitions from one or more R scripts, deriving each
#' measure from a documented function. Every top-level function assignment that
#' carries a roxygen2 block becomes a measure: its name is the function name,
#' its description is the `@title`, `@description`, and `@return`, its body is
#' the function, and its arguments come from the `@param` tags.
#'
#' Argument types are declared with a leading type code span in the `@param`
#' description:
#'
#' ```r
#' #' @param region `string` The sales region.
#' #' @param period `enum[day, week, month]` Aggregation period.
#' #' @param tags `string[]` Tag filters.
#' ```
#'
#' Supported types are `string`, `integer`, `number`, `boolean`, `enum[...]`
#' for a fixed set of values, and `{type}[]` for an array. An argument is
#' required when its formal has no default value. When a `@param` has no type
#' code span, its type is inferred from the formal's default, falling back to a
#' string.
#'
#' @param paths Character vector of paths to R scripts or directories. For a
#'   directory, all `.R` files in it are read.
#'
#' @return A list of [measure()] objects, suitable for [semantic_layer()].
#'
#' @seealso [measure()] to define a measure directly, and [semantic_layer()] to
#'   collect the result into a layer.
#'
#' @examples
#' \dontrun{
#' semantic_layer(read_measures("measures.R"))
#' }
#'
#' @export
read_measures <- function(paths) {
  rlang::check_installed("roxygen2")

  if (!is.character(paths)) {
    cli::cli_abort("{.arg paths} must be a character vector of file or directory paths.")
  }

  files <- resolve_measure_files(paths)
  measures <- unlist(lapply(files, read_measures_file), recursive = FALSE)
  measures %||% list()
}

resolve_measure_files <- function(paths, call = rlang::caller_env()) {
  missing <- paths[!file.exists(paths)]
  if (length(missing)) {
    cli::cli_abort(
      "{cli::qty(missing)}Path{?s} {?does/do} not exist: {.path {missing}}.",
      call = call
    )
  }

  files <- unlist(lapply(paths, function(path) {
    if (dir.exists(path)) {
      list.files(path, pattern = "[.][Rr]$", full.names = TRUE)
    } else {
      path
    }
  }))
  unique(files)
}

read_measures_file <- function(file) {
  blocks <- roxygen2::parse_file(file)
  measures <- lapply(blocks, block_to_measure)
  Filter(Negate(is.null), measures)
}

block_to_measure <- function(block) {
  fn <- block$object$value
  if (!is.function(fn)) {
    return(NULL)
  }

  name <- block$object$topic
  description <- block_description(block)
  arguments <- block_arguments(block, fn)

  measure(name, description, fn, arguments = arguments)
}

block_description <- function(block) {
  parts <- c(
    roxygen2::block_get_tag_value(block, "title"),
    roxygen2::block_get_tag_value(block, "description"),
    {
      ret <- roxygen2::block_get_tag_value(block, "return")
      if (!is.null(ret)) paste0("Returns: ", ret)
    }
  )
  paste(parts, collapse = "\n\n")
}

block_arguments <- function(block, fn) {
  formals <- formals(fn)
  param_text <- block_param_text(block)

  args <- list()
  for (nm in names(formals)) {
    required <- identical(formals[[nm]], quote(expr = ))
    args[[nm]] <- param_type(
      param_text[[nm]] %||% "",
      default = formals[[nm]],
      required = required
    )
  }
  args
}

# The raw tag text is read instead of `val$description` so the type code span
# survives verbatim: the markdown roclet would otherwise turn the `[...]` inside
# it into a `\link{...}` once roxygen2's markdown state is active.
block_param_text <- function(block) {
  tags <- roxygen2::block_get_tags(block, "param")
  names <- vapply(tags, function(t) t$val$name, character(1))
  text <- lapply(tags, function(t) trimws(sub("^\\s*\\S+\\s*", "", t$raw)))
  names(text) <- names
  text
}

# Parse a `@param` description into an ellmer type, using a leading type code
# span (e.g. `enum[a, b]`) when present and otherwise inferring from the
# formal's default.
param_type <- function(text, default, required) {
  re <- "^\\s*`([a-zA-Z]+)(\\[[^]]*\\])?`\\s*(.*)$"
  m <- regmatches(text, regexec(re, text, perl = TRUE))[[1]]

  if (length(m) == 0) {
    return(infer_type(default, description = trimws(text), required = required))
  }

  kind <- tolower(m[2])
  bracket <- m[3]
  description <- trimws(m[4])

  if (nzchar(bracket)) {
    inner <- trimws(substr(bracket, 2, nchar(bracket) - 1))
    if (kind == "enum") {
      values <- trimws(strsplit(inner, ",")[[1]])
      return(ellmer::type_enum(
        values = values,
        description = description,
        required = required
      ))
    }
    return(ellmer::type_array(
      items = scalar_type(kind, ""),
      description = description,
      required = required
    ))
  }

  scalar_type(kind, description, required = required)
}

scalar_type <- function(kind, description, required = TRUE) {
  switch(
    kind,
    integer = ellmer::type_integer(description, required = required),
    number = ellmer::type_number(description, required = required),
    boolean = ellmer::type_boolean(description, required = required),
    ellmer::type_string(description, required = required)
  )
}

infer_type <- function(default, description, required) {
  value <- tryCatch(eval(default), error = function(e) NULL)
  kind <- if (is.logical(value)) {
    "boolean"
  } else if (is.integer(value)) {
    "integer"
  } else if (is.numeric(value)) {
    "number"
  } else {
    "string"
  }
  scalar_type(kind, description, required = required)
}
