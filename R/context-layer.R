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
  for (path in files) {
    md <- strip_frontmatter(paste(readLines(path, warn = FALSE), collapse = "\n"))
    if (nzchar(trimws(md))) {
      docs <- c(docs, md)
    }
  }

  new_context_layer(docs)
}

# Dictionary prose doubles as searchable context, inserted at natural YAML
# boundaries (one chunk per glossary term, per table's prose, and for the
# dataset details) so retrieval returns coherent units. Column-level content
# stays out of the store: first touch owns it, and indexing it would pay for
# a second copy the agent already has.
augment_context_layer <- function(context_layer, sources) {
  chunks <- unlist(lapply(
    sources,
    function(source) dictionary_context_chunks(source$dictionary)
  ))
  if (length(chunks) == 0) {
    return(context_layer)
  }

  layer <- context_layer %||% context_layer()
  new_context_layer(c(layer$docs, chunks))
}

new_context_layer <- function(docs) {
  structure(
    list(docs = docs, cache = new.env(parent = emptyenv())),
    class = "commons_context_layer"
  )
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
context_store <- function(layer) {
  if (is.null(layer$cache$store)) {
    local_commons_span(
      "commons_context_store_build",
      attributes = list("commons.context.n_docs" = length(layer$docs))
    )
    store <- ragnar::ragnar_store_create(embed = NULL)
    for (doc in layer$docs) {
      ragnar::ragnar_store_insert(store, ragnar::markdown_chunk(doc))
    }
    ragnar::ragnar_store_build_index(store, type = "fts")
    layer$cache$store <- store
  }
  layer$cache$store
}

context_search <- function(layer, query, n = 3) {
  if (length(layer$docs) == 0) {
    return(character(0))
  }
  res <- ragnar::ragnar_retrieve_bm25(context_store(layer), query, top_k = n)
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
