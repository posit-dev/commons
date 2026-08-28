new_object_state <- function(...) {
  state <- list2env(list(...), parent = emptyenv())
  lockEnvironment(state, bindings = FALSE)
  state
}

object_private <- function(x) {
  .subset2(
    .subset2(x, ".__enclos_env__"),
    "private"
  )
}

data_source_state <- function(x) object_private(x)$state

semantic_layer_state <- function(x) object_private(x)$state

context_layer_state <- function(x) object_private(x)$state

DataSource <- R6::R6Class(
  "commons_data_source",
  public = list(
    initialize = function(state) {
      private$state <- state
    },
    print = function(...) {
      n <- length(private$state$tables)
      cli::cli_text("A commons data source with {n} table{?s}.")
      invisible(self)
    }
  ),
  private = list(state = NULL),
  lock_objects = TRUE,
  lock_class = TRUE,
  cloneable = FALSE
)

SemanticLayer <- R6::R6Class(
  "commons_semantic_layer",
  public = list(
    initialize = function(state) {
      private$state <- state
    },
    print = function(...) {
      n <- length(private$state$measures)
      cli::cli_text("A commons semantic layer with {n} measure{?s}.")
      invisible(self)
    }
  ),
  private = list(state = NULL),
  lock_objects = TRUE,
  lock_class = TRUE,
  cloneable = FALSE
)

ContextLayer <- R6::R6Class(
  "commons_context_layer",
  public = list(
    initialize = function(state) {
      private$state <- state
    },
    print = function(...) {
      n <- length(private$state$docs)
      cli::cli_text("A commons context layer with {n} document{?s}.")
      invisible(self)
    }
  ),
  private = list(state = NULL),
  lock_objects = TRUE,
  lock_class = TRUE,
  cloneable = FALSE
)
