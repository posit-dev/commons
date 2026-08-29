# Operational functions stay outside the R6 classes; centralize private access.
object_private <- function(x) {
  .subset2(
    .subset2(x, ".__enclos_env__"),
    "private"
  )
}

data_source_state <- function(x) object_private(x)

semantic_layer_state <- function(x) object_private(x)

context_layer_state <- function(x) object_private(x)

DataSource <- R6::R6Class(
  "commons_data_source",
  public = list(
    initialize = function(
      con,
      tables,
      table_ids,
      handle,
      dictionary,
      pending,
      relations,
      manifest,
      session,
      definition_bindings,
      semantic_models,
      semantic_stubs,
      calculations
    ) {
      private$con <- con
      private$tables <- tables
      private$table_ids <- table_ids
      private$handle <- handle
      private$dictionary <- dictionary
      private$pending <- pending
      private$relations <- relations
      private$manifest <- manifest
      private$session <- session
      private$definition_bindings <- definition_bindings
      private$semantic_models <- semantic_models
      private$semantic_stubs <- semantic_stubs
      private$calculations <- calculations
    },
    print = function(...) {
      n <- length(private$tables)
      cli::cli_text("A commons data source with {n} table{?s}.")
      invisible(self)
    }
  ),
  private = list(
    con = NULL,
    tables = NULL,
    table_ids = NULL,
    handle = NULL,
    dictionary = NULL,
    pending = NULL,
    relations = NULL,
    manifest = NULL,
    session = NULL,
    definition_bindings = NULL,
    semantic_models = NULL,
    semantic_stubs = NULL,
    calculations = NULL
  ),
  lock_objects = TRUE,
  lock_class = TRUE,
  cloneable = FALSE
)

SemanticLayer <- R6::R6Class(
  "commons_semantic_layer",
  public = list(
    initialize = function(measures, fn_sources) {
      private$measures <- measures
      private$fn_sources <- fn_sources
    },
    print = function(...) {
      n <- length(private$measures)
      cli::cli_text("A commons semantic layer with {n} measure{?s}.")
      invisible(self)
    }
  ),
  private = list(
    measures = NULL,
    fn_sources = NULL
  ),
  lock_objects = TRUE,
  lock_class = TRUE,
  cloneable = FALSE
)

ContextLayer <- R6::R6Class(
  "commons_context_layer",
  public = list(
    initialize = function(docs, cache) {
      private$docs <- docs
      private$cache <- cache
    },
    print = function(...) {
      n <- length(private$docs)
      cli::cli_text("A commons context layer with {n} document{?s}.")
      invisible(self)
    }
  ),
  private = list(
    docs = NULL,
    cache = NULL
  ),
  lock_objects = TRUE,
  lock_class = TRUE,
  cloneable = FALSE
)
