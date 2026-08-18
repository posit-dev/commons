new_semantic_model <- function(
  id,
  name,
  description = NULL,
  backend,
  dimensions = list(),
  metrics = list()
) {
  structure(
    list(
      id = id,
      name = name,
      description = description,
      backend = backend,
      dimensions = dimensions,
      metrics = metrics
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
  synonyms = character()
) {
  list(
    name = name,
    kind = kind,
    parent = parent,
    label = label,
    description = description,
    type = type,
    synonyms = synonyms
  )
}

semantic_models_registry <- function(sources) {
  rows <- list(no_semantic_members)
  source_labels <- rlang::names2(sources)
  for (i in seq_along(sources)) {
    models <- sources[[i]]$semantic_models
    for (model_label in names(models)) {
      model <- models[[model_label]]
      members <- c(model$dimensions, model$metrics)
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
  list(members = do.call(rbind, rows))
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
  synonyms = character()
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
    )
  )
}

registry_semantic_members <- function(registry, source = NULL) {
  members <- registry$members
  if (is.null(source)) {
    return(members)
  }
  members[members$source == source, , drop = FALSE]
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

semantic_member_pool_text <- function(
  member,
  members,
  source_names = character()
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
      if (identical(member$kind[[1]], "metric")) {
        sprintf("Query with call_metrics (metrics = [\"%s\"]).", reference)
      } else {
        sprintf("Use as a call_metrics dimension: %s.", reference)
      }
    ),
    collapse = "\n"
  )
}

semantic_member_sources_line <- function(member, source_names) {
  source <- member$source[[1]]
  if (!source %in% source_names) {
    return(NULL)
  }
  sprintf("sources: %s", source)
}
