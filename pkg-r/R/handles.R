# Conversation-scoped store of tool results, so later `run_r` calls can
# reference earlier outputs as plain variables (`r1`, `r2`, ...).

new_handle_store <- function() {
  store <- new.env(parent = emptyenv())
  store$count <- 0L
  store$values <- new.env(parent = emptyenv())
  store
}

# Store a tool result under the next handle id and tell the model how to access
# it from run_r, or return NULL when there's nothing to register (no store, or
# a NULL value). Non-tabular values (e.g. scalar measure results) are available
# for further derivation too.
register_handle <- function(store, value, max_rows = 10000L) {
  if (is.null(store) || is.null(value)) {
    return(NULL)
  }
  if (!is.data.frame(value)) {
    store$count <- store$count + 1L
    id <- paste0("r", store$count)
    assign(id, value, envir = store$values)
    return(sprintf("Available to `run_r` as `%s`.", id))
  }

  value <- as.data.frame(value)
  capped <- nrow(value) > max_rows
  if (capped) {
    value <- utils::head(value, max_rows)
  }

  store$count <- store$count + 1L
  id <- paste0("r", store$count)
  assign(id, value, envir = store$values)

  note <- if (capped) {
    sprintf(" Only the first %s rows are stored.", format_number(max_rows))
  } else {
    ""
  }
  paste0(
    sprintf("Available to `run_r` as `%s`.%s\n", id, note),
    as.character(ellmer::df_schema(value))
  )
}

handle_ids <- function(store) {
  if (is.null(store) || store$count == 0L) {
    return(character())
  }
  paste0("r", seq_len(store$count))
}

get_handle <- function(store, id) {
  get(id, envir = store$values, inherits = FALSE)
}
