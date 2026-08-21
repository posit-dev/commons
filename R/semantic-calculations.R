new_typed_argument <- function(
  name,
  type,
  description = NULL,
  default = NULL,
  has_default = FALSE,
  identifier = FALSE,
  choices = NULL
) {
  rlang::check_string(name)
  rlang::check_string(type)
  if (!is.null(description)) {
    rlang::check_string(description)
  }
  type <- rlang::arg_match(
    type,
    c("string", "integer", "number", "logical", "date", "datetime")
  )
  rlang::check_bool(has_default)
  rlang::check_bool(identifier)
  if (identifier) {
    if (!identical(type, "string")) {
      cli::cli_abort("Identifier argument {.val {name}} must use string type.")
    }
    choices <- normalize_identifier_choices(choices)
    if (length(choices) == 0L) {
      cli::cli_abort(
        "Identifier argument {.val {name}} must have an explicit allowlist."
      )
    }
  } else if (!is.null(choices)) {
    cli::cli_abort(
      "Only identifier arguments can declare {.arg choices}."
    )
  }
  argument <- list(
    name = name,
    type = type,
    description = description,
    has_default = has_default,
    default = default,
    identifier = identifier,
    choices = choices
  )
  if (has_default) {
    validate_typed_value(default, argument)
  }
  argument
}

new_trusted_calculation <- function(
  name,
  description,
  sql,
  arguments = list(),
  model = NULL
) {
  rlang::check_string(name)
  rlang::check_string(description)
  rlang::check_string(sql)
  check_trusted_query(sql)
  arguments <- normalize_calculation_arguments(arguments)
  tokens <- calculation_tokens(sql)
  expected <- vapply(arguments, `[[`, character(1), "name")
  unknown <- setdiff(tokens, expected)
  missing <- setdiff(expected, tokens)
  if (length(unknown) || length(missing)) {
    cli::cli_abort(c(
      "Calculation placeholders must match its arguments exactly.",
      "i" = if (length(unknown)) {
        "Unknown placeholders: {.val {unknown}}."
      },
      "i" = if (length(missing)) {
        "Arguments without placeholders: {.val {missing}}."
      }
    ))
  }
  duplicated <- unique(tokens[duplicated(tokens)])
  if (length(duplicated)) {
    cli::cli_abort(
      "Calculation placeholders must appear once: {.val {duplicated}}."
    )
  }
  structure(
    list(
      name = name,
      description = description,
      sql = sql,
      arguments = arguments,
      model = model
    ),
    class = "commons_trusted_calculation"
  )
}

calculations_registry <- function(sources) {
  registry <- list()
  source_names <- rlang::names2(sources)
  for (i in seq_along(sources)) {
    calculations <- sources[[i]]$calculations %||% list()
    for (calculation in calculations) {
      calculation$source <- source_names[[i]]
      calculation$key <- calculation_key(calculation)
      registry[[length(registry) + 1L]] <- calculation
    }
  }
  registry
}

semantic_model_calculations <- function(models) {
  calculations <- list()
  for (model_label in names(models)) {
    for (calculation in models[[model_label]]$calculations %||% list()) {
      calculation$model <- model_label
      calculations[[length(calculations) + 1L]] <- calculation
    }
  }
  calculations
}

calculation_key <- function(calculation) {
  if (is.null(calculation$model)) {
    calculation$name
  } else {
    paste(calculation$model, calculation$name, sep = "::")
  }
}

resolve_calculation <- function(
  calculations,
  name,
  source_name = NULL,
  call = rlang::caller_env()
) {
  rlang::check_string(name, call = call)
  candidates <- Filter(function(calculation) {
    (is.null(source_name) || identical(calculation$source, source_name)) &&
      name %in% c(calculation$name, calculation$key)
  }, calculations)
  if (length(candidates) == 1L) {
    return(candidates[[1]])
  }
  if (length(candidates) > 1L) {
    choices <- unique(vapply(candidates, `[[`, character(1), "key"))
    cli::cli_abort(c(
      "Trusted calculation name {.val {name}} is ambiguous.",
      "i" = "Use a qualified name: {.val {choices}}."
    ), call = call)
  }
  available <- unique(vapply(calculations, `[[`, character(1), "key"))
  cli::cli_abort(c(
    "No trusted calculation is named {.val {name}}.",
    "i" = "Available calculations: {.val {available}}."
  ), call = call)
}

call_calculation_impl <- function(
  calculations,
  sources,
  handles,
  name,
  arguments = "{}",
  source_name = NULL
) {
  source <- resolve_sql_source(sources, source_name)
  source_label <- source_name %||% rlang::names2(sources)[[1]]
  n_models <- length(source$semantic_models)
  source <- source_hydrate_semantic_models(source, name)
  if (length(source$semantic_models) > n_models) {
    source_index <- if (length(sources) == 1L) {
      1L
    } else {
      match(source_label, names(sources))
    }
    sources[[source_index]] <- source
    calculations <- calculations_registry(sources)
  }
  calculation <- resolve_calculation(
    calculations,
    name,
    source_name = source_label
  )
  prepared <- prepare_calculation(
    calculation,
    parse_json_args(arguments),
    source$con
  )
  result <- source_query_bind(source, prepared$sql, prepared$bindings)
  advert <- register_handle(handles, result)
  tool_result(
    paste(c(df_to_markdown(result), advert), collapse = "\n\n"),
    title = sprintf(
      "Calculation: %s%s",
      html_escape(calculation$key),
      source_label(source_name)
    ),
    icon = maybe_icon("shield-check"),
    markdown = sprintf(
      "```sql\n%s\n```\n\n%s",
      prepared$sql,
      df_to_markdown(result)
    ),
    html = measure_display_html(prepared$arguments, result),
    tag = "A",
    show_tag = FALSE
  )
}

prepare_calculation <- function(calculation, arguments, con) {
  values <- validate_typed_arguments(
    calculation$arguments,
    arguments,
    include_defaults = TRUE
  )
  sql <- calculation$sql
  bindings <- list()
  for (argument in calculation$arguments) {
    name <- argument$name
    token <- paste0("{{", name, "}}")
    value <- values[[name]]
    if (argument$identifier) {
      value <- argument$choices[[as.character(value)]]
      replacement <- as.character(DBI::dbQuoteIdentifier(con, value))
    } else {
      replacement <- "?"
      bindings[[length(bindings) + 1L]] <- value
    }
    sql <- sub(token, replacement, sql, fixed = TRUE)
  }
  check_trusted_query(sql)
  list(sql = sql, bindings = bindings, arguments = values)
}

check_trusted_query <- function(sql, call = rlang::caller_env()) {
  query <- sub(";[[:space:]]*$", "", trimws(sql))
  if (
    grepl(";", query, fixed = TRUE) ||
      !grepl("^(SELECT|WITH)\\b", query, ignore.case = TRUE)
  ) {
    cli::cli_abort(
      "Trusted calculations must contain exactly one read-only SELECT query.",
      call = call
    )
  }
  check_query(query, call = call)
}

validate_typed_arguments <- function(
  specifications,
  arguments,
  include_defaults = FALSE,
  call = rlang::caller_env()
) {
  if (!is.list(arguments) || (length(arguments) && is.null(names(arguments)))) {
    cli::cli_abort("{.arg arguments} must be a JSON object.", call = call)
  }
  if (any(!nzchar(names(arguments))) || anyDuplicated(names(arguments))) {
    cli::cli_abort(
      "{.arg arguments} must have unique, non-empty names.",
      call = call
    )
  }
  expected <- vapply(specifications, `[[`, character(1), "name")
  extra <- setdiff(names(arguments), expected)
  if (length(extra)) {
    cli::cli_abort(
      "Unexpected argument{?s}: {.val {extra}}.",
      call = call
    )
  }
  required <- vapply(specifications, function(x) !x$has_default, logical(1))
  missing <- setdiff(expected[required], names(arguments))
  if (length(missing)) {
    cli::cli_abort(
      "Missing required argument{?s}: {.val {missing}}.",
      call = call
    )
  }
  values <- list()
  for (specification in specifications) {
    name <- specification$name
    if (!name %in% names(arguments)) {
      if (include_defaults && specification$has_default) {
        values[[name]] <- specification$default
      }
      next
    }
    values[[name]] <- validate_typed_value(
      arguments[[name]],
      specification,
      call = call
    )
  }
  values
}

validate_typed_value <- function(
  value,
  specification,
  call = rlang::caller_env()
) {
  name <- specification$name
  if (length(value) != 1L || is.list(value) || is.na(value)) {
    cli::cli_abort(
      "Argument {.val {name}} must be one non-missing value.",
      call = call
    )
  }
  valid <- switch(
    specification$type,
    string = is.character(value),
    integer = is.numeric(value) &&
      is.finite(value) &&
      abs(value) < 2^53 &&
      isTRUE(value == trunc(value)),
    number = is.numeric(value) && is.finite(value),
    logical = is.logical(value),
    date = is.character(value) && valid_iso_date(value),
    datetime = is.character(value) && valid_iso_datetime(value)
  )
  if (!isTRUE(valid)) {
    article <- if (identical(specification$type, "integer")) "an" else "a"
    cli::cli_abort(
      "Argument {.val {name}} must be {article} {specification$type} value.",
      call = call
    )
  }
  if (specification$identifier) {
    choices <- names(specification$choices)
    if (!value %in% choices) {
      cli::cli_abort(c(
        "Identifier argument {.val {name}} does not allow {.val {value}}.",
        "i" = "Allowed values: {.val {choices}}."
      ), call = call)
    }
  }
  value
}

valid_iso_date <- function(value) {
  if (!grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", value)) {
    return(FALSE)
  }
  parsed <- suppressWarnings(as.Date(value, format = "%Y-%m-%d"))
  !is.na(parsed) && identical(format(parsed, "%Y-%m-%d"), value)
}

valid_iso_datetime <- function(value) {
  if (!grepl(
    paste0(
      "^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T]",
      "[0-9]{2}:[0-9]{2}(:[0-9]{2}(\\.[0-9]+)?)?",
      "(Z|[+-][0-9]{2}:[0-9]{2})?$"
    ),
    value
  )) {
    return(FALSE)
  }
  date <- substr(value, 1L, 10L)
  hour <- as.integer(substr(value, 12L, 13L))
  minute <- as.integer(substr(value, 15L, 16L))
  second <- if (substr(value, 17L, 17L) == ":") {
    as.integer(substr(value, 18L, 19L))
  } else {
    0L
  }
  offset <- regmatches(value, regexpr("[+-][0-9]{2}:[0-9]{2}$", value))
  valid_offset <- length(offset) == 0L || (
    as.integer(substr(offset, 2L, 3L)) <= 23L &&
      as.integer(substr(offset, 5L, 6L)) <= 59L
  )
  valid_iso_date(date) &&
    hour <= 23L &&
    minute <= 59L &&
    second <= 59L &&
    valid_offset
}

normalize_calculation_arguments <- function(arguments) {
  if (length(arguments) == 0L) {
    return(list())
  }
  if (!is.list(arguments)) {
    cli::cli_abort("{.arg arguments} must be a list of typed arguments.")
  }
  names <- vapply(arguments, `[[`, character(1), "name")
  if (anyDuplicated(names)) {
    cli::cli_abort("Calculation argument names must be unique.")
  }
  names(arguments) <- names
  arguments
}

normalize_identifier_choices <- function(choices) {
  if (is.character(choices)) {
    choices <- as.list(choices)
  }
  if (inherits(choices, "Id")) {
    choices <- list(choices)
  }
  if (!is.list(choices)) {
    return(list())
  }
  labels <- names(choices)
  if (is.null(labels) || any(!nzchar(labels))) {
    labels <- vapply(choices, function(choice) {
      if (inherits(choice, "Id")) table_id_label(choice) else as.character(choice)
    }, character(1))
  }
  if (
    any(!vapply(choices, function(choice) {
      inherits(choice, "Id") || rlang::is_string(choice)
    }, logical(1))) ||
      anyDuplicated(labels)
  ) {
    cli::cli_abort(
      "Identifier choices must be uniquely named strings or {.cls DBI::Id} objects."
    )
  }
  names(choices) <- labels
  choices
}

calculation_tokens <- function(sql) {
  matches <- gregexpr("\\{\\{[^{}]+\\}\\}", sql, perl = TRUE)[[1]]
  if (identical(matches[[1]], -1L)) {
    return(character())
  }
  tokens <- regmatches(sql, list(matches))[[1]]
  substr(tokens, 3L, nchar(tokens) - 2L)
}

calculation_pool_text <- function(calculation, source_names = character()) {
  arguments <- calculation$arguments
  argument_text <- if (length(arguments)) {
    paste(vapply(arguments, function(argument) {
      choices <- if (argument$identifier) {
        paste0("; allowed: ", paste(names(argument$choices), collapse = ", "))
      } else {
        ""
      }
      required <- if (argument$has_default) "optional" else "required"
      description <- if (!is.null(argument$description)) {
        paste0(": ", argument$description)
      } else {
        ""
      }
      sprintf(
        "`%s` (%s, %s%s)%s",
        argument$name,
        argument$type,
        required,
        choices,
        description
      )
    }, character(1)), collapse = ", ")
  } else {
    "none"
  }
  source <- if (
    length(source_names) && nzchar(calculation$source %||% "")
  ) {
    paste0("\nSource: `", calculation$source, "`.")
  } else {
    ""
  }
  sprintf(
    "### %s --- trusted query\n%s\nArguments: %s.%s\nRun with `call_calculation`.",
    calculation$key,
    calculation$description,
    argument_text,
    source
  )
}
