catalog_calculations_registry <- function(sources) {
  registry <- list()
  labels <- rlang::names2(sources)
  for (i in seq_along(sources)) {
    source <- sources[[i]]
    catalog <- source$provider$catalog %||% source$catalog
    if (!inherits(catalog, "commons_catalog")) {
      next
    }
    for (calculation in catalog$calculations) {
      if (!catalog_calculation_available(catalog, calculation)) {
        next
      }
      key <- paste(i, calculation$id, sep = ":")
      registry[[key]] <- list(
        calculation = calculation,
        source = source,
        source_name = labels[[i]]
      )
    }
  }
  registry
}

catalog_calculation_available <- function(catalog, calculation) {
  dependencies <- c(catalog$models, catalog$relations)[calculation$dependencies]
  !any(vapply(
    dependencies,
    function(dependency) identical(dependency$access$state, "visible_only"),
    logical(1)
  ))
}

catalog_calculation_entry_available <- function(entry) {
  catalog <- entry$source$provider$catalog %||% entry$source$catalog
  catalog_calculation_available(catalog, entry$calculation)
}

calculation_pool_text <- function(entry, show_source = FALSE) {
  calculation <- entry$calculation
  arguments <- if (length(calculation$arguments)) {
    paste(vapply(names(calculation$arguments), function(name) {
      argument <- calculation$arguments[[name]]
      choices <- if (length(argument$choices)) {
        sprintf("; one of %s", paste(argument$choices, collapse = ", "))
      } else {
        ""
      }
      sprintf(
        "- `%s` (%s, %s%s)",
        name,
        argument$type,
        if (argument$required) "required" else "optional",
        choices
      )
    }, character(1)), collapse = "\n")
  } else {
    "No arguments."
  }
  paste(
    c(
      sprintf("### %s", calculation$name),
      calculation$description,
      if (show_source) sprintf("Source: `%s`", entry$source_name),
      sprintf("Run with `call_calculation(name = \"%s\")`.", calculation$name),
      arguments
    ),
    collapse = "\n"
  )
}

call_catalog_calculation <- function(
  registry,
  name,
  arguments = "{}",
  source_name = NULL,
  handles = NULL
) {
  entry <- resolve_catalog_calculation(registry, name, source_name)
  if (!catalog_calculation_entry_available(entry)) {
    cli::cli_abort(
      "Trusted calculation {.val {name}} is not queryable by this connection."
    )
  }
  calculation <- entry$calculation
  values <- validate_catalog_calculation_args(
    calculation,
    parse_json_args(arguments)
  )
  execution <- calculation$execution
  if (identical(execution$kind, "native_metric")) {
    cli::cli_abort(
      "Calculation {.val {name}} is a native metric; run it with {.fn call_metrics}."
    )
  }
  prepared <- prepare_catalog_calculation(
    execution,
    calculation$arguments,
    values,
    entry$source$con
  )
  result <- tryCatch(
    source_query_bind(entry$source, prepared$sql, prepared$params),
    error = function(err) err
  )
  if (inherits(result, "condition")) {
    state <- if (grepl(
      "permission|not authorized|insufficient privilege|access denied",
      conditionMessage(result),
      ignore.case = TRUE
    )) {
      "visible_only"
    } else {
      "unknown"
    }
    catalog_calculation_access(entry, state, conditionMessage(result))
    rlang::cnd_signal(result)
  }
  catalog_calculation_access(entry, "queryable", "trusted query succeeded")
  advert <- register_handle(handles, result)
  tool_result(
    paste(c(df_to_markdown(result), advert), collapse = "\n\n"),
    title = sprintf(
      "Ran a trusted calculation: %s%s",
      html_escape(calculation$name),
      source_label(if (nzchar(entry$source_name)) entry$source_name else NULL)
    ),
    icon = maybe_icon("shield-check"),
    markdown = sprintf(
      "```sql\n%s\n```\n\n%s",
      prepared$sql,
      df_to_markdown(result)
    ),
    html = measure_display_html(values, result),
    tag = "A",
    show_tag = FALSE
  )
}

catalog_calculation_access <- function(entry, state, evidence) {
  provider <- entry$source$provider
  if (is.null(provider)) {
    return(invisible(entry))
  }
  catalog <- provider$catalog
  for (id in entry$calculation$dependencies) {
    if (id %in% names(catalog$models)) {
      model <- catalog$models[[id]]
      model$access <- new_catalog_access(state, evidence)
      catalog$models[[id]] <- model
      for (relation_id in model$exposed) {
        relation <- catalog$relations[[relation_id]]
        relation$access <- new_catalog_access(state, evidence)
        catalog$relations[[relation_id]] <- relation
      }
    } else if (id %in% names(catalog$relations)) {
      relation <- catalog$relations[[id]]
      relation$access <- new_catalog_access(state, evidence)
      catalog$relations[[id]] <- relation
    }
  }
  provider$catalog <- catalog
  invisible(entry)
}

resolve_catalog_calculation <- function(
  registry,
  name,
  source_name = NULL,
  call = rlang::caller_env()
) {
  matches <- Filter(function(entry) {
    identical(entry$calculation$name, name) &&
      (is.null(source_name) || identical(entry$source_name, source_name))
  }, registry)
  if (length(matches) == 1) {
    return(matches[[1]])
  }
  if (length(matches) > 1) {
    cli::cli_abort(
      "Calculation {.val {name}} exists in several data sources; supply {.arg source}.",
      call = call
    )
  }
  available <- unique(vapply(
    registry,
    function(entry) entry$calculation$name,
    character(1)
  ))
  cli::cli_abort(
    c(
      "No trusted calculation named {.val {name}}.",
      "i" = "Available calculations: {.val {available}}."
    ),
    call = call
  )
}

validate_catalog_calculation_args <- function(
  calculation,
  values,
  call = rlang::caller_env()
) {
  arguments <- calculation$arguments
  extra <- setdiff(names(values), names(arguments))
  required <- names(arguments)[vapply(arguments, `[[`, logical(1), "required")]
  missing <- setdiff(required, names(values))
  if (length(extra) || length(missing)) {
    cli::cli_abort(c(
      "Arguments do not match trusted calculation {.val {calculation$name}}.",
      "x" = if (length(extra)) "Unknown arguments: {.val {extra}}.",
      "x" = if (length(missing)) "Missing arguments: {.val {missing}}."
    ), call = call)
  }
  out <- list()
  for (name in names(arguments)) {
    argument <- arguments[[name]]
    value <- values[[name]]
    if (is.null(value)) {
      out[[name]] <- argument$default
      next
    }
    out[[name]] <- validate_catalog_calculation_value(
      value,
      argument,
      name,
      call
    )
  }
  out
}

validate_catalog_calculation_value <- function(value, argument, name, call) {
  if (length(value) != 1 || is.na(value)) {
    cli::cli_abort(
      "Calculation argument {.arg {name}} must be one non-missing value.",
      call = call
    )
  }
  valid <- switch(
    argument$type,
    string = is.character(value),
    integer = is.numeric(value) && is.finite(value) && value == as.integer(value),
    number = is.numeric(value) && is.finite(value),
    logical = is.logical(value),
    date = is.character(value) && grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", value) && !is.na(as.Date(value)),
    datetime = is.character(value) && grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ]", value)
  )
  if (!isTRUE(valid)) {
    cli::cli_abort(
      "Calculation argument {.arg {name}} must be a {.val {argument$type}} value.",
      call = call
    )
  }
  if (length(argument$choices) && !as.character(value) %in% argument$choices) {
    cli::cli_abort(
      c(
        "Calculation argument {.arg {name}} is not an allowed value.",
        "i" = "Allowed values: {.val {argument$choices}}."
      ),
      call = call
    )
  }
  value
}

prepare_catalog_calculation <- function(execution, arguments, values, con) {
  sql <- execution$sql
  if (is.null(sql) || !nzchar(sql)) {
    cli::cli_abort("The trusted calculation has no executable SQL.")
  }
  params <- list()
  for (binding in execution$bindings) {
    argument <- arguments[[binding$argument]]
    value <- values[[binding$argument]]
    if (identical(binding$method, "identifier")) {
      quoted <- as.character(DBI::dbQuoteIdentifier(con, as.character(value)))
      sql <- calculation_replace_token(sql, binding$token, quoted)
    } else {
      if (!is.null(binding$token)) {
        sql <- calculation_replace_token(sql, binding$token, "?")
      }
      params <- c(params, list(value))
    }
  }
  list(sql = sql, params = params)
}

calculation_replace_token <- function(sql, token, replacement) {
  count <- lengths(regmatches(sql, gregexpr(token, sql, fixed = TRUE)))
  if (count != 1) {
    cli::cli_abort(
      "A trusted calculation binding token must occur exactly once in its SQL."
    )
  }
  sub(token, replacement, sql, fixed = TRUE)
}

source_query_bind <- function(source, sql, params) {
  if (!is.null(source$provider)) catalog_provider_check(source$provider)
  if (length(params) == 0) {
    return(source_query(source, sql))
  }
  check_query(sql)
  result <- DBI::dbSendQuery(source$con, sql)
  on.exit(DBI::dbClearResult(result), add = TRUE)
  DBI::dbBind(result, params)
  DBI::dbFetch(result)
}
