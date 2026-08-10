catalog_table_registry <- function(
  con,
  tables,
  current_namespace,
  id_type,
  exact_relation,
  list_relations,
  call = rlang::caller_env()
) {
  if (is.null(tables)) {
    ids <- list(current_namespace(con, call = call))
  } else {
    entries <- table_entries(tables, call = call)
    ids <- lapply(entries, table_entry_id, call = call)
  }

  relations <- list()
  validate <- list()
  for (id in ids) {
    type <- id_type(id, call = call)
    if (identical(type, "relation")) {
      relation <- exact_relation(con, id, call = call)
      relations[[length(relations) + 1L]] <- relation
      validate[[length(validate) + 1L]] <- id
      next
    }
    relations <- c(relations, list_relations(con, id, call = call))
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

catalog_id_type <- function(id, backend, call = rlang::caller_env()) {
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
      "{backend} {.cls DBI::Id} entries in {.arg tables} must follow
       catalog, schema, and table order without skipped or empty components.",
      call = call
    )
  }
  if ("table" %in% roles) "relation" else "namespace"
}

catalog_match_exact_relation <- function(relations, id) {
  requested_name <- id@name[["table"]]
  is_requested <- vapply(
    relations,
    function(relation) {
      identical(relation$id@name[["table"]], requested_name)
    },
    logical(1)
  )
  if (!any(is_requested)) {
    return(list(id = id, kind = NULL, description = NULL))
  }

  relation <- relations[[which(is_requested)[[1]]]]
  relation$id <- id
  relation
}
