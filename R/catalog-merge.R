catalog_merge <- function(discovered, authored, call = rlang::caller_env()) {
  validate_commons_catalog(discovered, call = call)
  validate_commons_catalog(authored, call = call)

  reconciled <- catalog_reconcile_relations(discovered, authored, call)
  relation_map <- reconciled$map
  authored <- catalog_remap_catalog(authored, relation_map)
  retained_authored <- authored$relations[setdiff(
    names(authored$relations),
    names(relation_map)
  )]

  new_commons_catalog(
    sources = catalog_combine_records(
      discovered$sources,
      authored$sources,
      "source",
      call
    ),
    relations = catalog_combine_records(
      reconciled$relations,
      retained_authored,
      "relation",
      call
    ),
    models = catalog_combine_records(
      discovered$models,
      authored$models,
      "model",
      call
    ),
    definitions = catalog_combine_records(
      discovered$definitions,
      authored$definitions,
      "definition",
      call
    ),
    calculations = catalog_combine_records(
      discovered$calculations,
      authored$calculations,
      "calculation",
      call
    ),
    terms = catalog_combine_records(
      discovered$terms,
      authored$terms,
      "term",
      call
    ),
    context = catalog_combine_records(
      discovered$context,
      authored$context,
      "context",
      call
    ),
    diagnostics = c(discovered$diagnostics, authored$diagnostics),
    provider = discovered$provider %||% authored$provider,
    call = call
  )
}

catalog_reconcile_relations <- function(discovered, authored, call) {
  relations <- discovered$relations
  relation_map <- character()
  claimed <- character()

  for (relation in authored$relations) {
    candidates <- catalog_relation_candidates(
      relation,
      discovered$relations,
      discovered$sources
    )
    if (length(candidates) == 0) {
      next
    }
    if (length(candidates) > 1) {
      paths <- vapply(
        discovered$relations[candidates],
        catalog_path_label,
        character(1)
      )
      cli::cli_abort(
        "Authored relation {.val {catalog_path_label(relation)}} is ambiguous; it matches {.val {paths}}.",
        call = call
      )
    }

    candidate_id <- candidates[[1]]
    if (candidate_id %in% claimed) {
      cli::cli_abort(
        "Multiple authored relations match discovered relation {.val {catalog_path_label(discovered$relations[[candidate_id]])}}.",
        call = call
      )
    }
    claimed <- c(claimed, candidate_id)
    relation_map[[relation$id]] <- candidate_id
    relations[[candidate_id]] <- catalog_merge_relation(
      relations[[candidate_id]],
      relation,
      discovered$sources[[relations[[candidate_id]]$source_id]],
      call
    )
  }

  list(relations = relations, map = relation_map)
}

catalog_relation_candidates <- function(authored, discovered, sources) {
  if (length(discovered) == 0) {
    return(character())
  }
  ids <- names(discovered)
  matched <- vapply(discovered, function(candidate) {
    source <- sources[[candidate$source_id]]
    catalog_relation_matches(authored, candidate, source$identifier_case)
  }, logical(1))
  ids[matched]
}

catalog_relation_matches <- function(authored, discovered, identifier_case) {
  authored_path <- catalog_normalize_identifiers(
    authored$path$components,
    identifier_case
  )
  discovered_path <- catalog_normalize_identifiers(
    discovered$path$components,
    identifier_case
  )

  if (length(authored_path) > 1) {
    if (length(authored_path) > length(discovered_path)) {
      return(FALSE)
    }
    offset <- length(discovered_path) - length(authored_path)
    return(identical(authored_path, discovered_path[seq_along(authored_path) + offset]))
  }

  authored_names <- catalog_normalize_identifiers(
    c(authored$name, authored$aliases, authored_path),
    identifier_case
  )
  discovered_name <- utils::tail(discovered_path, 1)
  discovered_name %in% authored_names
}

catalog_normalize_identifiers <- function(x, identifier_case) {
  switch(
    identifier_case,
    upper = toupper(x),
    lower = tolower(x),
    preserve = x
  )
}

catalog_merge_relation <- function(discovered, authored, source, call) {
  columns <- catalog_merge_columns(
    discovered$columns,
    authored$columns,
    source$identifier_case,
    call
  )
  scalar_fields <- c("label", "description", "details")
  fields <- discovered
  for (field in scalar_fields) {
    fields[[field]] <- catalog_authored_value(authored[[field]], discovered[[field]])
  }
  fields$aliases <- unique(c(
    discovered$aliases,
    authored$aliases,
    if (!identical(discovered$name, authored$name)) authored$name
  ))
  fields$tags <- unique(c(discovered$tags, authored$tags))
  fields$synonyms <- unique(c(discovered$synonyms, authored$synonyms))
  fields$columns <- columns
  fields$constraints <- c(discovered$constraints, authored$constraints)
  fields$field_provenance <- catalog_merge_field_provenance(
    discovered,
    authored,
    scalar_fields,
    c("aliases", "tags", "synonyms")
  )
  fields$extensions <- utils::modifyList(
    discovered$extensions,
    authored$extensions,
    keep.null = TRUE
  )
  structure(fields, class = class(discovered))
}

catalog_merge_columns <- function(discovered, authored, identifier_case, call) {
  out <- discovered
  normalized <- catalog_normalize_identifiers(names(discovered), identifier_case)

  for (column in authored) {
    name <- catalog_normalize_identifiers(column$name, identifier_case)
    candidates <- which(normalized == name)
    if (length(candidates) > 1) {
      cli::cli_abort(
        "Authored column {.val {column$name}} ambiguously matches discovered columns {.val {names(discovered)[candidates]}}.",
        call = call
      )
    }
    if (length(candidates) == 0) {
      out[[column$name]] <- column
      next
    }
    discovered_name <- names(discovered)[candidates]
    out[[discovered_name]] <- catalog_merge_column(
      discovered[[discovered_name]],
      column
    )
  }
  out
}

catalog_merge_column <- function(discovered, authored) {
  fields <- discovered
  scalar_fields <- c(
    "logical_type",
    "description",
    "details",
    "units",
    "values",
    "range",
    "examples",
    "display"
  )
  for (field in scalar_fields) {
    fields[[field]] <- catalog_authored_value(authored[[field]], discovered[[field]])
  }
  fields$restrictions <- unique(c(discovered$restrictions, authored$restrictions))
  fields$tags <- unique(c(discovered$tags, authored$tags))
  fields$field_provenance <- catalog_merge_field_provenance(
    discovered,
    authored,
    scalar_fields,
    c("restrictions", "tags")
  )
  fields$extensions <- utils::modifyList(
    discovered$extensions,
    authored$extensions,
    keep.null = TRUE
  )
  structure(fields, class = class(discovered))
}

catalog_authored_value <- function(authored, discovered) {
  if (is.null(authored) || length(authored) == 0) discovered else authored
}

catalog_merge_field_provenance <- function(
  discovered,
  authored,
  scalar_fields,
  additive_fields
) {
  out <- discovered$field_provenance
  for (field in scalar_fields) {
    if (!is.null(authored[[field]]) && length(authored[[field]])) {
      out[[field]] <- authored$field_provenance[[field]] %||% authored$provenance
    }
  }
  for (field in additive_fields) {
    out[[field]] <- Filter(Negate(is.null), list(
      discovered$field_provenance[[field]] %||% discovered$provenance,
      authored$field_provenance[[field]] %||% authored$provenance
    ))
  }
  out
}

catalog_remap_catalog <- function(catalog, relation_map) {
  if (length(relation_map) == 0) {
    return(catalog)
  }
  catalog$models <- lapply(catalog$models, catalog_remap_model, relation_map)
  names(catalog$models) <- vapply(catalog$models, `[[`, character(1), "id")
  catalog$definitions <- lapply(
    catalog$definitions,
    catalog_remap_definition,
    relation_map
  )
  names(catalog$definitions) <- vapply(
    catalog$definitions,
    `[[`,
    character(1),
    "id"
  )
  catalog$calculations <- lapply(
    catalog$calculations,
    catalog_remap_dependencies,
    relation_map
  )
  names(catalog$calculations) <- vapply(
    catalog$calculations,
    `[[`,
    character(1),
    "id"
  )
  catalog$context <- lapply(catalog$context, catalog_remap_context, relation_map)
  names(catalog$context) <- vapply(catalog$context, `[[`, character(1), "id")
  catalog
}

catalog_remap_model <- function(model, relation_map) {
  for (field in c("datasets", "exposed", "dependencies")) {
    model[[field]] <- catalog_remap_ids(model[[field]], relation_map)
  }
  model
}

catalog_remap_definition <- function(definition, relation_map) {
  definition$relation_id <- catalog_remap_ids(
    definition$relation_id,
    relation_map
  )
  definition$dependencies <- catalog_remap_ids(
    definition$dependencies,
    relation_map
  )
  definition
}

catalog_remap_dependencies <- function(record, relation_map) {
  record$dependencies <- catalog_remap_ids(record$dependencies, relation_map)
  record
}

catalog_remap_context <- function(context, relation_map) {
  context$scope <- catalog_remap_ids(context$scope, relation_map)
  context
}

catalog_remap_ids <- function(ids, relation_map) {
  mapped <- unname(relation_map[ids])
  replace <- !is.na(mapped)
  ids[replace] <- mapped[replace]
  unique(ids)
}

catalog_combine_records <- function(x, y, what, call) {
  collisions <- intersect(names(x), names(y))
  if (length(collisions)) {
    cli::cli_abort(
      "Discovered and authored catalogs have conflicting {what} IDs: {.val {collisions}}.",
      call = call
    )
  }
  c(x, y)
}

catalog_path_label <- function(relation) {
  paste(relation$path$components, collapse = ".")
}
