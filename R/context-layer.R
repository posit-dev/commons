#' Create a context layer
#'
#' A context layer contains text that helps a [commons()] agent interpret its
#' data source.
#'
#' Files are chunked and indexed with \pkg{ragnar}. The `always` argument is for
#' short facts that should be included in every system prompt.
#'
#' @param files Character vector of paths to text/markdown files to index.
#' @param always Character vector of facts to inject into the system prompt on
#'   every turn. Optional.
#'
#' @return A `commons_context_layer` object.
#'
#' @examples
#' layer <- context_layer(
#'   always = "Revenue excludes tax unless stated otherwise."
#' )
#'
#' @export
context_layer <- function(files = character(), always = character()) {
  if (!is.character(files) || !is.character(always)) {
    cli::cli_abort("{.arg files} and {.arg always} must be character vectors.")
  }

  store <- ragnar::ragnar_store_create(embed = NULL)
  for (path in files) {
    md <- strip_frontmatter(paste(readLines(path, warn = FALSE), collapse = "\n"))
    if (nzchar(trimws(md))) {
      ragnar::ragnar_store_insert(store, ragnar::markdown_chunk(md))
    }
  }
  if (length(files)) {
    ragnar::ragnar_store_build_index(store, type = "fts")
  }

  structure(
    list(store = store, always = always, n_docs = length(files)),
    class = "commons_context_layer"
  )
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
  for (chunk in chunks) {
    ragnar::ragnar_store_insert(layer$store, ragnar::markdown_chunk(chunk))
  }
  ragnar::ragnar_store_build_index(layer$store, type = "fts")
  layer$n_docs <- layer$n_docs + length(chunks)
  layer
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

  chunks <- c(dictionary$details, tables[!is.na(tables)], glossary)
  chunks[nzchar(chunks)]
}

# Frontmatter carries file metadata (e.g. provenance) meant for maintainers,
# not the model; drop it so retrieval can't surface it.
strip_frontmatter <- function(md) {
  sub("(?s)^---\r?\n.*?\r?\n---(\r?\n|$)", "", md, perl = TRUE)
}

context_search <- function(store, query, n = 3) {
  if (store$n_docs == 0) {
    return(character(0))
  }
  res <- ragnar::ragnar_retrieve_bm25(store$store, query, top_k = n)
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
