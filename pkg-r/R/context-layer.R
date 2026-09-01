#' Create a context layer
#'
#' A context layer contains text that helps a [commons()] agent interpret its
#' data source.
#'
#' Context is retrieved when relevant. Facts needed in every conversation
#' belong in the `instructions` passed to [commons()], not here.
#'
#' @param files Character vector of paths to text or Markdown files.
#'
#' @return A `commons_context_layer` R6 object. Its internals are private and
#'   may change without notice.
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
    function(source) {
      source_state <- data_source_state(source)
      c(
        dictionary_context_chunks(source_state$dictionary),
        unlist(lapply(
          source_state$semantic_models,
          function(model) model$context$retrieval
        ), use.names = FALSE)
      )
    }
  ))
  if (length(chunks) == 0) {
    return(context_layer)
  }

  layer <- context_layer %||% context_layer()
  layer_state <- context_layer_state(layer)
  # Source enrichment belongs to this agent, not the caller's layer.
  new_context_layer(c(layer_state$docs, chunks))
}

new_context_layer <- function(docs) {
  ContextLayer$new(docs = docs)
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
# not the model; drop it so retrieval can't surface it. The metadata block is
# optional so an emptied-out fence is removed rather than indexed as text.
strip_frontmatter <- function(md) {
  sub("(?s)^---\r?\n(.*?\r?\n)?---(\r?\n|$)", "", md, perl = TRUE)
}

# Store setup (duckdb creation, chunk insertion, FTS indexing) is the most
# expensive part of building an agent and many conversations never search, so
# it's deferred to the first search. Aliases of one layer share its store;
# augmenting its documents creates a layer with a fresh store.
context_store <- function(layer) {
  state <- context_layer_state(layer)
  if (is.null(state$store)) {
    local_commons_span(
      "commons_context_store_build",
      attributes = list("commons.context.n_docs" = length(state$docs))
    )
    store <- ragnar::ragnar_store_create(embed = NULL)
    for (doc in state$docs) {
      ragnar::ragnar_store_insert(store, ragnar::markdown_chunk(doc))
    }
    ragnar::ragnar_store_build_index(store, type = "fts")
    state$store <- store
  }
  state$store
}

context_search <- function(layer, query, n = 3) {
  state <- context_layer_state(layer)
  if (length(state$docs) == 0) {
    return(character(0))
  }
  res <- ragnar::ragnar_retrieve_bm25(context_store(layer), query, top_k = n)
  if (nrow(res) == 0) {
    return(character(0))
  }
  trimws(res$text)
}

check_context_layer <- function(context_layer, call = rlang::caller_env()) {
  if (
    !is.null(context_layer) &&
      (!is.environment(context_layer) ||
        !inherits(context_layer, "commons_context_layer"))
  ) {
    cli::cli_abort(
      "{.arg context_layer} must be a {.fn context_layer} or {.code NULL}.",
      call = call
    )
  }
}
