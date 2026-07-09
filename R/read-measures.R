read_measures <- function(paths, env = globalenv()) {
  rlang::check_installed("roxygen2")

  registerS3method(
    "roxy_tag_parse",
    "roxy_tag_measure",
    function(x) roxygen2::tag_toggle(x),
    envir = asNamespace("roxygen2")
  )
  registerS3method(
    "roxy_tag_parse",
    "roxy_tag_provenance",
    function(x) roxygen2::tag_value(x),
    envir = asNamespace("roxygen2")
  )

  if (!is.character(paths)) {
    cli::cli_abort("{.arg paths} must be a character vector of file or directory paths.")
  }

  files <- resolve_measure_files(paths)

  # Source every file into one shared env (in order) so a measure can call a
  # helper defined in a sibling file. The parsed block only reads tags. The env
  # inherits from `env` (the semantic_layer() caller) so measures can reference
  # data defined there, not only in the global environment.
  measure_env <- new.env(parent = env)
  for (file in files) {
    sys.source(file, envir = measure_env)
  }

  measures <- unlist(
    lapply(files, function(file) read_measures_file(file, measure_env)),
    recursive = FALSE
  )
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

read_measures_file <- function(file, env) {
  blocks <- roxygen2::parse_file(file)
  measures <- lapply(blocks, function(block) block_to_measure(block, env))
  Filter(Negate(is.null), measures)
}

block_to_measure <- function(block, env) {
  if (is.null(roxygen2::block_get_tag(block, "measure"))) {
    return(NULL)
  }

  name <- block$object$topic
  fn <- get(name, envir = env)
  if (!is.function(fn)) {
    return(NULL)
  }

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
    # An argument without @param is supplied by commons(), not the model.
    if (is.null(param_text[[nm]])) {
      next
    }
    required <- identical(formals[[nm]], quote(expr = ))
    args[[nm]] <- param_type(
      param_text[[nm]],
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
