# The relations in a generic DBI connection's current schema, named by bare
# table name, or NULL when the backend can't report a current schema or has no
# information_schema (SQLite, for one), where the caller falls back to
# DBI::dbListTables().
dbi_current_relations <- function(con) {
  namespace <- dbi_current_namespace(con)
  if (is.null(namespace)) {
    return(NULL)
  }
  relations <- dbi_list_relations(
    con,
    DBI::Id(schema = namespace$schema),
    catalog = namespace$catalog
  )
  if (!is.null(relations)) {
    names(relations) <- vapply(relations, catalog_relation_name, character(1))
  }
  relations
}

# `tables` for a generic DBI connection: table names and table ids as before,
# plus ids naming a whole schema, whose relations are labeled schema-qualified
# so they stay distinct across schemas.
dbi_table_registry <- function(con, tables, call = rlang::caller_env()) {
  entries <- table_entries(tables, call = call)
  is_namespace <- vapply(entries, dbi_is_namespace_id, logical(1), call = call)
  registry <- normalize_table_registry(entries[!is_namespace], call = call)
  if (length(registry$ids)) {
    check_table_ids_exist(con, registry, call = call)
  }
  if (!any(is_namespace)) {
    return(registry)
  }

  current <- dbi_current_namespace(con)
  relations <- lapply(registry$ids, dbi_named_relation, con = con, current = current)
  current_catalog <- current$catalog
  for (namespace in entries[is_namespace]) {
    listed <- dbi_list_relations(con, namespace, catalog = current_catalog)
    label <- paste(namespace@name, collapse = ".")
    if (is.null(listed)) {
      cli::cli_abort(
        c(
          "Can't list the tables in schema {.val {label}}.",
          i = "Selecting a whole schema requires {.code information_schema}; name its tables instead."
        ),
        call = call
      )
    }
    if (length(listed) == 0L) {
      cli::cli_abort(
        "Schema {.val {label}} contains no tables.",
        call = call
      )
    }
    names(listed) <- vapply(listed, function(x) table_id_label(x$id), character(1))
    relations <- c(relations, listed)
  }

  labels <- names(relations)
  duplicated_labels <- unique(labels[duplicated(labels)])
  if (length(duplicated_labels)) {
    cli::cli_abort(
      "{.arg tables} must not select duplicate labels: {.val {duplicated_labels}}.",
      call = call
    )
  }
  catalog_check_object_limit(length(relations), call = call)

  list(
    labels = labels,
    ids = lapply(relations, `[[`, "id"),
    relations = relations,
    namespace_selected = TRUE
  )
}

# Re-keys dictionary tables given a relative name, like `orders`, under the
# qualified label they uniquely match, like `marts.orders`, as the warehouse
# paths do. Unmatched tables keep the name the dictionary gives them.
dbi_bind_dictionary <- function(dictionary, ids, call = rlang::caller_env()) {
  if (is.null(dictionary) || length(dictionary$tables) == 0L) {
    return(list(dictionary = dictionary, definition_bindings = NULL))
  }
  relations <- lapply(ids, function(id) list(id = id))
  matches <- catalog_dictionary_matches(dictionary, relations, "lower", call = call)
  for (dictionary_name in names(matches)) {
    label <- matches[[dictionary_name]]
    if (is.na(label) || identical(label, dictionary_name)) {
      next
    }
    table <- dictionary$tables[[dictionary_name]]
    # Keep the dictionary's name for first-touch and relationship matching.
    table$.authored_name <- dictionary_name
    dictionary$tables[[dictionary_name]] <- NULL
    dictionary$tables[[label]] <- table
  }
  list(
    dictionary = dictionary,
    definition_bindings = list(tables = matches, columns = list(), strict = FALSE)
  )
}

# A table named in `tables`, with its kind looked up so searches filtered by
# kind treat it like the tables a schema selection lists. The kind is left
# unset when the backend can't say.
dbi_named_relation <- function(id, con, current) {
  components <- id@name
  schema <- if ("schema" %in% names(components)) {
    components[["schema"]]
  } else {
    current$schema
  }
  if (is.null(schema)) {
    return(list(id = id))
  }
  namespace <- do.call(
    DBI::Id,
    as.list(c(components[names(components) == "catalog"], schema = schema))
  )
  listed <- dbi_list_relations(
    con,
    namespace,
    catalog = current$catalog,
    table = components[["table"]]
  )
  list(id = id, kind = if (length(listed) == 1L) listed[[1]]$kind)
}

dbi_is_namespace_id <- function(entry, call = rlang::caller_env()) {
  if (!inherits(entry, "Id") || "table" %in% names(entry@name)) {
    return(FALSE)
  }
  components <- entry@name
  roles <- names(components)
  valid <- identical(roles, "schema") || identical(roles, c("catalog", "schema"))
  if (!valid || any(is.na(components) | !nzchar(components))) {
    cli::cli_abort(
      "A {.cls DBI::Id} selecting a whole schema must name a {.arg schema}, optionally preceded by a {.arg catalog}.",
      call = call
    )
  }
  TRUE
}

# The tables and views in one schema, with ids qualified as `namespace` is, or
# NULL when the backend has no information_schema to ask. `catalog` narrows the
# lookup when `namespace` doesn't name one; `table` narrows it to one relation.
dbi_list_relations <- function(con, namespace, catalog = NULL, table = NULL) {
  components <- namespace@name
  views <- "information_schema.tables"
  if ("catalog" %in% names(components)) {
    catalog <- components[["catalog"]]
    # SQL Server keeps one information_schema per database, so another
    # database's tables are only listed in its own; DuckDB rejects this form
    # and falls through to the unqualified view.
    views <- c(
      paste0(DBI::dbQuoteIdentifier(con, catalog), ".", views),
      views
    )
  }
  filter <- paste(
    "WHERE table_schema =",
    DBI::dbQuoteString(con, components[["schema"]])
  )
  # DuckDB's information_schema spans every attached database.
  if (!is.null(catalog)) {
    filter <- paste(filter, "AND table_catalog =", DBI::dbQuoteString(con, catalog))
  }
  if (!is.null(table)) {
    filter <- paste(filter, "AND table_name =", DBI::dbQuoteString(con, table))
  }
  rows <- NULL
  for (view in views) {
    sql <- paste("SELECT table_name, table_type FROM", view, filter)
    rows <- tryCatch(DBI::dbGetQuery(con, sql), error = function(err) NULL)
    if (!is.null(rows)) {
      break
    }
  }
  if (is.null(rows)) {
    return(NULL)
  }
  names(rows) <- tolower(names(rows))
  lapply(seq_len(nrow(rows)), function(i) {
    list(
      id = do.call(
        DBI::Id,
        c(as.list(components), table = rows$table_name[[i]])
      ),
      kind = dbi_relation_kind(rows$table_type[[i]])
    )
  })
}

dbi_current_namespace <- function(con) {
  for (sql in dbi_namespace_queries) {
    row <- tryCatch(DBI::dbGetQuery(con, sql), error = function(err) NULL)
    if (is.null(row) || nrow(row) != 1L) {
      next
    }
    names(row) <- tolower(names(row))
    schema <- catalog_session_value(row$namespace_schema[[1]])
    if (!is.null(schema)) {
      return(list(
        catalog = catalog_session_value(row$namespace_catalog[[1]]),
        schema = schema
      ))
    }
  }
  NULL
}

# Tried in order; a dialect that lacks a function errors and moves on. The
# aliases avoid `schema`, which SQL Server and MySQL reserve.
dbi_namespace_queries <- c(
  # PostgreSQL, DuckDB, Redshift
  "SELECT current_database() AS namespace_catalog, current_schema() AS namespace_schema",
  # SQL Server
  "SELECT DB_NAME() AS namespace_catalog, SCHEMA_NAME() AS namespace_schema",
  # MySQL and MariaDB, where a schema is a database and table_catalog is 'def'
  "SELECT NULL AS namespace_catalog, DATABASE() AS namespace_schema"
)

dbi_relation_kind <- function(type) {
  if (grepl("VIEW", toupper(type), fixed = TRUE)) "view" else "table"
}
