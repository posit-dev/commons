catalog_merge <- function(
  discovered,
  authored,
  relation_ids = names(discovered$relations),
  call = rlang::caller_env()
) {
  validate_commons_catalog(discovered, call = call)
  validate_commons_catalog(authored, call = call)
  candidates <- discovered
  candidates$relations <- candidates$relations[relation_ids]
  authored <- catalog_scope_authored(authored, candidates)

  reconciled <- catalog_reconcile_relations(
    discovered,
    authored,
    call,
    relation_ids
  )
  relation_map <- reconciled$map
  authored <- catalog_remap_catalog(authored, relation_map)

  new_commons_catalog(
    sources = catalog_combine_records(
      discovered$sources,
      authored$sources,
      "source",
      call
    ),
    relations = catalog_combine_records(
      reconciled$relations,
      list(),
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

catalog_scope_authored <- function(authored, discovered) {
  relation_names <- vapply(
    authored$relations,
    `[[`,
    character(1),
    "name"
  )
  keep_relations <- names(authored$relations)[vapply(
    authored$relations,
    function(relation) {
      length(catalog_relation_candidates(
        relation,
        discovered$relations,
        discovered$sources
      )) > 0
    },
    logical(1)
  )]
  dropped_relations <- setdiff(names(authored$relations), keep_relations)
  dropped_relation_names <- unname(relation_names[dropped_relations])
  authored$relations <- authored$relations[keep_relations]
  authored$relations <- lapply(
    authored$relations,
    catalog_scope_relation_constraints,
    dropped_relation_ids = dropped_relations,
    dropped_relation_names = dropped_relation_names
  )

  keep_models <- logical(length(authored$models))
  names(keep_models) <- names(authored$models)
  for (id in names(authored$models)) {
    model <- authored$models[[id]]
    for (field in c("datasets", "exposed", "dependencies")) {
      model[[field]] <- setdiff(model[[field]], dropped_relations)
    }
    dataset_names <- vapply(
      authored$relations[model$datasets],
      `[[`,
      character(1),
      "name"
    )
    keep_relationships <- vapply(
      model$relationships,
      catalog_relationship_in_scope,
      logical(1),
      dataset_names = dataset_names,
      dropped_dataset_names = dropped_relation_names
    )
    model$relationships <- model$relationships[keep_relationships]
    keep_models[[id]] <- length(model$datasets) > 0 || length(model$exposed) > 0
    authored$models[[id]] <- model
  }
  dropped_models <- names(keep_models)[!keep_models]
  authored$models <- authored$models[keep_models]

  keep_definitions <- vapply(authored$definitions, function(definition) {
    definition$relation_id %in% keep_relations &&
      definition$model_id %in% names(authored$models) &&
      !any(definition$dependencies %in% c(dropped_relations, dropped_models))
  }, logical(1))
  dropped_definitions <- names(authored$definitions)[!keep_definitions]
  authored$definitions <- authored$definitions[keep_definitions]

  authored$calculations <- Filter(function(calculation) {
    !any(calculation$dependencies %in% c(
      dropped_relations,
      dropped_models,
      dropped_definitions
    ))
  }, authored$calculations)
  dropped <- c(dropped_relations, dropped_models, dropped_definitions)
  authored$context <- Filter(function(context) {
    !any(context$scope %in% dropped) &&
      catalog_relationship_context_in_scope(context, authored)
  }, authored$context)
  validate_commons_catalog(authored)
  authored
}

catalog_relationship_context_in_scope <- function(context, catalog) {
  relationship <- context$extensions$ossie_relationship
  if (is.null(relationship)) return(TRUE)
  model_ids <- intersect(context$scope, names(catalog$models))
  if (length(model_ids) != 1) return(FALSE)
  model <- catalog$models[[model_ids[[1]]]]
  dataset_names <- vapply(
    catalog$relations[model$datasets],
    `[[`,
    character(1),
    "name"
  )
  all(c(relationship$from, relationship$to) %in% dataset_names)
}

catalog_scope_relation_constraints <- function(
  relation,
  dropped_relation_ids,
  dropped_relation_names
) {
  keep <- vapply(relation$constraints, function(constraint) {
    reference <- constraint$reference
    if (is.null(reference)) return(TRUE)
    !any(reference$relation_id %in% dropped_relation_ids) &&
      !any(reference$table %in% dropped_relation_names)
  }, logical(1))
  relation$constraints <- relation$constraints[keep]
  relation
}

catalog_relationship_in_scope <- function(
  relationship,
  dataset_names,
  dropped_dataset_names
) {
  endpoints <- unlist(c(relationship$from, relationship$to), use.names = FALSE)
  if (length(endpoints)) {
    return(all(endpoints %in% dataset_names))
  }
  text <- paste(unlist(
    relationship[c("join", "condition", "sql")],
    use.names = FALSE
  ), collapse = " ")
  !any(vapply(dropped_dataset_names, function(name) {
    pattern <- paste0(
      "(?<![[:alnum:]_$])",
      escape_regex(name),
      "(?![[:alnum:]_$])"
    )
    grepl(pattern, text, ignore.case = TRUE, perl = TRUE)
  }, logical(1)))
}

catalog_reconcile_relations <- function(
  discovered,
  authored,
  call,
  relation_ids = names(discovered$relations)
) {
  relations <- discovered$relations
  relation_map <- character()
  claimed <- character()

  for (relation in authored$relations) {
    candidates <- catalog_relation_candidates(
      relation,
      discovered$relations[relation_ids],
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
  discovered <- Filter(
    function(relation) !identical(relation$access$state, "visible_only"),
    discovered
  )
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
