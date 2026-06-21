#' Create a context store
#'
#' A context store contains text that helps a [commons()] agent interpret its
#' data source.
#'
#' Files are chunked and indexed with \pkg{ragnar}. The `always` argument is for
#' short facts that should be included in every system prompt.
#'
#' @param files Character vector of paths to text/markdown files to index.
#' @param always Character vector of facts to inject into the system prompt on
#'   every turn. Optional.
#'
#' @return A `commons_context_store` object.
#'
#' @examples
#' store <- context_store(
#'   always = "Revenue excludes tax unless stated otherwise."
#' )
#'
#' @export
context_store <- function(files = character(), always = character()) {
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
    class = "commons_context_store"
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

check_context_store <- function(context, call = rlang::caller_env()) {
  if (!is.null(context) && !inherits(context, "commons_context_store")) {
    cli::cli_abort(
      "{.arg context} must be a {.fn context_store} or {.code NULL}.",
      call = call
    )
  }
}
