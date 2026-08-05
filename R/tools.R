# Register only the tools the agent's composition earns; nothing about its
# surface should imply operations it doesn't have.
build_commons_tools <- function(self, private) {
  native_semantics <- catalog_semantics_possible(private$sources)
  c(
    if (pool_searchable(
      private$registry,
      private$definitions,
      private$calculations
    ) || native_semantics) {
      list(tool_search_pool(private))
    },
    if (length(private$registry) > 0) list(tool_call_measure(private)),
    if (length(private$calculations) > 0 || native_semantics) {
      list(tool_call_calculation(private))
    },
    if (registry_has_metrics(private$definitions) || native_semantics) {
      list(tool_call_metrics(private))
    },
    if (any(vapply(
      private$sources,
      catalog_provider_searchable,
      logical(1)
    ))) {
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

catalog_semantics_possible <- function(sources) {
  any(vapply(sources, function(source) {
    !is.null(source$provider) &&
      isTRUE(source$provider$capabilities$native_semantics)
  }, logical(1)))
}

tool_search_catalog <- function(private) {
  ellmer::tool(
    function(query, kinds = NULL, source = NULL) {
      src <- resolve_sql_source(private$sources, source)
      if (is.null(src$provider)) {
        return("This data source does not have a searchable catalog.")
      }
      results <- catalog_provider_search(src$provider, query, kinds)
      body <- if (length(results)) {
        paste(vapply(results, function(relation) {
          label <- src$relation_labels[[relation$id]] %||% relation$name
          summary <- relation$description %||% relation$label %||% "No description."
          sprintf("- `%s` (%s): %s", label, relation$kind, summary)
        }, character(1)), collapse = "\n")
      } else {
        sprintf("No catalog objects found for \"%s\".", query)
      }
      tool_result(
        body,
        title = "Searched the data catalog",
        icon = maybe_icon("search"),
        markdown = body
      )
    },
    "Search the selected data catalog by business meaning, object name, tags, and synonyms. Results are stable object names for describe_table.",
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
      title = "Search the data catalog",
      icon = maybe_icon("search"),
      read_only_hint = TRUE
    )
  )
}

# Measures are never listed in the system prompt, and definitions past their
# ambient cap aren't either; a search tool over a fully visible pool would
# just cost the model a verification round trip.
pool_searchable <- function(measures, definitions, calculations = list()) {
  length(measures) > 0 || length(calculations) > 0 ||
    definitions_overflow(definitions)
}

tool_search_pool <- function(private) {
  source_names <- if (length(private$sources) > 1) {
    names(private$sources)
  } else {
    character()
  }
  kinds <- c(
    if (length(private$registry) > 0) "measures (run with call_measure)",
    if (length(private$calculations) > 0) {
      "trusted warehouse calculations (run with call_calculation)"
    },
    if (nrow(registry_defs(private$definitions)) > 0) {
      "governed definitions (apply as {{name}} tokens in run_sql, or through call_metrics)"
    },
    if (catalog_semantics_possible(private$sources)) {
      "native semantics discovered by describe_table"
    }
  )
  ellmer::tool(
    function(query) {
      definitions <- definitions_registry(private$sources)
      calculations <- catalog_calculations_registry(private$sources)
      body <- search_pool_text(
        private$registry,
        definitions,
        query,
        source_names,
        calculations
      )
      tool_result(
        body,
        title = "Found a trusted calculation",
        icon = maybe_icon("search")
      )
    },
    sprintf(
      "Search the semantic layer's governed operations: %s. Use this before writing your own SQL.",
      paste(kinds, collapse = " and ")
    ),
    arguments = list(
      query = ellmer::type_string(
        "What you want to compute, in plain language."
      )
    ),
    name = "search_pool",
    annotations = ellmer::tool_annotations(
      title = "Find a trusted calculation",
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
      definitions <- definitions_registry(private$sources)
      call_metrics_impl(
        definitions,
        private$sources,
        private$handles,
        metrics = metrics,
        dimensions = dimensions,
        filters = filters,
        where = where,
        arguments = arguments,
        source_name = source
      )
    },
    sprintf(
      "Compute governed metrics, optionally grouped and filtered. Metric, dimension, and filter names come from %s; commons compiles and runs the query.",
      if (pool_searchable(
        private$registry,
        private$definitions,
        private$calculations
      )) {
        "the system prompt or search_pool"
      } else {
        "the system prompt"
      }
    ),
    arguments = list(
      metrics = ellmer::type_array(
        ellmer::type_string(),
        "Metric names to compute. All metrics in one call must belong to the same table."
      ),
      dimensions = ellmer::type_array(
        ellmer::type_string(),
        "Dimension or documented column names to group by.",
        required = FALSE
      ),
      filters = ellmer::type_array(
        ellmer::type_string(),
        "Governed filter names to apply.",
        required = FALSE
      ),
      where = ellmer::type_array(
        ellmer::type_object(
          column = ellmer::type_string("A documented column name."),
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
      title = "Run a trusted calculation",
      icon = maybe_icon("shield-check"),
      read_only_hint = TRUE
    )
  )
}

tool_call_calculation <- function(private) {
  ellmer::tool(
    function(name, arguments = "{}", source = NULL) {
      call_catalog_calculation(
        catalog_calculations_registry(private$sources),
        name,
        arguments,
        source,
        private$handles
      )
    },
    "Run an exact trusted warehouse calculation returned by search_pool. Arguments are typed and bound without SQL interpolation.",
    arguments = list(
      name = ellmer::type_string(
        "The calculation name, exactly as returned by search_pool."
      ),
      arguments = ellmer::type_string(
        "A JSON object using exactly the calculation's argument names."
      ),
      source = sql_source_type(private$sources)
    ),
    name = "call_calculation",
    annotations = ellmer::tool_annotations(
      title = "Run a trusted calculation",
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
        sources = private$sources
      )
    },
    "Run a registered measure returned by search_pool. `arguments` is a JSON object using exactly the argument names from search_pool.",
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
      title = "Run a trusted calculation",
      icon = maybe_icon("shield-check"),
      read_only_hint = TRUE
    )
  )
}

tool_search_context <- function(private) {
  ellmer::tool(
    function(query, source = NULL) {
      search_context_tool(private$context_layer, query, source)
    },
    "Search context for metric definitions, data notes, and table relationships.",
    arguments = list(
      query = ellmer::type_string(
        "What you need context about, in plain language."
      ),
      source = sql_source_type(private$sources)
    ),
    name = "search_context",
    annotations = ellmer::tool_annotations(
      title = "Search context",
      icon = maybe_icon("book"),
      read_only_hint = TRUE
    )
  )
}

tool_describe_table <- function(private) {
  ellmer::tool(
    function(table, source = NULL) {
      result <- describe_table_tool(
        resolve_sql_source(private$sources, source),
        table,
        source_name = source,
        tracker = private$first_touch
      )
      catalog_runtime_refresh(private)
      result
    },
    "Describe a table: columns, types, and sample rows. Use this before writing SQL against an unfamiliar table.",
    arguments = list(
      table = ellmer::type_string(
        "The table name, as listed in the system prompt."
      ),
      source = sql_source_type(private$sources)
    ),
    name = "describe_table",
    annotations = ellmer::tool_annotations(
      title = "Inspect a table",
      icon = maybe_icon("table"),
      read_only_hint = TRUE
    )
  )
}

tool_run_sql <- function(private) {
  ellmer::tool(
    function(sql, source = NULL) {
      src <- resolve_sql_source(private$sources, source)
      definitions <- definitions_registry(private$sources)
      expansion <- expand_for_run_sql(
        definitions,
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
      sql = ellmer::type_string("A read-only SELECT query, in the data source's SQL dialect."),
      source = sql_source_type(private$sources)
    ),
    name = "run_sql",
    annotations = ellmer::tool_annotations(
      title = "Grab data",
      icon = maybe_icon("code-square"),
      read_only_hint = TRUE
    )
  )
}

catalog_runtime_refresh <- function(private) {
  private$definitions <- definitions_registry(private$sources)
  private$calculations <- catalog_calculations_registry(private$sources)
  private$context_layer <- augment_context_layer(
    private$context_layer,
    private$sources
  )
  private$corpus <- build_citation_corpus(
    private$context_layer,
    private$registry,
    private$sources
  )
  if (!is.null(private$citation_request)) {
    private$citation_request$request <- citation_request_text(
      private$registry,
      private$definitions
    )
  }
  invisible(private)
}

run_sql_description <- function(definitions, measures = list()) {
  parts <- c(
    "Run a read-only SELECT query against a data source.",
    if (length(measures) > 0) {
      "Use this when no registered measure answers the question."
    },
    if (!is.null(definitions) && any(
      registry_defs(definitions)$execution == "data_dictionary"
    )) {
      paste0(
        "Governed definitions can be written as {{name}} tokens anywhere ",
        "in the SQL; each expands to its trusted expression before the ",
        "query runs."
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
  sources = list()
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
  args <- validate_measure_args(td, parse_json_args(arguments))
  # A measure takes a source's connection by the source's name; a board source
  # must have its pins loaded before that connection can answer a query.
  for (source_name in names(injections[[name]])) {
    source_ensure_all(sources[[source_name]])
  }
  value <- do.call(td, c(args, injections[[name]]))
  value <- collect_lazy_table(value)
  advert <- register_handle(handles, value)
  tool_result(
    paste(c(format_measure_value(value), advert), collapse = "\n\n"),
    title = sprintf("Ran a trusted calculation: %s", html_escape(tool_title(td))),
    icon = maybe_icon("shield-check"),
    html = measure_display_html(args, value),
    tag = "A",
    show_tag = FALSE
  )
}

search_context_tool <- function(context, query, source = NULL) {
  if (is.null(context)) {
    return("No context layer is configured for this agent.")
  }
  hits <- context_search(context, query, source = source)
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

describe_table_tool <- function(source, table, source_name = NULL, tracker = NULL) {
  d <- source_describe(source, table)
  dictionary <- source_runtime_dictionary(source)
  entry <- dictionary$tables[[table]] %||% NULL
  context <- if (!table_touched(tracker, source_name, table)) {
    catalog_first_touch_text(source, table)
  } else {
    character()
  }

  sample <- if (nrow(d$sample)) {
    sprintf(
      "Sample rows:\n\n%s",
      df_to_markdown(d$sample, max_rows = 5)
    )
  }
  if (is.null(entry)) {
    parts <- c(
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
      dictionary_entry_parts(dictionary, table, columns),
      context,
      sample
    )
  }
  mark_table_touched(tracker, source_name, table)

  body <- paste(parts, collapse = "\n\n")
  tool_result(
    body,
    title = sprintf("Inspected %s%s", table, source_label(source_name)),
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
    title = sprintf("Grabbed data%s", source_label(source_name)),
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
  dictionary <- source_runtime_dictionary(source)
  tables <- source_tables(source)
  hits <- tables[vapply(
    tables,
    function(table) grepl(word_pattern(table), sql, ignore.case = TRUE),
    logical(1)
  )]
  hits <- hits[!vapply(
    hits,
    function(table) table_touched(tracker, source_name, table),
    logical(1)
  )]
  if (length(hits) == 0) {
    return(NULL)
  }

  for (table in hits) {
    mark_table_touched(tracker, source_name, table)
  }
  unname(vapply(
    hits,
    function(table) paste(
      c(
        if (!is.null(dictionary$tables[[table]])) {
          dictionary_entry_text(dictionary, table)
        },
        catalog_first_touch_text(source, table)
      ),
      collapse = "\n\n"
    ),
    character(1)
  ))
}

catalog_first_touch_text <- function(source, table) {
  catalog <- source$provider$catalog %||% source$catalog
  if (!inherits(catalog, "commons_catalog")) {
    return(character())
  }
  labels <- source_relation_labels(source)
  relation_ids <- names(labels)[labels == table]
  if (length(relation_ids) == 0) {
    return(character())
  }
  model_ids <- names(Filter(
    function(model) any(relation_ids %in% c(model$exposed, model$datasets)),
    catalog$models
  ))
  scopes <- c(relation_ids, model_ids)
  records <- Filter(
    function(record) {
      identical(record$delivery, "first_touch") &&
        (length(record$scope) == 0 || any(record$scope %in% scopes))
    },
    catalog$context
  )
  unique(vapply(records, `[[`, character(1), "text"))
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

source_label <- function(source_name) {
  if (is.null(source_name)) {
    return("")
  }
  sprintf(" (%s)", html_escape(source_name))
}

tool_result <- function(
  value,
  title,
  icon = NULL,
  html = NULL,
  markdown = NULL,
  tag = NULL,
  open = FALSE,
  show_request = FALSE,
  show_tag = TRUE
) {
  if (!is.null(tag) && isTRUE(show_tag)) {
    title <- sprintf("%s \u00b7 %s", title, tag_label(tag))
  }
  display <- list(title = title, open = open, show_request = show_request)
  if (!is.null(icon)) {
    display$icon <- icon
  }
  if (!is.null(html)) {
    display$html <- html
  }
  if (!is.null(markdown)) {
    display$markdown <- markdown
  }

  ellmer::ContentToolResult(
    value = value,
    extra = list(display = display, commons_tag = tag)
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
    rows <- "<div class=\"commons-measure-arg commons-measure-arg-empty\">No arguments</div>"
  } else {
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
  }

  sprintf("<div class=\"commons-measure-args\">%s</div>", rows)
}

measure_display_html <- function(args, value) {
  sprintf(
    "<div class=\"commons-measure-display\">%s%s</div>",
    measure_args_html(args),
    measure_result_html(value)
  )
}

measure_result_html <- function(value) {
  sprintf(
    "<div class=\"commons-measure-result\"><strong>Tool result</strong><div class=\"commons-measure-result-value\">%s</div></div>",
    format_measure_html(value)
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
