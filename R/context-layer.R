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
    md <- paste(readLines(path, warn = FALSE), collapse = "\n")
    ragnar::ragnar_store_insert(store, ragnar::markdown_chunk(md))
  }
  if (length(files)) {
    ragnar::ragnar_store_build_index(store, type = "fts")
  }

  structure(
    list(store = store, always = always, n_docs = length(files)),
    class = "commons_context_layer"
  )
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
