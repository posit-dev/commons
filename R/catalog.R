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

catalog_merge_dictionary <- function(
  dictionary,
  relations,
  con,
  describe_relation,
  identifier_case,
  call = rlang::caller_env()
) {
  if (is.null(dictionary) || length(dictionary$tables) == 0L) {
    return(list(
      dictionary = dictionary,
      relations = relations,
      definition_bindings = NULL
    ))
  }

  matches <- catalog_dictionary_matches(
    dictionary,
    relations,
    identifier_case,
    call = call
  )
  dictionary$relationships <- catalog_scope_dictionary_relationships(
    dictionary,
    matches
  )
  tables <- list()
  column_matches <- list()
  for (authored_name in names(matches)) {
    label <- matches[[authored_name]]
    if (is.na(label)) {
      next
    }
    relation <- relations[[label]]
    columns <- describe_relation(con, relation$id, call = call)
    relation$columns <- columns
    relations[[label]] <- relation
    merged <- catalog_merge_dictionary_table(
      dictionary$tables[[authored_name]],
      authored_name,
      label,
      relation,
      columns,
      identifier_case,
      call = call
    )
    tables[[label]] <- merged$table
    column_matches[[authored_name]] <- merged$column_matches
  }
  dictionary$tables <- tables

  list(
    dictionary = dictionary,
    relations = relations,
    definition_bindings = list(
      tables = matches,
      columns = column_matches,
      strict = TRUE
    )
  )
}

catalog_scope_dictionary_relationships <- function(dictionary, matches) {
  dropped <- names(matches)[is.na(matches)]
  if (length(dropped) == 0L) {
    return(dictionary$relationships)
  }
  keep <- vapply(
    dictionary$relationships,
    catalog_dictionary_relationship_in_scope,
    logical(1),
    dropped = dropped,
    dictionary = dictionary
  )
  dictionary$relationships[keep]
}

catalog_dictionary_relationship_in_scope <- function(
  relationship,
  dropped,
  dictionary
) {
  text <- paste(c(relationship$join, relationship$description), collapse = " ")
  !any(vapply(
    dropped,
    dictionary_table_mentioned,
    logical(1),
    dictionary = dictionary,
    text = text
  ))
}

catalog_dictionary_matches <- function(
  dictionary,
  relations,
  identifier_case,
  call = rlang::caller_env()
) {
  matches <- stats::setNames(
    rep(NA_character_, length(dictionary$tables)),
    names(dictionary$tables)
  )
  claimed <- character()
  for (authored_name in names(dictionary$tables)) {
    label <- catalog_dictionary_match(
      authored_name,
      relations,
      identifier_case,
      call = call
    )
    if (is.null(label)) {
      next
    }
    if (label %in% claimed) {
      other <- names(matches)[which(matches == label)]
      cli::cli_abort(
        "Authored tables {.val {c(other, authored_name)}} both match selected
         relation {.val {label}}.",
        call = call
      )
    }
    matches[[authored_name]] <- label
    claimed <- c(claimed, label)
  }
  matches
}

catalog_dictionary_match <- function(
  authored_name,
  relations,
  identifier_case,
  call = rlang::caller_env()
) {
  labels <- names(relations)
  exact <- labels[labels == authored_name]
  if (length(exact) == 1L) {
    return(exact)
  }

  authored <- catalog_normalize_identifier(authored_name, identifier_case)
  normalized_labels <- catalog_normalize_identifier(labels, identifier_case)
  exact <- labels[normalized_labels == authored]
  if (length(exact) == 1L) {
    return(exact)
  }
  if (length(exact) > 1L) {
    catalog_abort_ambiguous_dictionary_table(
      authored_name,
      exact,
      call = call
    )
  }

  relation_names <- vapply(
    relations,
    function(relation) relation$id@name[["table"]],
    character(1)
  )
  relative <- labels[
    catalog_normalize_identifier(relation_names, identifier_case) == authored
  ]
  if (length(relative) == 0L && grepl(".", authored_name, fixed = TRUE)) {
    authored_path <- strsplit(authored_name, ".", fixed = TRUE)[[1]]
    relative <- labels[vapply(
      relations,
      catalog_relation_has_suffix,
      logical(1),
      suffix = authored_path,
      identifier_case = identifier_case
    )]
  }
  if (length(relative) > 1L) {
    catalog_abort_ambiguous_dictionary_table(
      authored_name,
      relative,
      call = call
    )
  }
  if (length(relative) == 1L) relative else NULL
}

catalog_relation_has_suffix <- function(relation, suffix, identifier_case) {
  path <- unname(relation$id@name)
  if (length(suffix) > length(path)) {
    return(FALSE)
  }
  path <- utils::tail(path, length(suffix))
  identical(
    catalog_normalize_identifier(path, identifier_case),
    catalog_normalize_identifier(suffix, identifier_case)
  )
}

catalog_abort_ambiguous_dictionary_table <- function(
  authored_name,
  matches,
  call = rlang::caller_env()
) {
  cli::cli_abort(
    c(
      "Authored table {.val {authored_name}} matches more than one selected
       relation: {.val {matches}}.",
      "i" = "Use its fully qualified name in the data dictionary."
    ),
    call = call
  )
}

catalog_merge_dictionary_table <- function(
  authored,
  authored_name,
  selected_name,
  relation,
  columns,
  identifier_case,
  call = rlang::caller_env()
) {
  authored$description <- catalog_authored_prose(
    authored$description,
    relation$description
  )
  authored$kind <- relation$kind %||% authored$kind
  merged <- catalog_merge_dictionary_columns(
    authored$columns,
    columns,
    identifier_case,
    call = call
  )
  authored$columns <- merged$columns
  if (!identical(authored_name, selected_name)) {
    # Preserve the authored alias for first-touch and relationship matching after re-keying.
    authored$.authored_name <- authored_name
  }

  list(table = authored, column_matches = merged$matches)
}

catalog_merge_dictionary_columns <- function(
  authored,
  discovered,
  identifier_case,
  call = rlang::caller_env()
) {
  out <- lapply(seq_len(nrow(discovered)), function(i) {
    catalog_dictionary_column(discovered, i)
  })
  names(out) <- discovered$column
  matches <- stats::setNames(
    rep(NA_character_, length(authored)),
    names(authored)
  )

  normalized <- catalog_normalize_identifier(names(out), identifier_case)
  for (authored_name in names(authored)) {
    exact <- which(names(out) == authored_name)
    candidates <- if (length(exact) == 1L) {
      exact
    } else {
      which(
        normalized ==
          catalog_normalize_identifier(authored_name, identifier_case)
      )
    }
    if (length(candidates) > 1L) {
      cli::cli_abort(
        "Authored column {.val {authored_name}} matches more than one discovered
         column: {.val {names(out)[candidates]}}.",
        call = call
      )
    }
    if (length(candidates) == 0L) {
      out[[authored_name]] <- authored[[authored_name]]
      next
    }

    discovered_name <- names(out)[[candidates]]
    matches[[authored_name]] <- discovered_name
    column <- utils::modifyList(
      out[[discovered_name]],
      authored[[authored_name]],
      keep.null = TRUE
    )
    column$type <- out[[discovered_name]]$type
    column$nullable <- out[[discovered_name]]$nullable
    column$description <- catalog_authored_prose(
      authored[[authored_name]]$description,
      out[[discovered_name]]$description
    )
    out[[discovered_name]] <- column
  }
  list(columns = out, matches = matches)
}

catalog_dictionary_column <- function(discovered, i) {
  description <- discovered$description[[i]]
  if (is.na(description) || !nzchar(description)) {
    description <- NULL
  }
  list(
    type = discovered$type[[i]],
    nullable = discovered$nullable[[i]],
    description = description
  )
}

catalog_authored_prose <- function(authored, discovered) {
  if (is.null(authored) || !nzchar(authored)) discovered else authored
}

catalog_normalize_identifier <- function(x, identifier_case) {
  switch(identifier_case, upper = toupper(x), lower = tolower(x), x)
}
