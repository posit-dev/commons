is_snowflake_connection <- function(con) {
  info <- tryCatch(DBI::dbGetInfo(con), error = function(err) NULL)
  name <- info$dbms.name
  rlang::is_string(name) && identical(tolower(name), "snowflake")
}

snowflake_table_registry <- function(
  con,
  tables = NULL,
  call = rlang::caller_env()
) {
  if (is.null(tables)) {
    ids <- list(snowflake_current_namespace(con, call = call))
  } else {
    entries <- table_entries(tables, call = call)
    ids <- lapply(entries, table_entry_id, call = call)
  }

  relations <- list()
  validate <- list()
  for (id in ids) {
    type <- snowflake_id_type(id, call = call)
    if (identical(type, "relation")) {
      relation <- snowflake_exact_relation(con, id, call = call)
      label <- table_id_label(id, call = call)
      relations[[length(relations) + 1L]] <- relation
      validate[[length(validate) + 1L]] <- id
      next
    }
    relations <- c(
      relations,
      snowflake_list_relations(con, id, call = call)
    )
  }

  labels <- vapply(relations, function(x) {
    table_id_label(x$id, call = call)
  }, character(1))
  duplicated_labels <- unique(labels[duplicated(labels)])
  if (length(duplicated_labels)) {
    cli::cli_abort(
      "{.arg tables} must not select duplicate labels: {.val {duplicated_labels}}.",
      call = call
    )
  }

  relation_ids <- lapply(relations, `[[`, "id")
  names(relation_ids) <- labels
  names(relations) <- labels

  validate_labels <- vapply(validate, table_id_label, character(1), call = call)
  names(validate) <- validate_labels

  list(
    labels = labels,
    ids = relation_ids,
    relations = relations,
    validate = list(labels = validate_labels, ids = validate)
  )
}

snowflake_current_namespace <- function(con, call = rlang::caller_env()) {
  row <- tryCatch(
    DBI::dbGetQuery(
      con,
      paste(
        "SELECT CURRENT_DATABASE() AS catalog,",
        "CURRENT_SCHEMA() AS schema"
      )
    ),
    error = function(err) {
      cli::cli_abort(
        "Failed to read the current Snowflake namespace.",
        parent = err,
        call = call
      )
    }
  )
  names(row) <- tolower(names(row))
  if (nrow(row) != 1L || !all(c("catalog", "schema") %in% names(row))) {
    cli::cli_abort(
      "Snowflake returned an invalid current namespace.",
      call = call
    )
  }
  values <- unlist(row[1, c("catalog", "schema")], use.names = TRUE)
  if (
    length(values) != 2L ||
      any(is.na(values)) ||
      any(!nzchar(values))
  ) {
    cli::cli_abort(
      c(
        "The Snowflake connection has no current database and schema.",
        "i" = "Set both on the connection or supply {.arg tables} as a {.cls DBI::Id}."
      ),
      call = call
    )
  }
  DBI::Id(catalog = values[["catalog"]], schema = values[["schema"]])
}

snowflake_list_relations <- function(con, namespace, call = rlang::caller_env()) {
  components <- namespace@name
  target <- if (identical(names(components), "catalog")) {
    paste("IN DATABASE", DBI::dbQuoteIdentifier(con, namespace))
  } else {
    paste("IN SCHEMA", DBI::dbQuoteIdentifier(con, namespace))
  }
  rows <- tryCatch(
    DBI::dbGetQuery(con, paste("SHOW OBJECTS", target)),
    error = function(err) {
      cli::cli_abort(
        "Failed to list relations in the selected Snowflake namespace.",
        parent = err,
        call = call
      )
    }
  )
  snowflake_relations_from_show(rows)
}

snowflake_exact_relation <- function(con, id, call = rlang::caller_env()) {
  components <- id@name
  namespace <- components[setdiff(names(components), "table")]
  if (length(namespace) == 0L) {
    namespace <- snowflake_current_namespace(con, call = call)@name
  }
  namespace <- do.call(DBI::Id, as.list(namespace))
  target <- paste("IN SCHEMA", DBI::dbQuoteIdentifier(con, namespace))
  rows <- tryCatch(
    DBI::dbGetQuery(
      con,
      paste(
        "SHOW OBJECTS LIKE",
        DBI::dbQuoteString(con, components[["table"]]),
        target
      )
    ),
    error = function(err) {
      cli::cli_abort(
        "Failed to read metadata for the selected Snowflake relation.",
        parent = err,
        call = call
      )
    }
  )
  matches <- snowflake_relations_from_show(rows)
  matches <- Filter(
    function(x) identical(x$id@name[["table"]], components[["table"]]),
    matches
  )
  if (length(matches)) {
    relation <- matches[[1]]
    relation$id <- id
    return(relation)
  }
  list(id = id, kind = NULL, description = NULL)
}

snowflake_relations_from_show <- function(rows) {
  names(rows) <- tolower(names(rows))
  if (nrow(rows) == 0L) {
    return(list())
  }
  rows <- rows[toupper(rows$kind) %in% c("TABLE", "VIEW"), , drop = FALSE]
  lapply(seq_len(nrow(rows)), function(i) {
    description <- rows$comment[[i]]
    if (is.na(description) || !nzchar(description)) {
      description <- NULL
    }
    list(
      id = DBI::Id(
        catalog = rows$database_name[[i]],
        schema = rows$schema_name[[i]],
        table = rows$name[[i]]
      ),
      kind = tolower(rows$kind[[i]]),
      description = description
    )
  })
}

snowflake_describe_relation <- function(con, id, call = rlang::caller_env()) {
  rows <- tryCatch(
    DBI::dbGetQuery(
      con,
      paste("DESC TABLE", DBI::dbQuoteIdentifier(con, id))
    ),
    error = function(err) {
      cli::cli_abort(
        "Failed to describe the selected Snowflake relation.",
        parent = err,
        call = call
      )
    }
  )
  names(rows) <- tolower(names(rows))
  rows <- rows[toupper(rows$kind) == "COLUMN", , drop = FALSE]
  description <- rows$comment
  description[is.na(description) | !nzchar(description)] <- NA_character_
  data.frame(
    column = rows$name,
    type = rows$type,
    nullable = rows[["null?"]] == "Y",
    description = description,
    row.names = NULL
  )
}

snowflake_id_type <- function(id, call = rlang::caller_env()) {
  components <- id@name
  roles <- names(components)
  valid <- list(
    c("catalog"),
    c("schema"),
    c("catalog", "schema"),
    c("table"),
    c("schema", "table"),
    c("catalog", "schema", "table")
  )
  if (
    !any(vapply(valid, identical, logical(1), roles)) ||
      any(is.na(components) | !nzchar(components))
  ) {
    cli::cli_abort(
      "Snowflake {.cls DBI::Id} entries in {.arg tables} must follow
       catalog, schema, and table order without skipped or empty components.",
      call = call
    )
  }
  if ("table" %in% roles) "relation" else "namespace"
}
