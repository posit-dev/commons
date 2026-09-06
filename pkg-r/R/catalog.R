catalog_table_registry <- function(
  con,
  tables,
  current_namespace,
  id_type,
  exact_relation,
  list_relations,
  exclude = NULL,
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
  namespace_selected <- FALSE
  for (id in ids) {
    type <- id_type(id, call = call)
    if (identical(type, "relation")) {
      relation <- exact_relation(con, id, call = call)
      relations[[length(relations) + 1L]] <- relation
      # Keyed by the relation's own id rather than the authored one: an entry
      # naming a bare table is qualified with the connection's namespace once
      # the warehouse answers, and the two lists have to agree on the label
      # or the access check cannot pair them up.
      validate[[length(validate) + 1L]] <- relation$id
      next
    }
    namespace_selected <- TRUE
    relations <- c(relations, list_relations(con, id, call = call))
  }

  keep <- !catalog_excluded(
    vapply(relations, catalog_relation_name, character(1)),
    exclude
  )
  relations <- relations[keep]
  validate <- Filter(
    function(id) !catalog_excluded(id@name[["table"]], exclude),
    validate
  )
  catalog_check_object_limit(length(relations), call = call)

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
    validate = list(labels = validate_labels, ids = validate),
    namespace_selected = namespace_selected
  )
}

catalog_check_object_limit <- function(n, call = rlang::caller_env()) {
  if (n > catalog_object_limit) {
    cli::cli_abort(c(
      "The selection resolves to {n} objects, above the supported limit of {catalog_object_limit}.",
      i = "Narrow {.arg tables} to fewer catalog or schema prefixes."
    ), call = call)
  }
  invisible(n)
}

catalog_object_limit <- 25000L

catalog_prompt_limit <- 3000L

new_catalog_manifest <- function(
  relations,
  namespace_selected = FALSE,
  semantic_stubs = list()
) {
  if (is.null(relations) && length(semantic_stubs) == 0L) {
    return(NULL)
  }
  manifest <- new.env(parent = emptyenv())
  manifest$relations <- relations
  manifest$objects <- c(relations %||% list(), semantic_stubs)
  manifest$access <- stats::setNames(rep("unknown", length(relations)), names(relations))
  manifest$access_errors <- list()
  labels <- names(manifest$objects)
  manifest$searchable <- isTRUE(namespace_selected) &&
    nchar(paste(labels, collapse = "\n"), type = "bytes") >
      catalog_prompt_limit
  manifest
}

catalog_searchable <- function(source) {
  source_state <- data_source_state(source)
  !is.null(source_state$manifest) && isTRUE(source_state$manifest$searchable)
}

catalog_search <- function(source, query, kinds = NULL, limit = 10L) {
  source_state <- data_source_state(source)
  catalog_check_session(source)
  rlang::check_string(query)
  rlang::check_number_whole(limit, min = 1)
  relations <- source_state$manifest$objects %||% list()
  if (!is.null(kinds)) {
    if (!is.character(kinds) || anyNA(kinds)) {
      cli::cli_abort(
        "{.arg kinds} must be a character vector without missing values."
      )
    }
    relations <- Filter(function(relation) relation$kind %in% kinds, relations)
  }
  query_terms <- catalog_search_terms(query)
  if (length(query_terms) == 0L || length(relations) == 0L) {
    return(list())
  }
  relation_labels <- rlang::names2(relations)
  scores <- vapply(seq_along(relations), function(i) {
    relation <- relations[[i]]
    text <- paste(
      relation_labels[[i]],
      catalog_relation_name(relation),
      relation$description %||% ""
    )
    terms <- catalog_search_terms(text)
    sum(query_terms %in% terms) + sum(vapply(
      query_terms,
      grepl,
      logical(1),
      x = tolower(text),
      fixed = TRUE
    ))
  }, numeric(1))
  keep <- scores > 0
  relations <- relations[keep]
  scores <- scores[keep]
  relations <- relations[order(scores, decreasing = TRUE)]
  if (!is.null(source_state$session)) {
    relations <- catalog_search_queryable(source, relations, limit)
  }
  utils::head(relations, limit)
}

catalog_search_queryable <- function(source, relations, limit) {
  source_state <- data_source_state(source)
  results <- list()
  candidates <- utils::head(relations, catalog_search_probe_limit)
  for (label in names(candidates)) {
    if (!is.null(source_state$semantic_stubs[[label]])) {
      results[[label]] <- candidates[[label]]
      if (length(results) >= limit) {
        break
      }
      next
    }
    queryable <- tryCatch(
      {
        catalog_ensure_queryable(source, label)
        TRUE
      },
      commons_catalog_authorization_error = function(err) FALSE
    )
    if (queryable) {
      results[[label]] <- candidates[[label]]
    }
    if (length(results) >= limit) {
      break
    }
  }
  results
}

# Bound zero-row checks when many high-ranking metadata matches are unauthorized.
catalog_search_probe_limit <- 100L

catalog_search_terms <- function(x) {
  text <- tolower(paste(x %||% "", collapse = " "))
  unique(Filter(
    nzchar,
    strsplit(gsub("[^[:alnum:]_]+", " ", text), " +")[[1]]
  ))
}

catalog_relation_name <- function(relation) {
  unname(relation$id@name[["table"]])
}

catalog_excluded <- function(names, patterns) {
  if (length(patterns) == 0L) {
    return(rep(FALSE, length(names)))
  }
  Reduce(`|`, lapply(patterns, function(pattern) {
    grepl(catalog_glob_regex(pattern), names)
  }))
}

catalog_glob_regex <- function(pattern) {
  escaped <- gsub("([][{}()+.^$|\\\\])", "\\\\\\1", pattern)
  escaped <- gsub("\\*", ".*", escaped)
  escaped <- gsub("\\?", ".", escaped)
  paste0("^", escaped, "$")
}

check_catalog_exclude <- function(exclude, call = rlang::caller_env()) {
  if (
    !is.null(exclude) &&
      (!is.character(exclude) || anyNA(exclude) || any(!nzchar(exclude)))
  ) {
    cli::cli_abort(
      "{.arg exclude} must contain non-empty glob patterns without missing values.",
      call = call
    )
  }
  invisible(exclude)
}

catalog_check_nonempty <- function(registry, call = rlang::caller_env()) {
  if (
    length(registry$labels) == 0L &&
      length(registry$semantic_models) == 0L &&
      length(registry$semantic_stubs) == 0L
  ) {
    cli::cli_abort(
      "The resolved catalog selection contains no objects.",
      call = call
    )
  }
  registry
}

catalog_exclude_semantic_models <- function(models, exclude) {
  keep <- !catalog_excluded(
    vapply(models, function(model) {
      catalog_relation_name(list(id = model$identity %||% model$id))
    }, character(1)),
    exclude
  )
  models[keep]
}

catalog_exclude_relations <- function(registry, labels) {
  registry$labels <- setdiff(registry$labels, labels)
  registry$ids <- registry$ids[registry$labels]
  registry$relations <- registry$relations[registry$labels]

  validate_labels <- setdiff(registry$validate$labels, labels)
  registry$validate$labels <- validate_labels
  registry$validate$ids <- registry$validate$ids[validate_labels]
  registry
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

# `requested` is the authored name qualified with the namespace the lookup
# ran in, and becomes the relation's label once the warehouse confirms it.
# The warehouse's own id is kept as `identity`, since it carries that
# backend's casing and is what later metadata queries have to name.
catalog_match_exact_relation <- function(relations, id, requested = id) {
  requested_name <- id@name[["table"]]
  is_requested <- vapply(
    relations,
    function(relation) {
      identical(relation$id@name[["table"]], requested_name)
    },
    logical(1)
  )
  if (!any(is_requested)) {
    return(list(
      id = id,
      kind = NULL,
      description = NULL,
      discovered = FALSE
    ))
  }

  relation <- relations[[which(is_requested)[[1]]]]
  relation$identity <- relation$id
  # A relation the warehouse reports without a namespace has none to be
  # labelled with, and none to be queried under either: a Databricks
  # temporary view answers only to its bare name.
  if (any(c("catalog", "schema") %in% names(relation$identity@name))) {
    relation$id <- requested
  }
  relation$discovered <- TRUE
  relation
}

catalog_merge_dictionary <- function(
  dictionary,
  relations,
  con,
  describe_relation,
  identifier_case,
  access_check = NULL,
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
    if (!is.null(access_check)) {
      access_check(con, relation$id, label, call = call)
    }
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
