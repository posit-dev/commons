build_commons_tools <- function(self, private) {
  list(
    tool_search_measures(private),
    tool_call_measure(private),
    tool_search_context(private),
    tool_describe_table(private),
    tool_run_sql(private)
  )
}

tool_search_measures <- function(private) {
  source_names <- if (length(private$sources) > 1) {
    names(private$sources)
  } else {
    character()
  }
  ellmer::tool(
    function(query) {
      search_measures_text(private$registry, query, source_names)
    },
    "Search registered measures. Returns matching measures with their argument schemas. Use this before call_measure.",
    arguments = list(
      query = ellmer::type_string(
        "What you want to measure, in plain language."
      )
    ),
    name = "search_measures",
    annotations = ellmer::tool_annotations(
      title = "Search measures",
      icon = maybe_icon("search"),
      read_only_hint = TRUE
    )
  )
}

tool_call_measure <- function(private) {
  ellmer::tool(
    function(name, arguments = "{}", sql = NULL) {
      call_measure_tool(
        private$registry,
        name,
        arguments,
        sql,
        injections = private$injections
      )
    },
    # For small registries, we may eventually expose each measure schema upfront
    # instead of relying on search_measures for discovery.
    "Run a registered measure returned by search_measures. `arguments` is a JSON object using exactly the argument names from search_measures. If the measure output is close to the answer but needs a final filter, total, ratio, ranking, or other derivation, pass a read-only SELECT query in `sql`; the measure output is available as the table `measure`.",
    arguments = list(
      name = ellmer::type_string(
        "The measure name, exactly as returned by search_measures."
      ),
      arguments = ellmer::type_string(
        "A JSON object of the measure's arguments."
      ),
      sql = ellmer::type_string(
        "Optional read-only SELECT query to run against the measure output, exposed as the table `measure`. Prefer this over calculating from the measure output yourself when a governed measure gets close to the answer.",
        required = FALSE
      )
    ),
    name = "call_measure",
    annotations = ellmer::tool_annotations(
      title = "Measure",
      icon = maybe_icon("shield-check"),
      read_only_hint = TRUE
    )
  )
}

tool_search_context <- function(private) {
  ellmer::tool(
    function(query) search_context_tool(private$context_layer, query),
    "Search context for metric definitions, data notes, and table relationships.",
    arguments = list(
      query = ellmer::type_string(
        "What you need context about, in plain language."
      )
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
      describe_table_tool(
        resolve_sql_source(private$sources, source),
        table,
        source_name = source,
        tracker = private$first_touch
      )
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
      title = "Describe table",
      icon = maybe_icon("table"),
      read_only_hint = TRUE
    )
  )
}

tool_run_sql <- function(private) {
  ellmer::tool(
    function(sql, source = NULL) {
      run_sql_tool(
        resolve_sql_source(private$sources, source),
        sql,
        source_name = source,
        tracker = private$first_touch
      )
    },
    "Run a read-only SELECT query against a data source. Use this when no registered measure answers the question.",
    arguments = list(
      sql = ellmer::type_string("A read-only SELECT query, in the data source's SQL dialect."),
      source = sql_source_type(private$sources)
    ),
    name = "run_sql",
    annotations = ellmer::tool_annotations(
      title = "SQL",
      icon = maybe_icon("code-square"),
      read_only_hint = TRUE
    )
  )
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
  sql = NULL,
  injections = list()
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
  value <- do.call(td, c(args, injections[[name]]))
  derived <- !is.null(sql) && !identical(sql, "")
  if (derived) {
    result <- query_measure_output(value, sql)
    body <- df_to_markdown(result)
    tag <- "B"
    html <- measure_display_html(args, value, sql = sql, derived_value = result)
  } else {
    body <- format_measure_value(value)
    tag <- "A"
    html <- measure_display_html(args, value)
  }
  tool_result(
    body,
    title = sprintf("Measure: %s", html_escape(tool_title(td))),
    icon = maybe_icon("shield-check"),
    html = html,
    tag = tag,
    open = TRUE,
    show_request = FALSE,
    show_tag = FALSE
  )
}

query_measure_output <- function(value, sql, call = rlang::caller_env()) {
  check_query(sql, call = call)
  df <- collect_measure_frame(value, call = call)

  con <- duckdb_connect()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  duckdb_lock_down(con)

  registered <- FALSE
  tryCatch(
    {
      invisible(duckdb::duckdb_register(con, "measure", df))
      registered <- TRUE
      DBI::dbGetQuery(con, sql)
    },
    finally = {
      if (registered) {
        try(duckdb::duckdb_unregister(con, "measure"), silent = TRUE)
      }
    }
  )
}

collect_measure_frame <- function(value, call = rlang::caller_env()) {
  if (inherits(value, "tbl_sql")) {
    rlang::check_installed("dplyr")
    value <- dplyr::collect(value)
  }
  if (!is.data.frame(value)) {
    cli::cli_abort(
      "{.arg sql} can only be supplied when the measure returns a data frame or lazy table.",
      call = call
    )
  }
  as.data.frame(value)
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

describe_table_tool <- function(source, table, source_name = NULL, tracker = NULL) {
  d <- source_describe(source, table)
  entry <- source$dictionary$tables[[table]]

  sample <- sprintf(
    "Sample rows:\n\n%s",
    df_to_markdown(d$sample, max_rows = 5)
  )
  if (is.null(entry)) {
    parts <- c(
      sprintf("Columns of `%s`:\n\n%s", table, df_to_markdown(d$schema)),
      sample
    )
  } else {
    mark_table_touched(tracker, source_name, table)
    columns <- sprintf(
      "Columns of `%s`:\n\n%s",
      table,
      dictionary_columns_text(entry$columns, live = d$schema)
    )
    parts <- c(
      dictionary_entry_parts(source$dictionary, table, columns),
      sample
    )
  }

  body <- paste(parts, collapse = "\n\n")
  tool_result(
    body,
    title = sprintf("Described %s%s", table, source_label(source_name)),
    icon = maybe_icon("table"),
    markdown = body
  )
}

run_sql_tool <- function(source, sql, source_name = NULL, tracker = NULL) {
  res <- source_query(source, sql)
  body <- df_to_markdown(res)
  display_md <- sprintf("```sql\n%s\n```\n\n%s", sql, body)
  entries <- dictionary_sql_entries(source, sql, source_name, tracker)
  tool_result(
    paste(c(body, entries), collapse = "\n\n"),
    title = sprintf("Ran SQL%s", source_label(source_name)),
    icon = maybe_icon("code-square"),
    markdown = display_md,
    tag = "B",
    open = FALSE,
    show_request = FALSE,
    show_tag = FALSE
  )
}

# Dictionary entries for tables this query touches that the conversation
# hasn't seen yet, via either tool. Matching is by table name in the SQL
# text, which is reliable in a way column matching is not; a false positive
# appends a harmless note.
dictionary_sql_entries <- function(source, sql, source_name, tracker) {
  dictionary <- source$dictionary
  tables <- names(dictionary$tables)
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
  vapply(
    hits,
    function(table) dictionary_entry_text(dictionary, table),
    character(1)
  )
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
  show_request = TRUE,
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

format_measure_value <- function(value) {
  if (inherits(value, "tbl_sql")) {
    rlang::check_installed("dplyr")
    value <- dplyr::collect(value)
  }
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

measure_display_html <- function(args, value, sql = NULL, derived_value = NULL) {
  result_label <- if (is.null(sql)) "Tool result" else "Measure result"
  sprintf(
    "<div class=\"commons-measure-display\">%s%s%s</div>",
    measure_args_html(args),
    measure_result_html(value, label = result_label),
    measure_sql_html(sql, derived_value)
  )
}

measure_result_html <- function(value, label = "Tool result") {
  sprintf(
    "<div class=\"commons-measure-result\"><strong>%s</strong><div class=\"commons-measure-result-value\">%s</div></div>",
    html_escape(label),
    format_measure_html(value)
  )
}

measure_sql_html <- function(sql, value) {
  if (is.null(sql)) {
    return("")
  }
  sprintf(
    "<div class=\"commons-measure-sql\"><strong>Post-processing SQL</strong><pre><code>%s</code></pre></div>%s",
    html_escape(sql),
    measure_result_html(value, label = "Derived result")
  )
}

# Render a measure result for display: data frames become HTML tables; other
# values reuse the text formatting, escaped for HTML.
format_measure_html <- function(value) {
  if (inherits(value, "tbl_sql")) {
    rlang::check_installed("dplyr")
    value <- dplyr::collect(value)
  }
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
