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
  catalog_table_registry(
    con,
    tables,
    current_namespace = snowflake_current_namespace,
    id_type = snowflake_id_type,
    exact_relation = snowflake_exact_relation,
    list_relations = snowflake_list_relations,
    call = call
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
  relations <- snowflake_relations_from_show(rows)
  catalog_match_exact_relation(relations, id)
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
  catalog_id_type(id, "Snowflake", call = call)
}
