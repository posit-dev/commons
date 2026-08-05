#' Create a data source
#'
#' A data source is the set of tables available to a [commons()] agent.
#'
#' `data_source()` accepts data in several forms, picked by the class of what
#' you pass:
#'
#' * A DBI connection is queried as-is. Nothing is copied; the agent queries
#'   the database directly.
#' * Named data frames are loaded into an in-process DuckDB database. Use this
#'   when the data isn't already in a database.
#' * A `pins` board, e.g. [pins::board_connect()], is read into the same
#'   in-process database: each pin selected by `options` becomes a table. Pin
#'   names are validated against the board at construction (a single listing call), but
#'   each pin is downloaded only when its table is first used---by the
#'   `describe_table` tool, a SQL query that references it, or a measure that
#'   takes the source's connection. [commons_server()] starts a background
#'   process right after startup that downloads the remaining pins into the
#'   local pins cache, so a first use typically only reads an
#'   already-downloaded file. A table reflects the pin's
#'   value at first use and is not refreshed for the lifetime of the data
#'   source; if a pin can't be read (e.g. a network failure), the error
#'   surfaces at that first use and the read is retried on the next one.
#'
#' The resulting object gives the agent a DBI connection plus a table registry.
#' Use [list_tables()] to list the registered tables.
#'
#' @param ... A single DBI connection, a single `pins` board, or named data
#'   frames to register as tables. When passing data frames, each name becomes
#'   a table name the agent can query.
#' @param tables Deprecated. Use `options = data_source_options(include = ...)`.
#'
#'   Existing connection values retain their former behavior: strings with
#'   dots are treated as schema-qualified names. Existing board values retain
#'   their local-name-to-pin-name mapping.
#' @param options Selection, exclusion, and sampling controls from
#'   [data_source_options()]. DBI connections discover their current namespace
#'   by default. Boards require an explicit named `include` mapping.
#'
#'   Selection controls which objects commons describes to the model. The
#'   connection's grants remain the security boundary for SQL execution.
#' @param dictionary An optional path to a data dictionary describing the
#'   source's tables and columns, in the
#'   [data-dict.yaml](https://data-dict.tidyverse.org/) format, or an Apache
#'   Ossie model from [ossie_model()]. See the `Data dictionaries` section.
#'
#' @section Data dictionaries:
#' A data dictionary describes a data source's tables and columns: what each
#' table's rows represent, what its columns mean, allowed values and units,
#' how tables join, and definitions of domain terms. Its content reaches the
#' agent three ways:
#'
#' * The dataset-level `description` and `details`, along with the glossary,
#'   are included in the system prompt. These fields are the place for rules
#'   that span tables and for guidance on which tables answer which kinds of
#'   questions.
#' * The first time a conversation touches a table---via the `describe_table`
#'   tool or a SQL query---the table's full dictionary entry rides along with
#'   the tool result: its prose, documented columns, relationships, and
#'   definitions of glossary terms it references. `describe_table` merges
#'   documented columns with the table's live schema.
#' * When the agent also has a [context_layer()], the dictionary's prose is
#'   indexed for the `search_context` tool.
#'
#' A table's entry can also declare `definitions`: named, governed SQL
#' expressions with declared types that the model applies as `{{name}}`
#' tokens in `run_sql` queries, expanded to their trusted SQL before the
#' query runs. Definitions are validated against the live source and
#' delivered through all three channels above.
#'
#' [ossie_model()] reads Apache Ossie YAML or JSON into the same authored
#' metadata layer. Matching and selection rules are identical to data-dict;
#' [write_ossie()] exports the representable merged catalog and reports lossy
#' constructs as diagnostics.
#'
#' @section Trust:
#' The `run_sql` tool runs only read-only `SELECT` queries; statements that
#' would modify data or schema (`INSERT`, `UPDATE`, `DROP`, and similar) are
#' rejected before reaching the database. For the in-process DuckDB built from
#' data frames, commons additionally disables extension loading and filesystem
#' access. These are safeguards, not a sandbox: when you supply your own
#' connection, still open it in read-only mode where the backend supports it.
#'
#' @return A `commons_data_source` object.
#'
#' @examples
#' src <- data_source(
#'   sales = data.frame(id = 1:2, revenue = c(100, 200))
#' )
#' list_tables(src)
#'
#' @export
data_source <- function(
  ...,
  tables = NULL,
  dictionary = NULL,
  options = NULL
) {
  dots <- rlang::list2(...)
  dictionary <- as_authored_metadata(dictionary)
  kind <- data_source_kind(dots)
  options <- as_data_source_options(options, tables, kind)

  local_commons_span(
    "commons_data_source_create",
    attributes = list("commons.data_source.kind" = kind)
  )

  if (kind == "connection") {
    return(data_source_connection(dots[[1]], options, dictionary = dictionary))
  }
  if (kind == "board") {
    return(data_source_board(dots[[1]], options, dictionary = dictionary))
  }

  data_source_frames(dots, dictionary, options)
}

data_source_frames <- function(
  dots,
  dictionary,
  options,
  call = rlang::caller_env()
) {
  check_named_frames(dots, call = call)
  selected <- select_flat_names(names(dots), options, call)
  dots <- dots[selected]
  if (!is.null(options$include) || length(options$exclude)) {
    dictionary <- catalog_scope_flat_authored(dictionary, names(dots), "frames")
  }
  local_commons_span(
    "commons_data_source_load_frames",
    attributes = list("commons.data_source.n_tables" = length(dots))
  )
  con <- duckdb_connect()
  for (name in names(dots)) {
    DBI::dbWriteTable(
      con,
      name,
      as.data.frame(dots[[name]]),
      overwrite = TRUE
    )
  }
  duckdb_lock_down(con)

  new_data_source(
    con,
    names(dots),
    owned = TRUE,
    dictionary = dictionary,
    options = options
  )
}

data_source_kind <- function(dots) {
  if (length(dots) == 1 && inherits(dots[[1]], "DBIConnection")) {
    return("connection")
  }
  if (length(dots) == 1 && inherits(dots[[1]], "pins_board")) {
    return("board")
  }
  "frames"
}

data_source_connection <- function(
  con,
  options,
  dictionary = NULL,
  call = rlang::caller_env()
) {
  span <- local_commons_span("commons_data_source_list_tables")
  provider <- new_catalog_provider(con, options, call)
  authored <- catalog_from_authored_metadata(dictionary)
  if (length(authored$sources)) {
    catalog_provider_probe_authored(provider, authored, call = call)
    provider$catalog <- catalog_merge(
      provider$catalog,
      authored,
      relation_ids = provider$authored_relation_ids,
      call = call
    )
  }
  table_registry <- list(
    labels = names(provider$table_ids),
    ids = provider$table_ids
  )
  commons_span_set_attribute(
    span,
    "commons.data_source.n_tables",
    length(table_registry$labels)
  )
  new_data_source(
    con,
    table_registry$labels,
    owned = FALSE,
    table_ids = table_registry$ids,
    dictionary = dictionary,
    catalog = provider$catalog,
    provider = provider,
    options = provider$options,
    relation_labels = provider$relation_labels
  )
}

data_source_board <- function(
  board,
  options,
  dictionary = NULL,
  call = rlang::caller_env()
) {
  tables <- options$include
  if (!rlang::is_named(tables) || !is.character(tables)) {
    cli::cli_abort(
      "Board {.arg include} must be a named character vector of pin names.",
      call = call
    )
  }
  if (length(tables) == 0) {
    cli::cli_abort("Board {.arg include} must name at least one pin.", call = call)
  }
  duplicated_labels <- unique(names(tables)[duplicated(names(tables))])
  if (length(duplicated_labels)) {
    cli::cli_abort(
      "Board {.arg include} must not contain duplicate names: {.val {duplicated_labels}}.",
      call = call
    )
  }
  tables <- tables[!catalog_excluded(names(tables), options$exclude)]
  if (length(tables) == 0) {
    cli::cli_abort("{.arg exclude} removes every selected pin.", call = call)
  }

  local_commons_span(
    "commons_data_source_list_pins",
    attributes = list("commons.data_source.n_tables" = length(tables))
  )
  check_board_pins_exist(board, tables, call = call)
  dictionary <- catalog_scope_flat_authored(dictionary, names(tables), "board")

  # Lock the connection down before any writes; lock_configuration() only
  # freezes SET statements, so later dbWriteTable() from a deferred read still
  # works.
  con <- duckdb_connect()
  duckdb_lock_down(con)
  check_labels_free(con, names(tables), call = call)

  new_data_source(
    con,
    names(tables),
    owned = TRUE,
    dictionary = dictionary,
    pending = new_pending_pins(board, tables),
    options = options
  )
}

# The deferred-read state a board source carries: the board plus the pins not
# yet loaded (named character: table label -> pin name). Shared by every copy
# of the source, so a read through one copy is seen by all. source_prewarm()
# also stores its background downloader's handle here ($process), so every
# copy sees at most one live warmer.
new_pending_pins <- function(board, tables) {
  pending <- new.env(parent = emptyenv())
  pending$board <- board
  pending$pins <- tables
  pending
}

#' List the tables an agent can query
#'
#' @param data_source A [data_source()].
#'
#' @return A character vector of table names.
#'
#' @export
list_tables <- function(data_source) {
  check_data_source(data_source)
  source_tables(data_source)
}

source_runtime_dictionary <- function(source) {
  if (is.null(source$provider)) {
    return(source$dictionary)
  }
  catalog_to_runtime_dictionary(
    source_catalog(source),
    source_relation_labels(source)
  )
}

source_catalog <- function(source) {
  source_provider_check(source)
  source$provider$catalog %||% source$catalog
}

source_table_ids <- function(source) {
  source_provider_check(source)
  source$provider$table_ids %||% source$table_ids
}

source_tables <- function(source) {
  names(source_table_ids(source))
}

source_relation_labels <- function(source) {
  source$provider$relation_labels %||% source$relation_labels
}

source_provider_check <- function(source, call = rlang::caller_env()) {
  if (!is.null(source$provider)) {
    catalog_provider_check(source$provider, call)
  }
  invisible(source)
}

catalog_sources_check <- function(sources, call = rlang::caller_env()) {
  for (source in sources) {
    source_provider_check(source, call)
  }
  invisible(sources)
}

catalog_scope_flat_authored <- function(metadata, tables, kind) {
  authored <- catalog_from_authored_metadata(metadata)
  if (length(authored$sources) == 0) {
    return(authored)
  }
  source <- new_catalog_source(
    catalog_id("source", kind, "selection"),
    kind
  )
  relations <- lapply(tables, function(table) {
    new_catalog_relation(
      catalog_id("relation", source$id, table),
      source$id,
      new_source_path(c(table = table)),
      name = table
    )
  })
  discovered <- new_commons_catalog(
    sources = list(source),
    relations = relations
  )
  catalog_scope_authored(authored, discovered)
}

new_data_source <- function(
  con,
  tables,
  owned,
  table_ids = table_ids_from_labels(tables),
  dictionary = NULL,
  pending = NULL,
  catalog = catalog_from_authored_metadata(dictionary),
  provider = NULL,
  options = data_source_options(),
  relation_labels = character()
) {
  if (!is.null(provider) && length(catalog$sources)) {
    dictionary <- catalog_to_runtime_dictionary(catalog, relation_labels)
  } else if (inherits(dictionary, "commons_catalog")) {
    dictionary <- catalog_to_data_dictionary(catalog)
  }

  # Disconnect only the DuckDB connection we created; a user-supplied connection
  # has its own owner and lifetime.
  handle <- NULL
  if (owned) {
    handle <- new.env(parent = emptyenv())
    handle$con <- con
    reg.finalizer(
      handle,
      function(h) DBI::dbDisconnect(h$con, shutdown = TRUE),
      onexit = TRUE
    )
  }

  structure(
    list(
      con = con,
      tables = tables,
      table_ids = table_ids,
      handle = handle,
      dictionary = dictionary,
      catalog = catalog,
      provider = provider,
      options = options,
      relation_labels = relation_labels,
      pending = pending
    ),
    class = "commons_data_source"
  )
}

# Pick the data source a SQL tool call runs against. With one source no
# choice is needed; with several, the model passes a `source` name. The tool
# schema's enum should prevent bad values, but validate anyway so a bad call
# gets a clear error the model can act on.
resolve_sql_source <- function(sources, name, call = rlang::caller_env()) {
  if (length(sources) == 1) {
    return(sources[[1]])
  }
  if (!is.null(name) && name %in% names(sources)) {
    return(sources[[name]])
  }

  problem <- if (is.null(name)) {
    "{.arg source} is required when an agent has multiple data sources."
  } else {
    "No data source named {.val {name}}."
  }
  cli::cli_abort(
    c(problem, i = "Available sources: {.val {names(sources)}}."),
    call = call
  )
}

# Best-effort dialect hint for the system prompt. odbc and several other
# backends report a dbms name; fall back to the connection class.
source_dialect <- function(source) {
  info <- tryCatch(DBI::dbGetInfo(source$con), error = function(e) NULL)
  info$dbms.name %||% sub("_connection$", "", class(source$con)[[1]])
}

# A pin leaves `pending` only after a successful read, so a failure surfaces
# to the caller and the read is retried on the next touch.
source_ensure_tables <- function(source, tables, call = rlang::caller_env()) {
  pending <- source$pending
  if (is.null(pending)) {
    return(invisible(source))
  }
  todo <- intersect(tables, names(pending$pins))
  if (length(todo) == 0) {
    return(invisible(source))
  }

  local_commons_span(
    "commons_data_source_read_board",
    attributes = list("commons.data_source.n_tables" = length(todo))
  )
  for (table in todo) {
    pin <- pending$pins[[table]]
    value <- tryCatch(
      pins::pin_read(pending$board, pin),
      error = function(err) {
        cli::cli_abort(
          "Failed to read pin {.val {pin}} for table {.val {table}}.",
          parent = err,
          call = call
        )
      }
    )
    if (!is.data.frame(value)) {
      cli::cli_abort(
        c(
          "Pin {.val {pin}} for table {.val {table}} is not a data frame.",
          i = "It is {.obj_type_friendly {value}}."
        ),
        call = call
      )
    }
    DBI::dbWriteTable(source$con, table, as.data.frame(value), overwrite = TRUE)
    pending$pins <- pending$pins[setdiff(names(pending$pins), table)]
  }
  invisible(source)
}

source_ensure_all <- function(source, call = rlang::caller_env()) {
  source_ensure_tables(source, source_tables(source), call = call)
}

# Warm the pins on-disk cache in a background process rather than loading into
# DuckDB: dbWriteTable() must run in this process (where the DuckDB lives) and
# would block every question asked during the load. The board is serialized to
# the child, carrying its resolved cache path and auth, so the child writes to
# the cache the parent reads even when the default cache location would
# resolve differently (e.g. a deployment that repoints HOME).
#
# The handle lives on the shared pending env, so at most one child runs per
# source; once it exits with pins still pending, a later prewarm() respawns,
# and already-cached pins short-circuit so only genuine failures retry. A
# failed spawn degrades to pure on-demand loading. Killing the child mid-write
# can leave a truncated cache file pins won't re-download---the same hazard as
# interrupting pin_read() itself.
source_prewarm <- function(source) {
  pending <- source$pending
  if (is.null(pending) || length(pending$pins) == 0) {
    return(invisible(source))
  }
  if (!is.null(pending$process) && pending$process$is_alive()) {
    return(invisible(source))
  }
  pending$process <- tryCatch(
    callr::r_bg(
      prewarm_downloads,
      args = list(board = pending$board, pins = unique(unname(pending$pins))),
      supervise = TRUE
    ),
    error = function(err) NULL
  )
  invisible(source)
}

# Runs inside a background callr process, so it must be self-contained,
# referencing only base R and pins:: (the same constraint as the worker_*
# functions in run-r.R). Best-effort: a failing pin is skipped so it can't
# stop the rest from warming. The per-pin result is unused in production but
# makes tests deterministic.
prewarm_downloads <- function(board, pins) {
  vapply(
    pins,
    function(pin) {
      tryCatch(
        {
          pins::pin_download(board, pin)
          TRUE
        },
        error = function(err) FALSE
      )
    },
    logical(1)
  )
}

# The pending tables a failed query actually references, read from DuckDB's
# own catalog error ("Table with name X does not exist!") rather than from the
# SQL text. Anchoring on the fixed surrounding phrase---not a bare-name match,
# which would also fire on DuckDB's "Did you mean" suggestions---keeps a name
# in a string literal, comment, or column reference from triggering a spurious
# read. The phrase itself does the bounding, so a label that begins or ends in
# punctuation (which \b can't wrap) still matches.
pending_tables_in_error <- function(source, err) {
  pending <- source$pending
  if (is.null(pending)) {
    return(character())
  }
  msg <- conditionMessage(err)
  labels <- names(pending$pins)
  labels[vapply(
    labels,
    function(table) {
      grepl(
        paste0("Table with name ", escape_regex(table), " does not exist"),
        msg,
        ignore.case = TRUE
      )
    },
    logical(1)
  )]
}

source_describe <- function(source, table, n_sample = NULL) {
  id <- source_table_ids(source)[[table]]
  if (is.null(id)) {
    cli::cli_abort(c(
      "No table named {.val {table}}.",
      i = "Available tables: {.val {source_tables(source)}}."
    ))
  }
  source_ensure_tables(source, table)
  n_sample <- n_sample %||% source$options$sample_rows
  n_sample <- catalog_count(n_sample, "sample_rows")
  if (!is.null(source$provider)) {
    relation <- catalog_provider_hydrate(source$provider, table)
    schema <- data.frame(
      column = names(relation$columns),
      type = vapply(
        relation$columns,
        function(x) x$logical_type %||% x$native_type %||% "unknown",
        character(1)
      ),
      row.names = NULL
    )
  } else {
    metadata <- catalog_relation_metadata(source$con, id)
    schema <- data.frame(
      column = names(metadata$columns),
      type = vapply(
        metadata$columns,
        function(x) x$logical_type %||% x$native_type %||% "unknown",
        character(1)
      ),
      row.names = NULL
    )
  }
  sample <- if (n_sample > 0) {
    DBI::dbGetQuery(
      source$con,
      sprintf(
        "SELECT * FROM %s LIMIT %d",
        DBI::dbQuoteIdentifier(source$con, id),
        n_sample
      )
    )
  } else {
    stats::setNames(
      as.data.frame(rep(list(logical()), nrow(schema))),
      schema$column
    )
  }
  restricted <- source_restricted_columns(source, table)
  sample <- sample[setdiff(names(sample), restricted)]
  list(schema = schema, sample = sample)
}

source_restricted_columns <- function(source, table) {
  columns <- source_runtime_dictionary(source)$tables[[table]]$columns
  names(Filter(
    function(column) identical(column$display, "restricted"),
    columns
  ))
}

source_query <- function(source, sql) {
  if (!is.null(source$provider)) catalog_provider_check(source$provider)
  check_query(sql)
  if (is.null(source$pending)) {
    return(DBI::dbGetQuery(source$con, sql))
  }

  # Let DuckDB resolve the query's table references and drive loading off the
  # tables it reports missing: run the query, load the pending tables its
  # error names, and retry. A genuine error (bad column, syntax) surfaces
  # unchanged, and each pass either loads at least one table or stops, so the
  # loop is bounded.
  repeat {
    result <- tryCatch(
      DBI::dbGetQuery(source$con, sql),
      error = function(err) err
    )
    if (!inherits(result, "condition")) {
      return(result)
    }
    todo <- pending_tables_in_error(source, result)
    if (length(todo) == 0) {
      stop(result)
    }
    source_ensure_tables(source, todo)
  }
}

# A keyword denylist, not a SQL parser: it anchors on the leading statement
# keyword, so it pairs with duckdb_lock_down() and the read-only-connection
# recommendation rather than standing alone. Ported from posit-dev/querychat.
check_query <- function(sql, call = rlang::caller_env()) {
  normalized <- toupper(trimws(gsub(
    " +",
    " ",
    gsub("[\r\n\t]+", " ", sql)
  )))
  blocked <- c(
    "DELETE",
    "TRUNCATE",
    "CREATE",
    "DROP",
    "ALTER",
    "GRANT",
    "REVOKE",
    "EXEC",
    "EXECUTE",
    "CALL",
    "INSERT",
    "UPDATE",
    "MERGE",
    "REPLACE",
    "UPSERT"
  )
  pattern <- paste0("^(", paste(blocked, collapse = "|"), ")\\b")
  if (grepl(pattern, normalized)) {
    matched <- regmatches(normalized, regexpr(pattern, normalized))
    cli::cli_abort(
      c(
        "The query contains a disallowed operation: {.code {matched}}.",
        i = "Only read-only SELECT queries are allowed."
      ),
      call = call
    )
  }
  invisible(sql)
}

# DuckDB-specific hardening for the connection we own: no extension loading,
# no filesystem or external access, and the configuration locked thereafter.
duckdb_lock_down <- function(con) {
  DBI::dbExecute(
    con,
    "
SET allow_community_extensions = false;
SET allow_unsigned_extensions = false;
SET autoinstall_known_extensions = false;
SET autoload_known_extensions = false;
SET enable_external_access = false;
SET disabled_filesystems = 'LocalFileSystem';
SET lock_configuration = true;
"
  )
  invisible(con)
}

# DuckDB defaults its extension and home directories to the package library,
# which is read-only in deployed environments (e.g. Posit Connect). Point them
# at the session temp directory.
#
# `extension_directory` must be set in `config` (i.e. at startup): any query
# first initializes the extension subsystem against this directory, which fails
# when it defaults to the read-only package library. `home_directory`, however,
# is a process-global option; passing it in `config` re-sets a global option on
# every connection, which DuckDB rejects once any DuckDB instance already exists
# in the process (e.g. the connection a data frame `data_source()` holds). Set it
# instead with a session-scoped `SET`, which is safe across coexisting connections.
duckdb_connect <- function() {
  dir <- file.path(tempdir(), "duckdb")
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)
  con <- DBI::dbConnect(
    duckdb::duckdb(config = list(extension_directory = dir))
  )
  DBI::dbExecute(
    con,
    paste0("SET home_directory=", DBI::dbQuoteString(con, dir), ";")
  )
  con
}

normalize_table_registry <- function(tables, call = rlang::caller_env()) {
  entries <- table_entries(tables, call = call)
  ids <- lapply(entries, table_entry_id, call = call)
  labels <- vapply(ids, table_id_label, character(1), call = call)

  duplicated_labels <- unique(labels[duplicated(labels)])
  if (length(duplicated_labels)) {
    cli::cli_abort(
      "{.arg tables} must not contain duplicate labels: {.val {duplicated_labels}}.",
      call = call
    )
  }

  names(ids) <- labels
  list(labels = labels, ids = ids)
}

table_entries <- function(tables, call = rlang::caller_env()) {
  if (inherits(tables, "Id")) {
    return(list(tables))
  }
  if (is.character(tables)) {
    return(as.list(tables))
  }
  if (is.list(tables)) {
    return(tables)
  }

  cli::cli_abort(
    "{.arg tables} must be a character vector, a list, or a {.cls DBI::Id}.",
    call = call
  )
}

table_entry_id <- function(table, call = rlang::caller_env()) {
  if (inherits(table, "Id")) {
    return(table)
  }

  if (
    !is.character(table) ||
      length(table) != 1 ||
      is.na(table) ||
      table == ""
  ) {
    cli::cli_abort(
      "Each entry in {.arg tables} must be a table name or a {.cls DBI::Id}.",
      call = call
    )
  }

  parts <- strsplit(table, ".", fixed = TRUE)[[1]]
  if (any(parts == "")) {
    cli::cli_abort(
      "Schema-qualified entries in {.arg tables} must not contain empty name components.",
      call = call
    )
  }

  if (length(parts) == 1) {
    return(DBI::Id(table = table))
  }

  DBI::Id(
    schema = paste(parts[-length(parts)], collapse = "."),
    table = parts[[length(parts)]]
  )
}

table_id_label <- function(id, call = rlang::caller_env()) {
  components <- id@name
  table <- components["table"]

  if (is.na(table)) {
    cli::cli_abort(
      "{.cls DBI::Id} entries in {.arg tables} must include a {.arg table} component.",
      call = call
    )
  }

  if (any(is.na(components) | components == "")) {
    cli::cli_abort(
      "{.cls DBI::Id} entries in {.arg tables} must not contain empty name components.",
      call = call
    )
  }

  paste(components, collapse = ".")
}

table_ids_from_labels <- function(tables) {
  ids <- lapply(tables, function(table) DBI::Id(table = table))
  names(ids) <- tables
  ids
}

# Per-table dbExistsTable() calls cost one round trip each, which dominates
# startup against a remote warehouse. Probe every table in a single zero-row
# query instead, and fall back to per-table checks only to name the missing
# tables when that probe fails.
check_table_ids_exist <- function(con, table_registry, call = rlang::caller_env()) {
  probes <- vapply(
    table_registry$ids,
    function(id) {
      sprintf("SELECT 1 FROM %s WHERE 1 = 0", DBI::dbQuoteIdentifier(con, id))
    },
    character(1)
  )
  probe_error <- tryCatch(
    {
      DBI::dbGetQuery(con, paste(probes, collapse = " UNION ALL "))
      NULL
    },
    error = function(err) err
  )
  if (is.null(probe_error)) {
    return(invisible(table_registry))
  }

  exists <- vapply(
    table_registry$ids,
    function(id) isTRUE(DBI::dbExistsTable(con, id)),
    logical(1)
  )
  missing <- table_registry$labels[!exists]

  if (length(missing) == 0) {
    cli::cli_abort(
      "Failed to verify {.arg tables} against the connection.",
      parent = probe_error,
      call = call
    )
  }

  cli::cli_abort(
    "{.arg tables} names table{?s} not on the connection: {.val {missing}}.",
    call = call
  )
}

# One pin_list() call instead of a pin_read() per pin: fail fast on a bad pin
# name without paying to download anything. Connect's pin_list() returns
# owner/name full names while users typically pass the bare name, so a listed
# name matches either in full or by its post-slash suffix. A bare name that
# suffix-matches more than one owner's pin is ambiguous---pin_read() would
# reject it---so flag it here and ask for the qualified form.
check_board_pins_exist <- function(board, tables, call = rlang::caller_env()) {
  listed <- tryCatch(
    pins::pin_list(board),
    error = function(err) {
      cli::cli_abort(
        "Failed to list pins on the board.",
        parent = err,
        call = call
      )
    }
  )
  suffixes <- sub("^.*/", "", listed)
  status <- vapply(
    tables,
    function(pin) {
      if (pin %in% listed) {
        return("ok")
      }
      n_suffix <- sum(suffixes == pin)
      if (n_suffix > 1) {
        return("ambiguous")
      }
      if (n_suffix == 1) {
        return("ok")
      }
      # pin_list() can be capped (Connect returns up to 1000 pins), so absence
      # from it isn't proof the pin is missing. Confirm directly before
      # rejecting, and stay lenient if the check itself errors---the board is
      # reachable (pin_list() succeeded), so defer an odd per-pin failure to
      # read time rather than blocking a valid setup.
      exists <- tryCatch(
        isTRUE(pins::pin_exists(board, pin)),
        error = function(err) TRUE
      )
      if (exists) "ok" else "missing"
    },
    character(1)
  )
  missing <- unique(unname(tables[status == "missing"]))
  if (length(missing)) {
    cli::cli_abort(
      "{.arg tables} names pin{?s} not on the board: {.val {missing}}.",
      call = call
    )
  }
  ambiguous <- unique(unname(tables[status == "ambiguous"]))
  if (length(ambiguous)) {
    cli::cli_abort(
      c(
        "{.arg tables} names pin{?s} matching more than one pin on the board: {.val {ambiguous}}.",
        i = "Use the full {.val owner/name} form to disambiguate."
      ),
      call = call
    )
  }
  invisible(tables)
}

# A fresh DuckDB already exposes system relations (duckdb_tables, sqlite_master,
# pg_tables, information_schema.*, ...). A board label colliding with one is
# unusable: the pin can't be written under that name (DuckDB won't drop the
# built-in to overwrite it) and a query for it would silently read the built-in
# instead. Probe with a zero-row SELECT before any pins are written---anything
# that resolves here is a built-in---and reject the collisions.
check_labels_free <- function(con, labels, call = rlang::caller_env()) {
  taken <- labels[vapply(
    labels,
    function(label) {
      tryCatch(
        {
          DBI::dbGetQuery(
            con,
            sprintf(
              "SELECT 1 FROM %s WHERE 1 = 0",
              DBI::dbQuoteIdentifier(con, label)
            )
          )
          TRUE
        },
        error = function(err) FALSE
      )
    },
    logical(1)
  )]
  if (length(taken)) {
    cli::cli_abort(
      c(
        "{.arg tables} label{?s} {?collides/collide} with built-in database relation{?s}: {.val {taken}}.",
        i = "{cli::qty(taken)}Rename the affected table{?s}."
      ),
      call = call
    )
  }
  invisible(labels)
}

check_named_frames <- function(frames, call = rlang::caller_env()) {
  if (length(frames) == 0) {
    cli::cli_abort("Supply at least one named data frame.", call = call)
  }
  if (!rlang::is_named(frames)) {
    cli::cli_abort(
      "All arguments to {.fn data_source} must be named.",
      call = call
    )
  }
  is_df <- vapply(frames, is.data.frame, logical(1))
  if (!all(is_df)) {
    cli::cli_abort(
      "Every argument must be a data frame; {.arg {names(frames)[!is_df]}} {?is/are} not.",
      call = call
    )
  }
}

check_data_source <- function(data_source, call = rlang::caller_env()) {
  if (!inherits(data_source, "commons_data_source")) {
    cli::cli_abort(
      "{.arg data_source} must be a {.fn data_source}.",
      call = call
    )
  }
}

# A bare data_source() is accepted for the quick-start path; it has no name,
# so measures can't take its connection as an argument. commons() calls this
# before constructing the agent, so it must accept its own output.
as_data_sources <- function(x, call = rlang::caller_env()) {
  if (inherits(x, "commons_data_source")) {
    return(list(x))
  }

  all_sources <- is.list(x) &&
    length(x) > 0 &&
    all(vapply(x, inherits, logical(1), "commons_data_source"))
  if (!all_sources) {
    cli::cli_abort(
      "{.arg data_sources} must be a {.fn data_source} or a named list of them.",
      call = call
    )
  }

  if (length(x) > 1 && !rlang::is_named(x)) {
    cli::cli_abort(
      "Each entry in {.arg data_sources} must be named.",
      call = call
    )
  }

  duplicated_names <- unique(names(x)[duplicated(names(x))])
  if (length(duplicated_names)) {
    cli::cli_abort(
      "{.arg data_sources} names must be unique; duplicated name{?s}: {.val {duplicated_names}}.",
      call = call
    )
  }

  x
}
