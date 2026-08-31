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
# Housekeeping state for the persistent context cache: prune throttling, the
# fallback tempdir, and the one-time warning about an unusable cache dir.
context_cache_state <- new.env(parent = emptyenv())

context_store <- function(layer) {
  state <- context_layer_state(layer)
  if (!is.null(state$store)) {
    return(state$store)
  }
  if (!context_cache_enabled()) {
    store <- build_context_store_memory(state$docs)
    state$store <- store
    return(store)
  }
  path <- context_store_path(state$docs)
  if (!file.exists(path)) {
    build_context_store(state$docs, path)
  } else {
    # Touch the mtime so size-cap eviction is LRU: stores in active use
    # stay young. Best-effort -- a read-only cache dir still opens fine.
    tryCatch(Sys.setFileTime(path, Sys.time()), error = function(err) NULL)
  }
  store <- ragnar::ragnar_store_connect(path)
  state$store <- store
  store
}

# options(commons.context_cache = FALSE) disables the persistent store (the
# index is built in memory per layer instead) -- an escape hatch for
# development loops over context files.
context_cache_enabled <- function() {
  if (identical(getOption("commons.context_cache"), FALSE)) {
    return(FALSE)
  }
  # Env vars can't express FALSE; accept the usual spellings.
  val <- Sys.getenv("COMMONS_CONTEXT_CACHE", unset = NA_character_)
  if (!is.na(val) && tolower(val) %in% c("false", "0", "no")) {
    return(FALSE)
  }
  TRUE
}

build_context_store_memory <- function(docs) {
  local_commons_span(
    "commons_context_store_build",
    attributes = list(
      "commons.context.n_docs" = length(docs),
      "commons.context.persistent" = FALSE
    )
  )
  store <- ragnar::ragnar_store_create(embed = NULL)
  for (doc in docs) {
    ragnar::ragnar_store_insert(store, ragnar::markdown_chunk(doc))
  }
  ragnar::ragnar_store_build_index(store, type = "fts")
  store
}

# Build to a temp file in the same directory, then rename into place
# atomically, so a concurrent reader or builder never observes a partial
# store. If another builder wins the race, its store is equivalent content;
# discard ours and open theirs.
build_context_store <- function(docs, path) {
  local_commons_span(
    "commons_context_store_build",
    attributes = list(
      "commons.context.n_docs" = length(docs),
      "commons.context.persistent" = TRUE
    )
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
  prune_context_cache(dirname(path), protect = path)
  invisible(path)
}

# Content-addressed stores accumulate one file per content version, so the
# cache is capped by total size and pruned LRU: the mtime touch on open
# keeps actively used stores young, so eviction deletes least-recently-used
# stores first. The store just built is protected explicitly (not just by
# its young mtime) so a store larger than the cap survives: like cachem, a
# single oversized store is kept, with a one-time warning, rather than
# evicted into a rebuild loop. Throttled like cachem (at most once per 20
# builds or per 5 seconds) since stat-ing the directory on every build is
# needlessly slow; concurrent pruners may double-delete, which unlink
# tolerates with a warning.
prune_context_cache <- function(
  dir,
  max_size = getOption("commons.context_cache_max_size", 256 * 1024^2),
  protect = NULL
) {
  now <- Sys.time()
  context_cache_state$n_builds <- (context_cache_state$n_builds %||% 0) + 1
  last <- context_cache_state$last_prune
  throttled <- context_cache_state$n_builds %% 20 != 0 &&
    !is.null(last) &&
    difftime(now, last, units = "secs") < 5
  if (throttled) {
    return(invisible())
  }
  context_cache_state$last_prune <- now

  # Evict least-recently-used stores until the cache fits under max_size.
  stores <- list.files(dir, pattern = "[.]duckdb$", full.names = TRUE)
  total <- sum(file.size(stores))
  if (total > max_size) {
    evictable <- setdiff(stores, protect)
    evictable <- evictable[order(file.mtime(evictable))]
    for (victim in evictable) {
      if (total <= max_size) {
        break
      }
      total <- total - file.size(victim)
      suppressWarnings(unlink(victim))
    }
    if (total > max_size && is.null(context_cache_state$warned_size)) {
      context_cache_state$warned_size <- TRUE
      cli::cli_warn(c(
        "The context cache exceeds its size cap ({format_size(max_size)}) with only protected or in-use stores remaining.",
        i = "A single store larger than the cap is kept; raise {.code options(commons.context_cache_max_size)} if this is expected."
      ))
    }
  }
  invisible()
}

format_size <- function(bytes) {
  if (bytes >= 1024^2) {
    sprintf("%.0f MB", bytes / 1024^2)
  } else {
    sprintf("%.0f KB", bytes / 1024)
  }
}

context_store_path <- function(docs) {
  key <- rlang::hash(c(
    docs,
    paste0("ragnar:", utils::packageVersion("ragnar")),
    paste0("duckdb:", utils::packageVersion("duckdb"))
  ))
  file.path(context_cache_dir_safe(), "context", paste0(key, ".duckdb"))
}

# Cache root resolution: an explicit override, then Connect's persistent
# data directory (survives deployments when the server enables it), then --
# for Shiny apps -- an app_cache/ directory beside the app (sass's
# convention: per-app scoping on hosted platforms, used locally only if it
# already exists), then the per-user cache dir. Wherever the root is
# ephemeral (e.g. Connect Cloud, which resets disk to the deployed bundle),
# the store simply rebuilds once per cache lifetime instead of once per
# process.
context_cache_dir <- function() {
  opt <- getOption("commons.context_cache")
  if (!is.null(opt) && !identical(opt, FALSE)) {
    if (!rlang::is_string(opt)) {
      cli::cli_abort(
        "{.code options(commons.context_cache)} must be a path to a cache directory or {.code FALSE}."
      )
    }
    return(opt)
  }
  for (env in c("COMMONS_CONTEXT_CACHE", "CONNECT_CONTENT_DATA_DIR")) {
    val <- Sys.getenv(env, unset = NA_character_)
    false_like <- !is.na(val) && tolower(val) %in% c("false", "0", "no")
    if (!is.na(val) && nzchar(val) && !false_like) {
      return(val)
    }
  }
  if (is_shiny_app()) {
    app_dir <- shiny::getShinyOption("appDir")
    if (!is.null(app_dir)) {
      app_cache <- file.path(app_dir, "app_cache", "commons")
      if (
        is_hosted_shiny_app() ||
          dir.exists(app_cache) ||
          dir.exists(dirname(app_cache))
      ) {
        return(app_cache)
      }
    }
  }
  tools::R_user_dir("commons", "cache")
}

is_shiny_app <- function() {
  isNamespaceLoaded("shiny") && shiny::isRunning()
}

# Connect and Shiny Server both set SHINY_SERVER_VERSION for content.
is_hosted_shiny_app <- function() {
  nzchar(Sys.getenv("SHINY_SERVER_VERSION")) && is_shiny_app()
}

# Caching must never take down the app: if the resolved cache dir can't be
# created or written, warn once and fall back to a per-session tempdir (the
# store becomes per-process, as if persistence were disabled).
context_cache_dir_safe <- function() {
  dir <- context_cache_dir()
  ok <- tryCatch(
    {
      dir.create(dir, recursive = TRUE, showWarnings = FALSE)
      dir.exists(dir) && file.access(dir, 2) == 0
    },
    error = function(err) FALSE
  )
  if (ok) {
    return(dir)
  }
  if (is.null(context_cache_state$warned)) {
    context_cache_state$warned <- TRUE
    cli::cli_warn(c(
      "Cannot write to the context cache directory {.path {dir}}.",
      i = "Falling back to a per-session temporary directory; the context index will be rebuilt in each process."
    ))
  }
  if (is.null(context_cache_state$fallback_dir)) {
    context_cache_state$fallback_dir <- tempfile("commons-context-cache-")
    dir.create(context_cache_state$fallback_dir, recursive = TRUE)
  }
  context_cache_state$fallback_dir
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
