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
