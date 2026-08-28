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
# not the model; drop it so retrieval can't surface it.
strip_frontmatter <- function(md) {
  sub("(?s)^---\r?\n.*?\r?\n---(\r?\n|$)", "", md, perl = TRUE)
}

# The context store is a persistent, content-addressed DuckDB file: the key
# hashes the layer's docs plus the ragnar/duckdb versions (whose file format
# the store depends on), so a build happens once per content version per
# cache root and every process afterwards opens it read-only. Store setup is
# still deferred to the first search (or prewarm_context()) since many
# conversations never search, but on a warm cache that first search only
# pays for opening a file. Aliases of one layer share its store; augmenting
# its documents creates a layer with a fresh store.
context_store <- function(layer) {
  state <- context_layer_state(layer)
  if (!is.null(state$store)) {
    return(state$store)
  }
  path <- context_store_path(state$docs)
  if (!file.exists(path)) {
    build_context_store(state$docs, path)
  }
  store <- ragnar::ragnar_store_connect(path)
  state$store <- store
  store
}

# Build to a temp file in the same directory, then rename into place
# atomically, so a concurrent reader or builder never observes a partial
# store. If another builder wins the race, its store is equivalent content;
# discard ours and open theirs.
build_context_store <- function(docs, path) {
  local_commons_span(
    "commons_context_store_build",
    attributes = list("commons.context.n_docs" = length(docs))
  )
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  tmp <- tempfile(pattern = ".build-", tmpdir = dirname(path))
  on.exit(unlink(tmp, recursive = TRUE), add = TRUE)

  store <- ragnar::ragnar_store_create(tmp, embed = NULL)
  for (doc in docs) {
    ragnar::ragnar_store_insert(store, ragnar::markdown_chunk(doc))
  }
  ragnar::ragnar_store_build_index(store, type = "fts")
  DBI::dbDisconnect(store@con, shutdown = TRUE)

  if (!file.exists(path)) {
    file.rename(tmp, path)
  }
  if (!file.exists(path)) {
    cli::cli_abort("Failed to build the context store at {.path {path}}.")
  }
  invisible(path)
}

context_store_path <- function(docs) {
  key <- rlang::hash(c(
    docs,
    paste0("ragnar:", utils::packageVersion("ragnar")),
    paste0("duckdb:", utils::packageVersion("duckdb"))
  ))
  file.path(context_cache_dir(), "context", paste0(key, ".duckdb"))
}

# Cache root resolution: an explicit override, then Connect's persistent
# data directory (survives deployments when the server enables it), then the
# per-user cache dir. Wherever the root is ephemeral (e.g. Connect Cloud,
# which resets disk to the deployed bundle), the store simply rebuilds once
# per cache lifetime instead of once per process.
context_cache_dir <- function() {
  opt <- getOption("commons.context_cache")
  if (!is.null(opt)) {
    return(opt)
  }
  for (env in c("COMMONS_CONTEXT_CACHE", "CONNECT_CONTENT_DATA_DIR")) {
    val <- Sys.getenv(env, unset = NA_character_)
    if (!is.na(val) && nzchar(val)) {
      return(val)
    }
  }
  tools::R_user_dir("commons", "cache")
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
