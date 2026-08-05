#' Create a context layer
#'
#' A context layer contains text that helps a [commons()] agent interpret its
#' data source.
#'
#' Files are chunked and indexed with \pkg{ragnar} when the agent first
#' searches its context. Facts that should be in every prompt belong in the
#' `system_prompt` passed to [commons()], not here.
#'
#' @param files Character vector of paths to text/markdown files to index.
#'
#' @return A `commons_context_layer` object.
#'
#' @examples
#' path <- tempfile(fileext = ".md")
#' writeLines("Revenue excludes tax unless stated otherwise.", path)
#' layer <- context_layer(files = path)
#'
#' @export
context_layer <- function(files = character()) {
  if (!is.character(files)) {
    cli::cli_abort("{.arg files} must be a character vector.")
  }

  # Read eagerly so a bad path fails at construction; index lazily (see
  # context_store()).
  docs <- character(0)
  metadata <- list()
  for (path in files) {
    md <- strip_frontmatter(paste(readLines(path, warn = FALSE), collapse = "\n"))
    if (nzchar(trimws(md))) {
      docs <- c(docs, md)
      metadata <- c(metadata, list(list(list(
        kind = "file",
        path = normalizePath(path, mustWork = FALSE)
      ))))
    }
  }

  new_context_layer(docs, metadata = metadata)
}

# Dictionary prose doubles as searchable context, inserted at natural YAML
# boundaries (one chunk per glossary term, per table's prose, and for the
# dataset details) so retrieval returns coherent units. Column-level content
# stays out of the store: first touch owns it, and indexing it would pay for
# a second copy the agent already has.
augment_context_layer <- function(context_layer, sources) {
  labels <- rlang::names2(sources)
  chunks <- character()
  chunk_sources <- list()
  chunk_metadata <- list()
  for (i in seq_along(sources)) {
    source <- sources[[i]]
    label <- labels[[i]]
    dictionary <- source_runtime_dictionary(source)
    dictionary_chunks <- dictionary_context_chunks(dictionary)
    catalog <- source$provider$catalog %||% source$catalog
    records <- if (inherits(catalog, "commons_catalog")) {
      Filter(
        function(record) identical(record$delivery, "retrieval"),
        catalog$context
      )
    } else {
      list()
    }
    catalog_chunks <- vapply(records, `[[`, character(1), "text")
    one <- c(dictionary_chunks, catalog_chunks)
    chunks <- c(chunks, one)
    scope <- if (nzchar(label)) label else character()
    chunk_sources <- c(chunk_sources, rep(list(scope), length(one)))
    chunk_metadata <- c(
      chunk_metadata,
      lapply(dictionary_chunks, function(x) {
        list(list(kind = "data_dictionary", source = label))
      }),
      lapply(records, function(record) {
        list(list(
          id = record$id,
          kind = record$kind,
          scope = record$scope,
          authority = record$authority,
          provenance = record$provenance
        ))
      })
    )
  }
  if (length(chunks) == 0) {
    return(context_layer)
  }

  layer <- context_layer %||% context_layer()
  context_layer_merge(
    layer$docs,
    layer$sources,
    layer$metadata,
    chunks,
    chunk_sources,
    chunk_metadata
  )
}

new_context_layer <- function(
  docs,
  sources = rep(list(character()), length(docs)),
  metadata = rep(list(list()), length(docs))
) {
  if (!is.list(sources)) {
    sources <- lapply(sources, function(source) {
      if (is.na(source) || !nzchar(source)) character() else source
    })
  }
  structure(
    list(
      docs = docs,
      sources = sources,
      metadata = metadata,
      cache = new.env(parent = emptyenv())
    ),
    class = "commons_context_layer"
  )
}

context_layer_merge <- function(
  docs,
  sources,
  metadata,
  new_docs,
  new_sources,
  new_metadata
) {
  for (i in seq_along(new_docs)) {
    hit <- match(new_docs[[i]], docs)
    if (is.na(hit)) {
      docs <- c(docs, new_docs[[i]])
      sources <- c(sources, list(new_sources[[i]]))
      metadata <- c(metadata, list(new_metadata[[i]]))
    } else {
      sources[[hit]] <- unique(c(sources[[hit]], new_sources[[i]]))
      metadata[[hit]] <- context_metadata_merge(
        metadata[[hit]],
        new_metadata[[i]]
      )
    }
  }
  new_context_layer(docs, sources, metadata)
}

context_metadata_merge <- function(x, y) {
  for (item in y) {
    if (!any(vapply(x, identical, logical(1), item))) {
      x[[length(x) + 1]] <- item
    }
  }
  x
}

dictionary_context_chunks <- function(dictionary) {
  if (is.null(dictionary)) {
    return(character(0))
  }

  tables <- vapply(
    names(dictionary$tables),
    function(name) {
      entry <- dictionary$tables[[name]]
      prose <- paste(c(entry$description, entry$details), collapse = "\n\n")
      if (!nzchar(prose)) {
        return(NA_character_)
      }
      sprintf("Table `%s`: %s", name, prose)
    },
    character(1)
  )
  glossary <- sprintf(
    "%s: %s",
    names(dictionary$glossary),
    vapply(dictionary$glossary, identity, character(1))
  )

  chunks <- c(
    dictionary$details,
    tables[!is.na(tables)],
    glossary,
    definition_context_chunks(dictionary)
  )
  chunks[nzchar(chunks)]
}

# Frontmatter carries file metadata (e.g. provenance) meant for maintainers,
# not the model; drop it so retrieval can't surface it.
strip_frontmatter <- function(md) {
  sub("(?s)^---\r?\n.*?\r?\n---(\r?\n|$)", "", md, perl = TRUE)
}

# Store setup (duckdb creation, chunk insertion, FTS indexing) is the most
# expensive part of building an agent and many conversations never search, so
# it's deferred to the first search. The cache environment is created fresh
# whenever a layer's docs change, so layers sharing docs share a store and
# layers that differ never do.
context_store <- function(layer, source = NULL) {
  key <- if (is.null(source)) "store" else paste0("store:", source)
  if (is.null(layer$cache[[key]])) {
    local_commons_span(
      "commons_context_store_build",
      attributes = list("commons.context.n_docs" = length(layer$docs))
    )
    keep <- if (is.null(source)) {
      rep(TRUE, length(layer$docs))
    } else {
      vapply(
        layer$sources,
        function(sources) length(sources) == 0 || source %in% sources,
        logical(1)
      )
    }
    docs <- layer$docs[keep]
    store <- ragnar::ragnar_store_create(embed = NULL)
    for (doc in docs) {
      ragnar::ragnar_store_insert(store, ragnar::markdown_chunk(doc))
    }
    ragnar::ragnar_store_build_index(store, type = "fts")
    layer$cache[[key]] <- store
  }
  layer$cache[[key]]
}

context_search <- function(layer, query, n = 3, source = NULL) {
  if (length(layer$docs) == 0) {
    return(character(0))
  }
  if (!is.null(source) && !any(vapply(
    layer$sources,
    function(sources) length(sources) == 0 || source %in% sources,
    logical(1)
  ))) {
    return(character(0))
  }
  res <- ragnar::ragnar_retrieve_bm25(
    context_store(layer, source),
    query,
    top_k = n
  )
  if (nrow(res) == 0) {
    return(character(0))
  }
  trimws(res$text)
}

check_context_layer <- function(context_layer, call = rlang::caller_env()) {
  if (!is.null(context_layer) && !inherits(context_layer, "commons_context_layer")) {
    cli::cli_abort(
      "{.arg context_layer} must be a {.fn context_layer} or {.code NULL}.",
      call = call
    )
  }
}
