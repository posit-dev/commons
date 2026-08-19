new_semantic_model <- function(
  id,
  name,
  description = NULL,
  backend,
  identity = id,
  dimensions = list(),
  metrics = list(),
  facts = list(),
  filters = list(),
  parameters = list(),
  calculations = list(),
  dependencies = list(),
  dependencies_complete = TRUE,
  relationships = list(),
  context = list()
) {
  structure(
    list(
      id = id,
      identity = identity,
      name = name,
      description = description,
      backend = backend,
      dimensions = dimensions,
      metrics = metrics,
      facts = facts,
      filters = filters,
      parameters = parameters,
      calculations = calculations,
      dependencies = dependencies,
      dependencies_complete = dependencies_complete,
      relationships = relationships,
      context = semantic_model_context(context)
    ),
    class = "commons_semantic_model"
  )
}

new_semantic_member <- function(
  name,
  kind,
  parent = NULL,
  label = NULL,
  description = NULL,
  type = NULL,
  synonyms = character(),
  filter = FALSE
) {
  list(
    name = name,
    kind = kind,
    parent = parent,
    label = label,
    description = description,
    type = type,
    synonyms = synonyms,
    filter = filter
  )
}

semantic_model_context <- function(context) {
  first_touch <- unique(as.character(context$first_touch %||% character()))
  retrieval <- unique(as.character(context$retrieval %||% character()))
  list(
    first_touch = first_touch[!is.na(first_touch) & nzchar(first_touch)],
    retrieval = retrieval[!is.na(retrieval) & nzchar(retrieval)]
  )
}

semantic_spec_entries <- function(entries) {
  if (length(entries) == 0L) {
    return(list())
  }
  entries <- lapply(entries, as.list)
  entry_names <- rlang::names2(entries)
  for (i in seq_along(entries)) {
    if (is.null(entries[[i]]$name) && nzchar(entry_names[[i]])) {
      entries[[i]]$name <- entry_names[[i]]
    }
  }
  entries
}

semantic_parameters_from_spec <- function(entries, backend) {
  parameters <- lapply(semantic_spec_entries(entries), function(entry) {
    name <- entry$name
    type <- semantic_parameter_type(entry$data_type %||% entry$type)
    if (!rlang::is_string(name) || !nzchar(name) || is.null(type)) {
      cli::cli_abort(
        "{backend} declares an unsupported semantic parameter."
      )
    }
    default_field <- if (identical(backend, "Snowflake")) {
      "default_value"
    } else {
      "default"
    }
    has_default <- default_field %in% names(entry)
    default <- if (has_default) {
      coerce_semantic_default(entry[[default_field]], type)
    }
    new_typed_argument(
      name,
      type,
      description = entry$description %||% entry$comment,
      default = default,
      has_default = has_default
    )
  })
  names(parameters) <- vapply(parameters, `[[`, character(1), "name")
  if (anyDuplicated(names(parameters))) {
    cli::cli_abort("{backend} semantic parameter names must be unique.")
  }
  parameters
}

coerce_semantic_default <- function(value, type) {
  if (length(value) != 1L || is.list(value) || is.na(value)) {
    return(value)
  }
  switch(
    type,
    string = as.character(value),
    integer = suppressWarnings(as.integer(value)),
    number = suppressWarnings(as.numeric(value)),
    logical = if (is.logical(value)) {
      value
    } else if (tolower(as.character(value)) %in% c("true", "false")) {
      identical(tolower(as.character(value)), "true")
    } else {
      NA
    },
    date = as.character(value),
    datetime = as.character(value)
  )
}

semantic_parameter_type <- function(type) {
  if (!rlang::is_string(type) || !nzchar(type)) {
    return(NULL)
  }
  base <- toupper(sub("\\s*\\(.*$", "", trimws(type)))
  if (base %in% c("STRING", "TEXT", "VARCHAR", "CHAR")) {
    return("string")
  }
  if (base %in% c("BYTEINT", "SMALLINT", "INT", "INTEGER", "BIGINT")) {
    return("integer")
  }
  if (base %in% c(
    "NUMBER", "NUMERIC", "DECIMAL", "FLOAT", "DOUBLE", "REAL"
  )) {
    return("number")
  }
  if (base %in% c("BOOL", "BOOLEAN")) {
    return("logical")
  }
  if (identical(base, "DATE")) {
    return("date")
  }
  if (startsWith(base, "TIMESTAMP") || identical(base, "DATETIME")) {
    return("datetime")
  }
  NULL
}

semantic_models_registry <- function(sources) {
  rows <- list(no_semantic_members)
  parameters <- list()
  source_labels <- rlang::names2(sources)
  for (i in seq_along(sources)) {
    models <- sources[[i]]$semantic_models
    for (model_label in names(models)) {
      model <- models[[model_label]]
      parameters[[semantic_registry_model_key(
        source_labels[[i]],
        model_label
      )]] <- model$parameters %||% list()
      # Standalone filters are context; only filter-labelled members compile.
      members <- c(
        model$dimensions,
        model$metrics,
        Filter(function(member) isTRUE(member$filter), model$facts)
      )
      if (length(members) == 0L) {
        next
      }
      rows[[length(rows) + 1L]] <- semantic_member_rows(
        members,
        model_label,
        source_labels[[i]]
      )
    }
  }
  list(members = do.call(rbind, rows), parameters = parameters)
}

semantic_registry_model_key <- function(source, model) {
  paste(source, model, sep = "\034")
}

no_semantic_members <- data.frame(
  name = character(),
  model = character(),
  source = character(),
  kind = character(),
  parent = character(),
  label = character(),
  description = character(),
  type = character(),
  synonyms = character(),
  filter = logical()
)

semantic_member_rows <- function(members, model, source) {
  data.frame(
    name = vapply(members, `[[`, character(1), "name"),
    model = model,
    source = source,
    kind = vapply(members, `[[`, character(1), "kind"),
    parent = vapply(
      members,
      function(member) member$parent %||% NA_character_,
      character(1)
    ),
    label = vapply(
      members,
      function(member) member$label %||% NA_character_,
      character(1)
    ),
    description = vapply(
      members,
      function(member) member$description %||% NA_character_,
      character(1)
    ),
    type = vapply(
      members,
      function(member) member$type %||% NA_character_,
      character(1)
    ),
    synonyms = vapply(
      members,
      function(member) paste(member$synonyms, collapse = " "),
      character(1)
    ),
    filter = vapply(members, function(member) isTRUE(member$filter), logical(1))
  )
}

semantic_models_in_scope <- function(models, relations) {
  Filter(
    function(model) semantic_model_in_scope(model, relations),
    models
  )
}

semantic_model_identity_key <- function(model) {
  semantic_id_key(model$identity %||% model$id, model$backend)
}

semantic_association_seed <- function(relation) {
  identity <- relation$identity
  !is.null(relation$kind) &&
    inherits(identity, "Id") &&
    identical(names(identity@name), c("catalog", "schema", "table")) &&
    all(!is.na(identity@name) & nzchar(identity@name))
}

semantic_model_in_scope <- function(model, relations) {
  if (!isTRUE(model$dependencies_complete) || length(model$dependencies) == 0L) {
    return(FALSE)
  }
  selected <- vapply(
    relations,
    function(relation) {
      semantic_id_key(
        relation$identity %||% relation$id,
        model$backend
      )
    },
    character(1)
  )
  dependencies <- vapply(
    model$dependencies,
    semantic_id_key,
    character(1),
    backend = model$backend
  )
  all(dependencies %in% selected)
}

semantic_id_key <- function(id, backend) {
  values <- unname(id@name)
  if (identical(backend, "databricks_metric_view")) {
    values <- tolower(values)
  }
  paste(names(id@name), values, sep = "=", collapse = "\034")
}

semantic_members_context <- function(members, heading) {
  if (length(members) == 0L) {
    return(character())
  }
  entries <- vapply(members, function(member) {
    parent <- member$parent %||% ""
    reference <- paste(
      c(parent, member$name)[nzchar(c(parent, member$name))],
      collapse = "."
    )
    detail <- member$description %||% member$label
    if (is.null(detail) || is.na(detail) || !nzchar(detail)) {
      detail <- NULL
    }
    paste0(
      "- `", reference, "`",
      if (!is.null(detail)) paste0(": ", detail),
      if (isTRUE(member$filter)) " (usable as a named filter)"
    )
  }, character(1))
  paste(c(paste0(heading, ":"), entries), collapse = "\n")
}

semantic_model_first_touch <- function(source, table) {
  relation <- source_relation(source, table)
  if (is.null(relation)) {
    return(character())
  }
  Filter(
    nzchar,
    unique(unlist(lapply(source$semantic_models, function(model) {
      if (semantic_model_depends_on(model, relation)) {
        model$context$first_touch
      } else {
        character()
      }
    }), use.names = FALSE))
  )
}

semantic_model_depends_on <- function(model, relation) {
  relation_key <- semantic_id_key(
    relation$identity %||% relation$id,
    model$backend
  )
  dependency_keys <- vapply(
    model$dependencies,
    semantic_id_key,
    character(1),
    backend = model$backend
  )
  relation_key %in% dependency_keys
}

registry_semantic_members <- function(registry, source = NULL) {
  members <- registry$members
  if (is.null(source)) {
    return(members)
  }
  members[members$source == source, , drop = FALSE]
}

registry_semantic_parameters <- function(registry, member) {
  registry$parameters[[semantic_registry_model_key(
    member$source[[1]],
    member$model[[1]]
  )]] %||% list()
}

semantic_registry_has_metrics <- function(registry) {
  any(registry$members$kind == "metric")
}

semantic_member_aliases <- function(member) {
  parent <- member$parent[[1]]
  parent <- if (is.na(parent) || !nzchar(parent)) NULL else parent
  unique(c(
    member$name[[1]],
    if (!is.null(parent)) paste(parent, member$name[[1]], sep = "."),
    paste(member$model[[1]], member$name[[1]], sep = "::"),
    if (!is.null(parent)) {
      paste(
        member$model[[1]],
        paste(parent, member$name[[1]], sep = "."),
        sep = "::"
      )
    }
  ))
}

semantic_member_key <- function(member) {
  utils::tail(semantic_member_aliases(member), 1L)
}

semantic_member_candidates <- function(name, members) {
  if (nrow(members) == 0L) {
    return(members)
  }
  aliases <- lapply(seq_len(nrow(members)), function(i) {
    semantic_member_aliases(members[i, , drop = FALSE])
  })
  members[
    vapply(aliases, function(candidate) name %in% candidate, logical(1)),
    ,
    drop = FALSE
  ]
}

resolve_semantic_members <- function(
  names,
  members,
  kind,
  call = rlang::caller_env()
) {
  out <- members[0, , drop = FALSE]
  for (name in strip_token_braces(names %||% character())) {
    out <- rbind(
      out,
      resolve_semantic_member(name, members, kind, call = call)
    )
  }
  out
}

resolve_semantic_filters <- function(
  names,
  members,
  call = rlang::caller_env()
) {
  filters <- members[members$filter %in% TRUE, , drop = FALSE]
  filters$kind <- rep("filter", nrow(filters))
  resolve_semantic_members(names, filters, "filter", call = call)
}

resolve_semantic_member <- function(
  name,
  members,
  kind,
  call = rlang::caller_env()
) {
  named <- semantic_member_candidates(name, members)
  matched <- named[named$kind %in% kind, , drop = FALSE]
  if (nrow(matched) == 1L) {
    return(matched)
  }
  if (nrow(matched) > 1L) {
    choices <- vapply(seq_len(nrow(matched)), function(i) {
      semantic_member_key(matched[i, , drop = FALSE])
    }, character(1))
    cli::cli_abort(
      c(
        "Native semantic name {.val {name}} is ambiguous.",
        "i" = "Use a qualified name: {.val {unique(choices)}}."
      ),
      call = call
    )
  }
  if (nrow(named)) {
    cli::cli_abort(
      "{.val {name}} is a native {named$kind[[1]]}, not a {kind}.",
      call = call
    )
  }
  available <- members$name[members$kind %in% kind]
  cli::cli_abort(
    c(
      "No native semantic {kind} is named {.val {name}}.",
      "i" = "Available {kind}s: {.val {available}}."
    ),
    call = call
  )
}

semantic_where_conditions <- function(
  where,
  members,
  con,
  member_references,
  call = rlang::caller_env()
) {
  vapply(normalize_where(where), function(triple) {
    for (field in c("column", "op", "value")) {
      value <- triple[[field]]
      if (length(value) != 1L || is.na(value) || !nzchar(as.character(value))) {
        cli::cli_abort(
          "Each {.arg where} entry needs {.field column}, {.field op}, and {.field value}.",
          call = call
        )
      }
      triple[[field]] <- as.character(value)
    }
    if (!triple$op %in% where_ops) {
      cli::cli_abort(
        "{.arg where} operator must be one of {.val {where_ops}}, not {.val {triple$op}}.",
        call = call
      )
    }
    dimension <- resolve_semantic_member(
      triple$column,
      members,
      "dimension",
      call = call
    )
    reference <- member_references(dimension, con)
    value <- if (grepl("^-?[0-9]+(\\.[0-9]+)?$", triple$value)) {
      triple$value
    } else {
      as.character(DBI::dbQuoteString(con, triple$value))
    }
    sprintf("(%s %s %s)", reference, triple$op, value)
  }, character(1))
}

semantic_member_pool_text <- function(
  member,
  members,
  source_names = character(),
  parameters = list()
) {
  reference <- if (nrow(semantic_member_candidates(member$name[[1]], members)) == 1L) {
    member$name[[1]]
  } else {
    semantic_member_key(member)
  }
  detail <- prose_detail(member$description[[1]], NA_character_)
  paste(
    c(
      sprintf(
        "### %s --- native %s on semantic model `%s`\n%s",
        reference,
        member$kind[[1]],
        member$model[[1]],
        detail
      ),
      semantic_member_sources_line(member, source_names),
      semantic_parameters_pool_text(parameters),
      switch(
        member$kind[[1]],
        metric = sprintf(
          "Query with call_metrics (metrics = [\"%s\"]).",
          reference
        ),
        dimension = sprintf(
          "Use as a call_metrics dimension: %s.",
          reference
        ),
        NULL
      ),
      if (isTRUE(member$filter[[1]])) {
        sprintf("May be applied as a call_metrics filter: %s.", reference)
      }
    ),
    collapse = "\n"
  )
}

semantic_parameters_pool_text <- function(parameters) {
  if (length(parameters) == 0L) {
    return(NULL)
  }
  entries <- vapply(parameters, function(parameter) {
    default <- if (parameter$has_default) {
      paste0(", optional; default: ", parameter$default)
    } else {
      ", required"
    }
    description <- if (
      !is.null(parameter$description) && nzchar(parameter$description)
    ) {
      paste0(": ", parameter$description)
    } else {
      ""
    }
    paste0(
      "`", parameter$name, "` (", parameter$type, default, ")", description
    )
  }, character(1))
  paste0(
    "call_metrics arguments JSON: ",
    paste(entries, collapse = ", "),
    "."
  )
}

semantic_member_sources_line <- function(member, source_names) {
  source <- member$source[[1]]
  if (!source %in% source_names) {
    return(NULL)
  }
  sprintf("sources: %s", source)
}
