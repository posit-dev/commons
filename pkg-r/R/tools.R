# Register only the tools the agent's composition earns; nothing about its
# surface should imply operations it doesn't have.
build_commons_tools <- function(self, private) {
  c(
    if (pool_searchable(
      private$registry,
      private$definitions,
      private$semantic_models,
      private$calculations
    )) {
      list(tool_search_pool(private))
    },
    if (length(private$registry) > 0) list(tool_call_measure(private)),
    if (
      registry_has_metrics(private$definitions) ||
        semantic_registry_has_metrics(private$semantic_models) ||
        sources_have_semantic_stubs(private$sources)
    ) {
      list(tool_call_metrics(private))
    },
    if (
      length(private$calculations) ||
        sources_have_semantic_stubs(
          private$sources,
          backend = "snowflake_semantic_view"
        )
    ) {
      list(tool_call_calculation(private))
    },
    if (any(vapply(private$sources, catalog_searchable, logical(1)))) {
      list(tool_search_catalog(private))
    },
    list(
      tool_search_context(private),
      tool_describe_table(private),
      tool_run_sql(private),
      tool_run_r(private)
    )
  )
}

tool_search_catalog <- function(private) {
  ellmer::tool(
    function(query, kinds = NULL, source = NULL) {
      src <- resolve_sql_source(private$sources, source)
      if (!catalog_searchable(src)) {
        return(tool_result(
          "This data source does not have a searchable catalog.",
          title = "Searched for a trusted calculation",
          icon = maybe_icon("search")
        ))
      }
      results <- catalog_search(src, query, kinds)
      body <- if (length(results)) {
        paste(vapply(names(results), function(label) {
          relation <- results[[label]]
          summary <- relation$description %||% "No description."
          kind <- relation$kind %||% "unknown kind"
          sprintf("- `%s` (%s): %s", label, kind, summary)
        }, character(1)), collapse = "\n")
      } else {
        sprintf("No catalog objects found for \"%s\".", query)
      }
      tool_result(
        body,
        title = "Searched for a trusted calculation",
        icon = maybe_icon("search"),
        markdown = body
      )
    },
    paste(
      "Search a broad selected catalog by object name and description.",
      "Results are stable object names for describe_table."
    ),
    arguments = list(
      query = ellmer::type_string("The data you need, in plain language."),
      kinds = ellmer::type_array(
        ellmer::type_string(),
        "Optional object kinds such as table or view.",
        required = FALSE
      ),
      source = sql_source_type(private$sources)
    ),
    name = "search_catalog",
    annotations = ellmer::tool_annotations(
      title = "Searching for a trusted calculation",
      icon = maybe_icon("search"),
      read_only_hint = TRUE
    )
  )
}

# Measures are never listed in the system prompt, and definitions past their
# ambient cap aren't either; a search tool over a fully visible pool would
# just cost the model a verification round trip.
pool_searchable <- function(
  measures,
  definitions,
  semantic_models = NULL,
  calculations = list()
) {
  has_semantic_models <- !is.null(semantic_models) &&
    nrow(registry_semantic_members(semantic_models)) > 0L
  has_semantic_stubs <- !is.null(semantic_models) &&
    nrow(registry_semantic_stubs(semantic_models)) > 0L
  length(measures) > 0 ||
    definitions_overflow(definitions) ||
    has_semantic_models ||
    has_semantic_stubs ||
    length(calculations) > 0L
}

tool_search_pool <- function(private) {
  has_semantic_stubs <- nrow(
    registry_semantic_stubs(private$semantic_models)
  ) > 0L
  source_names <- if (length(private$sources) > 1) {
    names(private$sources)
  } else {
    character()
  }
  kinds <- c(
    if (length(private$registry) > 0) "measures (run with call_measure)",
    if (nrow(registry_defs(private$definitions)) > 0) {
      "governed definitions (apply as {{name}} tokens in run_sql)"
    },
    if (nrow(registry_semantic_members(private$semantic_models)) > 0) {
      "native semantic-model metrics (run with call_metrics)"
    },
    if (nrow(registry_semantic_stubs(private$semantic_models)) > 0) {
      "semantic models (inspect with describe_table)"
    },
    if (length(private$calculations)) {
      "exact trusted queries (run with call_calculation)"
    }
  )
  ellmer::tool(
    function(query) {
      body <- search_pool_text(
        private$registry,
        private$definitions,
        query,
        source_names,
        semantic_models = private$semantic_models,
        calculations = private$calculations
      )
      display_body <- search_pool_text(
        private$registry,
        private$definitions,
        query,
        source_names,
        semantic_models = private$semantic_models,
        calculations = private$calculations,
        measure_titles = TRUE
      )
      tool_result(
        body,
        title = "Searched for a trusted calculation",
        icon = maybe_icon("search"),
        markdown = display_body
      )
    },
    sprintf(
      paste(
        if (has_semantic_stubs) {
          "Search the semantic layer's trusted calculations and models: %s."
        } else {
          "Search the semantic layer's trusted calculations: %s."
        },
        "For every data question, use this before any other data",
        "tool, even if a table looks easy to query directly. Use the exact",
        "names it returns."
      ),
      paste(kinds, collapse = " and ")
    ),
    arguments = list(
      query = ellmer::type_string(
        "What you want to compute, in plain language."
      )
    ),
    name = "search_pool",
    annotations = ellmer::tool_annotations(
      title = "Searching for a trusted calculation",
      icon = maybe_icon("search"),
      read_only_hint = TRUE
    )
  )
}

tool_call_metrics <- function(private) {
  ellmer::tool(
    function(
      metrics,
      dimensions = NULL,
      filters = NULL,
      where = NULL,
      arguments = "{}",
      source = NULL
    ) {
      call_metrics_impl(
        private$definitions,
        private$sources,
        private$handles,
        metrics = metrics,
        dimensions = dimensions,
        filters = filters,
        where = where,
        source_name = source,
        arguments = arguments
      )
    },
    sprintf(
      paste(
        "Compute trusted calculations from governed metrics, optionally",
        "grouped and filtered. Metric, grouping, and filter names come from",
        "%s; commons compiles and runs the query."
      ),
      if (pool_searchable(
        private$registry,
        private$definitions,
        private$semantic_models,
        private$calculations
      )) {
        if (nrow(registry_semantic_stubs(private$semantic_models))) {
          "the system prompt, search_pool, or describe_table"
        } else {
          "the system prompt or search_pool"
        }
      } else {
        "the system prompt"
      }
    ),
    arguments = list(
      metrics = ellmer::type_array(
        ellmer::type_string(),
        "Metric names to compute. All metrics in one call must belong to the same table or native semantic model."
      ),
      dimensions = ellmer::type_array(
        ellmer::type_string(),
        "Derived or filter definition names, documented column names, or native semantic dimensions to group by.",
        required = FALSE
      ),
      filters = ellmer::type_array(
        ellmer::type_string(),
        "Governed filter names to apply.",
        required = FALSE
      ),
      where = ellmer::type_array(
        ellmer::type_object(
          column = ellmer::type_string(
            "A documented column or native semantic dimension name."
          ),
          op = ellmer::type_enum(
            c("=", "!=", "<", "<=", ">", ">="),
            "Comparison operator."
          ),
          value = ellmer::type_string(
            "The comparison value; numbers and dates as plain strings."
          )
        ),
        "Simple column predicates, e.g. a date range.",
        required = FALSE
      ),
      arguments = ellmer::type_string(
        "A JSON object of native semantic-model parameter values.",
        required = FALSE
      ),
      source = sql_source_type(private$sources)
    ),
    name = "call_metrics",
    annotations = ellmer::tool_annotations(
      title = "Running a trusted calculation",
      icon = maybe_icon("shield-check"),
      read_only_hint = TRUE
    )
  )
}

tool_call_calculation <- function(private) {
  ellmer::tool(
    function(name, arguments = "{}", source = NULL) {
      call_calculation_impl(
        private$sources,
        private$handles,
        name,
        arguments,
        source_name = source
      )
    },
    paste(
      paste(
        "Run an exact trusted query returned by search_pool or",
        "describe_table."
      ),
      "Arguments are validated and bound; identifier arguments accept only",
      "the values listed by search_pool or describe_table."
    ),
    arguments = list(
      name = ellmer::type_string(
        "The calculation name, exactly as returned by search_pool."
      ),
      arguments = ellmer::type_string(
        "A JSON object of the calculation's arguments."
      ),
      source = sql_source_type(private$sources)
    ),
    name = "call_calculation",
    annotations = ellmer::tool_annotations(
      title = "Running a trusted calculation",
      icon = maybe_icon("shield-check"),
      read_only_hint = TRUE
    )
  )
}

tool_call_measure <- function(private) {
  ellmer::tool(
    function(name, arguments = "{}") {
      call_measure_tool(
        private$registry,
        name,
        arguments,
        injections = private$injections,
        handles = private$handles,
        sources = private$sources,
        measure_provenance = private$measure_provenance
      )
    },
    paste(
      "Run trusted calculations returned by",
      "search_pool. `arguments` is a JSON object using exactly the argument",
      "names from search_pool. Prefer a measure's own arguments when they can",
      "answer the question directly. Measure results may be displayed directly",
      "to the user. If a result says it is already visible, do not reproduce",
      "it in your reply; summarize or interpret the relevant results instead."
    ),
    arguments = list(
      name = ellmer::type_string(
        "The measure name, exactly as returned by search_pool."
      ),
      arguments = ellmer::type_string(
        "A JSON object of the measure's arguments."
      )
    ),
    name = "call_measure",
    annotations = ellmer::tool_annotations(
      title = "Running a trusted calculation",
      icon = maybe_icon("shield-check"),
      read_only_hint = TRUE
    )
  )
}

tool_search_context <- function(private) {
  ellmer::tool(
    function(query) {
      result <- search_context_tool(private$context_layer, query)
      if (!S7::S7_inherits(result, ellmer::ContentToolResult)) {
        return(tool_result(
          result,
          title = "Searched context",
          icon = maybe_icon("book"),
          markdown = result
        ))
      }
      add_citation_request(result, private$citation_request)
    },
    "Search context for metric definitions, data notes, and table relationships.",
    arguments = list(
      query = ellmer::type_string(
        "What you need context about, in plain language."
      )
    ),
    name = "search_context",
    annotations = ellmer::tool_annotations(
      title = "Searching context",
      icon = maybe_icon("book"),
      read_only_hint = TRUE
    )
  )
}

tool_describe_table <- function(private) {
  has_semantic_models <- sources_have_semantic_models(private$sources) ||
    sources_have_semantic_stubs(private$sources)
  ellmer::tool(
    function(table, source = NULL) {
      describe_table_tool(
        resolve_sql_source(private$sources, source),
        table,
        source_name = source,
        tracker = private$first_touch
      )
    },
    if (has_semantic_models) {
      paste(
        "Describe a catalog object.",
        "For tables, return columns, types, and sample rows.",
        "For semantic models, return public members and any verified queries."
      )
    } else {
      paste(
        "Describe a table: columns, types, and sample rows.",
        "Use this before writing SQL against an unfamiliar table."
      )
    },
    arguments = list(
      table = ellmer::type_string(
        if (has_semantic_models) {
          "The object name, as listed in the system prompt or search results."
        } else {
          "The table name, as listed in the system prompt."
        }
      ),
      source = sql_source_type(private$sources)
    ),
    name = "describe_table",
    annotations = ellmer::tool_annotations(
      title = "Inspecting a table",
      icon = maybe_icon("table"),
      read_only_hint = TRUE
    )
  )
}

tool_run_sql <- function(private) {
  ellmer::tool(
    function(sql, source = NULL) {
      src <- resolve_sql_source(private$sources, source)
      expansion <- expand_for_run_sql(
        private$definitions,
        private$sources,
        source,
        sql
      )
      res <- run_sql_tool(
        src,
        expansion$sql,
        source_name = source,
        tracker = private$first_touch,
        handles = private$handles,
        applied = expansion$applied
      )
      add_citation_request(res, private$citation_request)
    },
    run_sql_description(private$definitions, private$registry),
    arguments = list(
      sql = ellmer::type_string(
        "A read-only SELECT query, in the data source's SQL dialect."
      ),
      source = sql_source_type(private$sources)
    ),
    name = "run_sql",
    annotations = ellmer::tool_annotations(
      title = "Retrieving data",
      icon = maybe_icon("code-square"),
      read_only_hint = TRUE
    )
  )
}

run_sql_description <- function(definitions, measures = list()) {
  parts <- c(
    "Run a read-only SELECT query against a data source.",
    if (length(measures) > 0) {
      "Use this when no registered measure answers the question."
    },
    if (!is.null(definitions) && nrow(registry_defs(definitions)) > 0) {
      paste0(
        "Governed definitions can be written as {{name}} tokens anywhere ",
        "in the SQL (or {{table::name}} when qualification is needed); ",
        "each expands to its compiled SQL before the query runs."
      )
    }
  )
  paste(parts, collapse = " ")
}

# With one source there's nothing to choose, so the model never sees the
# `source` argument (type_ignore keeps it out of the schema).
sql_source_type <- function(sources) {
  if (length(sources) == 1) {
    return(ellmer::type_ignore())
  }
  ellmer::type_enum(
    values = names(sources),
    description = "The data source to use, as listed in the system prompt."
  )
}

call_measure_tool <- function(
  registry,
  name,
  arguments,
  injections = list(),
  handles = NULL,
  sources = list(),
  measure_provenance = list()
) {
  td <- registry[[name]]
  if (is.null(td)) {
    detail <- if (length(registry)) {
      cli::format_inline("Registered measures: {.val {names(registry)}}.")
    } else {
      "No measures are registered."
    }
    cli::cli_abort(c("No measure named {.val {name}}.", i = detail))
  }
  footer <- measure_source_footer(
    measure_provenance[[name]] %||% character()
  )
  args <- validate_measure_args(td, parse_json_args(arguments))
  # A measure takes a source's connection by the source's name; a board source
  # must have its pins loaded before that connection can answer a query.
  for (source_name in names(injections[[name]])) {
    source_ensure_all(sources[[source_name]])
  }
  value <- do.call(td, c(args, injections[[name]]))
  if (S7::S7_inherits(value, ellmer::ContentToolResult)) {
    return(measure_content_tool_result(td, value, handles, footer))
  }
  value <- collect_lazy_table(value)
  if (is_ggplot(value)) {
    advert <- register_handle(handles, value)
    return(measure_plot_tool_result(td, args, value, advert, footer))
  }
  if (is_gt_table(value)) {
    data <- recover_gt_table_data(value)
    advert <- register_handle(handles, data)
    return(measure_gt_table_tool_result(
      td,
      args,
      value,
      data,
      advert,
      footer
    ))
  }
  advert <- register_handle(handles, value)
  tool_result(
    paste(c(format_measure_value(value), advert), collapse = "\n\n"),
    title = "Ran a trusted calculation",
    icon = maybe_icon("shield-check"),
    html = measure_display_html(args, value, measure_metadata(td)),
    footer = footer,
    tag = "A",
    show_tag = FALSE
  )
}

measure_content_tool_result <- function(td, result, handles, footer) {
  data <- result@extra$data
  result@extra$data <- NULL
  display <- result@extra$display

  if (is.null(result@error)) {
    data <- collect_lazy_table(data)
    advert <- register_handle(handles, data)
    result@value <- append_handle_advert(result@value, advert)
    if (measure_result_is_visible(display)) {
      result@value <- prepend_model_note(
        result@value,
        visible_result_note("measure result")
      )
    }
  }

  title <- "Ran a trusted calculation"
  icon <- maybe_icon("shield-check")
  if (is.null(display)) {
    display <- shinychat::tool_result_display(
      title = title,
      icon = icon,
      footer = footer
    )
  } else if (is.list(display)) {
    display$title <- display$title %||% title
    display$icon <- display$icon %||% icon
    display$footer <- display$footer %||% footer
  }
  result@extra$display <- display
  result@extra$commons_tag <- "A"
  result
}

measure_result_is_visible <- function(display) {
  is.list(display) && any(vapply(
    display[c("html", "markdown", "text")],
    Negate(is.null),
    logical(1)
  ))
}

prepend_model_note <- function(value, note) {
  note <- ellmer::ContentText(note)
  if (S7::S7_inherits(value, ellmer::Content)) {
    return(list(note, value))
  }
  if (
    is.list(value) &&
      length(value) > 0 &&
      all(vapply(value, S7::S7_inherits, logical(1), ellmer::Content))
  ) {
    return(c(list(note), value))
  }
  paste(c(note@text, format_measure_value(value)), collapse = "\n\n")
}

append_handle_advert <- function(value, advert) {
  if (is.null(advert)) {
    return(value)
  }
  note <- ellmer::ContentText(advert)
  if (S7::S7_inherits(value, ellmer::Content)) {
    return(list(value, note))
  }
  if (
    is.list(value) &&
      length(value) > 0 &&
      all(vapply(value, S7::S7_inherits, logical(1), ellmer::Content))
  ) {
    return(c(value, list(note)))
  }
  paste(c(format_measure_value(value), advert), collapse = "\n\n")
}

measure_plot_tool_result <- function(td, args, value, advert, footer) {
  title <- tool_title(td)
  rendered <- tryCatch(
    render_plot_image(value, sprintf("Plot returned by %s", title)),
    error = function(error) error
  )
  if (inherits(rendered, "error")) {
    return(measure_failure_result(
      td,
      args,
      advert,
      conditionMessage(rendered),
      "a plot",
      "commons-measure-plot-error",
      footer = footer
    ))
  }

  model_value <- list(
    ellmer::ContentText(visible_result_note("plot")),
    rendered$model
  )
  if (!is.null(advert)) {
    model_value[[length(model_value) + 1L]] <- ellmer::ContentText(advert)
  }
  tool_result(
    model_value,
    title = "Ran a trusted calculation",
    icon = maybe_icon("shield-check"),
    html = measure_display_with_result_html(
      args,
      measure_result_html(rendered$html),
      measure_metadata(td)
    ),
    footer = footer,
    tag = "A",
    open = TRUE,
    show_tag = FALSE
  )
}

measure_failure_result <- function(
  td,
  args,
  advert,
  message,
  result_type,
  class,
  footer,
  model_content = NULL
) {
  note <- sprintf(
    "The measure returned %s, but it could not be displayed: %s",
    result_type,
    message
  )
  tool_result(
    paste(c(model_content, note, advert), collapse = "\n\n"),
    title = "Ran a trusted calculation",
    icon = maybe_icon("shield-check"),
    html = measure_display_with_result_html(
      args,
      measure_result_html(html_escape(note), class),
      measure_metadata(td)
    ),
    footer = footer,
    tag = "A",
    open = TRUE,
    show_tag = FALSE
  )
}

measure_gt_table_tool_result <- function(
  td,
  args,
  value,
  data,
  advert,
  footer
) {
  rendered <- tryCatch(
    render_gt_table(value),
    error = function(error) error
  )
  model_content <- df_to_markdown(data)
  if (inherits(rendered, "error")) {
    return(measure_failure_result(
      td,
      args,
      advert,
      conditionMessage(rendered),
      "a gt table",
      "commons-measure-gt-table-error",
      footer = footer,
      model_content = model_content
    ))
  }
  model_note <- c(
    visible_result_note("gt table"),
    if (!is.null(advert)) {
      paste(
        "For calculations, use `run_r` with the table handle below instead of",
        "parsing values from the rendered table."
      )
    }
  )
  model_note <- paste(model_note, collapse = " ")
  display_html <- measure_display_with_result_html(
    args,
    measure_result_html(rendered$html, "commons-measure-gt-table"),
    measure_metadata(td)
  )
  if (length(rendered$dependencies) > 0) {
    display_html <- htmltools::attachDependencies(
      htmltools::HTML(display_html),
      rendered$dependencies,
      append = TRUE
    )
  }
  tool_result(
    paste(
      c(model_note, model_content, advert),
      collapse = "\n\n"
    ),
    title = "Ran a trusted calculation",
    icon = maybe_icon("shield-check"),
    html = display_html,
    footer = footer,
    tag = "A",
    open = TRUE,
    show_tag = FALSE
  )
}

search_context_tool <- function(context, query) {
  if (is.null(context)) {
    return("No context layer is configured for this agent.")
  }
  hits <- context_search(context, query)
  body <- if (length(hits)) {
    paste(hits, collapse = "\n\n---\n\n")
  } else {
    sprintf("No context found for \"%s\".", query)
  }
  tool_result(
    body,
    title = "Searched context",
    icon = maybe_icon("book"),
    markdown = body
  )
}

describe_table_tool <- function(
  source,
  table,
  source_name = NULL,
  tracker = NULL
) {
  source_state <- data_source_state(source)
  d <- source_describe(source, table)
  if (inherits(d, "commons_semantic_model_description")) {
    body <- semantic_model_description_text(d)
    return(tool_result(
      body,
      title = "Inspected a table",
      icon = maybe_icon("table"),
      markdown = body
    ))
  }
  entry <- source_state$dictionary$tables[[table]]
  context <- if (!table_touched(tracker, source_name, table)) {
    semantic_model_first_touch(source, table)
  } else {
    character()
  }
  relation <- c(
    if (!is.null(d$kind)) sprintf("Relation type: %s.", d$kind),
    if (is.null(entry)) d$description
  )

  sample <- sprintf(
    "Sample summary:\n\n%s",
    ellmer::df_schema(d$sample, max_cols = ncol(d$sample))
  )
  if (is.null(entry)) {
    parts <- c(
      relation,
      sprintf("Columns of `%s`:\n\n%s", table, df_to_markdown(d$schema)),
      context,
      sample
    )
  } else {
    columns <- sprintf(
      "Columns of `%s`:\n\n%s",
      table,
      dictionary_columns_text(entry$columns, live = d$schema)
    )
    parts <- c(
      relation,
      dictionary_entry_parts(source_state$dictionary, table, columns),
      context,
      sample
    )
  }
  mark_table_touched(tracker, source_name, table)

  body <- paste(parts, collapse = "\n\n")
  tool_result(
    body,
    title = "Inspected a table",
    icon = maybe_icon("table"),
    markdown = body
  )
}

run_sql_tool <- function(
  source,
  sql,
  source_name = NULL,
  tracker = NULL,
  handles = NULL,
  applied = NULL
) {
  res <- source_query(source, sql)
  body <- df_to_markdown(res)
  display_md <- sprintf("```sql\n%s\n```\n\n%s", sql, body)
  advert <- register_handle(handles, res)
  note <- applied_definitions_text(applied)
  entries <- dictionary_sql_entries(source, sql, source_name, tracker)
  tool_result(
    paste(c(body, note, advert, entries), collapse = "\n\n"),
    title = "Retrieved data",
    icon = maybe_icon("code-square"),
    markdown = display_md,
    tag = "B",
    open = FALSE,
    show_tag = FALSE
  )
}

# Dictionary entries for tables this query touches that the conversation
# hasn't seen yet, via either tool. Matching is by table name in the SQL
# text, which is reliable in a way column matching is not; a false positive
# appends a harmless note.
dictionary_sql_entries <- function(source, sql, source_name, tracker) {
  source_state <- data_source_state(source)
  dictionary <- source_state$dictionary
  tables <- source_state$tables %||% names(dictionary$tables)
  hits <- tables[vapply(
    tables,
    source_table_mentioned,
    logical(1),
    source = source,
    dictionary = dictionary,
    text = sql
  )]
  hits <- hits[
    !vapply(
      hits,
      function(table) table_touched(tracker, source_name, table),
      logical(1)
    )
  ]
  if (length(hits) == 0) {
    return(NULL)
  }

  entries <- vapply(
    hits,
    source_first_touch_text,
    character(1),
    source = source,
    dictionary = dictionary
  )
  keep <- nzchar(entries)
  hits <- hits[keep]
  entries <- entries[keep]
  if (length(hits) == 0L) {
    return(NULL)
  }
  for (table in hits) {
    mark_table_touched(tracker, source_name, table)
  }
  unname(entries)
}

source_first_touch_text <- function(table, source, dictionary) {
  paste(
    c(
      if (!is.null(dictionary$tables[[table]])) {
        dictionary_entry_text(dictionary, table)
      },
      semantic_model_first_touch(source, table)
    ),
    collapse = "\n\n"
  )
}

source_table_mentioned <- function(table, source, dictionary, text) {
  if (
    !is.null(dictionary$tables[[table]]) &&
      dictionary_table_mentioned(table, dictionary, text)
  ) {
    return(TRUE)
  }
  source_state <- data_source_state(source)
  id <- source_state$table_ids[[table]]
  candidates <- unique(c(table, id@name[["table"]]))
  any(vapply(
    candidates,
    function(candidate) grepl(word_pattern(candidate), text, ignore.case = TRUE),
    logical(1)
  ))
}

# Which tables' dictionary entries this conversation has already seen, so
# run_sql doesn't re-deliver them. A NULL tracker (tools used outside an
# agent) treats every touch as the first.
table_touched <- function(tracker, source_name, table) {
  !is.null(tracker) && isTRUE(tracker[[touch_key(source_name, table)]])
}

mark_table_touched <- function(tracker, source_name, table) {
  if (!is.null(tracker)) {
    tracker[[touch_key(source_name, table)]] <- TRUE
  }
  invisible(NULL)
}

touch_key <- function(source_name, table) {
  paste(source_name %||% "", table, sep = "\n")
}

tool_result <- function(
  value,
  title,
  icon = NULL,
  html = NULL,
  markdown = NULL,
  footer = NULL,
  tag = NULL,
  open = FALSE,
  show_request = FALSE,
  show_tag = TRUE
) {
  if (!is.null(tag) && isTRUE(show_tag)) {
    title <- sprintf("%s \u00b7 %s", title, tag_label(tag))
  }
  display <- shinychat::tool_result_display(
    title = title,
    icon = icon,
    html = html,
    markdown = markdown,
    show_request = show_request,
    open = open,
    footer = footer
  )

  ellmer::ContentToolResult(
    value = value,
    extra = list(display = display, commons_tag = tag)
  )
}

visible_result_note <- function(type) {
  paste(
    sprintf("This %s is already visible to the user.", type),
    "**Do not recreate or repeat it**."
  )
}

tag_label <- function(tag) {
  switch(tag, A = "Registered measure (A)", B = "SQL query (B)", tag)
}

parse_json_args <- function(x) {
  if (is.null(x) || identical(x, "") || identical(x, "{}")) {
    return(list())
  }
  if (is.list(x)) {
    return(x)
  }
  as.list(jsonlite::fromJSON(x, simplifyVector = TRUE))
}

collect_lazy_table <- function(value) {
  if (inherits(value, "tbl_sql")) {
    rlang::check_installed("dplyr")
    value <- dplyr::collect(value)
  }
  value
}

format_measure_value <- function(value) {
  value <- collect_lazy_table(value)
  if (is.data.frame(value)) {
    return(df_to_markdown(value))
  }
  if (is.atomic(value) && length(value) <= 20) {
    return(paste(format(value, trim = TRUE), collapse = ", "))
  }
  paste(utils::capture.output(print(value)), collapse = "\n")
}

measure_args_html <- function(args) {
  if (length(args) == 0) {
    return("")
  }
  rows <- paste(
    vapply(
      names(args),
      function(nm) {
        sprintf(
          "<div class=\"commons-measure-arg\"><span class=\"commons-measure-arg-name\">%s:</span> <span class=\"commons-measure-arg-value\">%s</span></div>",
          html_escape(label_name(nm)),
          html_escape(format_arg_value(args[[nm]]))
        )
      },
      character(1)
    ),
    collapse = "\n"
  )

  sprintf("<div class=\"commons-measure-args\">%s</div>", rows)
}

measure_display_html <- function(args, value, metadata = NULL) {
  measure_display_with_result_html(
    args,
    measure_result_html(format_measure_html(value)),
    metadata
  )
}

measure_display_with_result_html <- function(
  args,
  result_html,
  metadata = NULL
) {
  sprintf(
    "<div class=\"commons-measure-display\">%s%s%s</div>",
    measure_metadata_html(metadata),
    measure_args_html(args),
    result_html
  )
}

measure_metadata <- function(td) {
  data.frame(
    title = tool_title(td),
    description = tool_description(td),
    stringsAsFactors = FALSE
  )
}

measure_metadata_html <- function(metadata) {
  if (is.null(metadata) || nrow(metadata) == 0L) {
    return("")
  }
  items <- vapply(
    seq_len(nrow(metadata)),
    function(i) {
      description <- metadata$description[[i]]
      description <- if (is.na(description) || !nzchar(description)) {
        ""
      } else {
        sprintf(
          "<div class=\"commons-measure-description\">%s</div>",
          html_escape(description)
        )
      }
      sprintf(
        paste0(
          "<div class=\"commons-measure-metadata-item\">",
          "<strong class=\"commons-measure-title\">%s</strong>%s</div>"
        ),
        html_escape(metadata$title[[i]]),
        description
      )
    },
    character(1)
  )
  sprintf(
    "<div class=\"commons-measure-metadata\">%s</div>",
    paste(items, collapse = "\n")
  )
}

measure_source_footer <- function(provenance) {
  urls <- unique(provenance[grepl("^https?://", provenance, ignore.case = TRUE)])
  if (length(urls) == 0L) {
    return(NULL)
  }
  htmltools::tagList(lapply(seq_along(urls), function(i) {
    htmltools::tags$a(
      class = "commons-measure-source-link",
      href = urls[[i]],
      target = "_blank",
      rel = "noopener noreferrer",
      if (length(urls) == 1L) "View source" else sprintf("Source %d", i)
    )
  }))
}

measure_result_html <- function(content, class = NULL) {
  class <- if (is.null(class)) "" else paste0(" ", class)
  sprintf(
    paste0(
      "<div class=\"commons-measure-result\"><strong>Result</strong>",
      "<div class=\"commons-measure-result-value%s\">%s</div></div>"
    ),
    class,
    content
  )
}

# Render a measure result for display: data frames become HTML tables; other
# values reuse the text formatting, escaped for HTML.
format_measure_html <- function(value) {
  value <- collect_lazy_table(value)
  if (is.data.frame(value)) {
    return(df_to_html(value))
  }
  html_escape(format_measure_value(value))
}

label_name <- function(x) {
  x <- humanize_name(x)
  paste0(toupper(substr(x, 1, 1)), substr(x, 2, nchar(x)))
}

format_arg_value <- function(x) {
  if (is.null(x)) {
    return("")
  }
  if (is.atomic(x)) {
    return(paste(vapply(x, format_arg_scalar, character(1)), collapse = ", "))
  }
  jsonlite::toJSON(x, auto_unbox = TRUE)
}

format_arg_scalar <- function(x) {
  if (is.na(x)) {
    return("NA")
  }
  if (is.numeric(x)) {
    return(format_number(x))
  }
  if (is.logical(x)) {
    return(tolower(as.character(x)))
  }
  as.character(x)
}

format_number <- function(x) {
  if (isTRUE(all.equal(x, round(x)))) {
    return(formatC(x, format = "f", digits = 0, big.mark = ","))
  }
  prettyNum(
    format(x, scientific = FALSE, trim = TRUE),
    big.mark = ",",
    preserve.width = "none"
  )
}

html_escape <- function(x) {
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;", x, fixed = TRUE)
  x <- gsub(">", "&gt;", x, fixed = TRUE)
  x <- gsub("\"", "&quot;", x, fixed = TRUE)
  x <- gsub("'", "&#39;", x, fixed = TRUE)
  x
}
