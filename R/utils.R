lexical_rank <- function(query, documents, n = 5) {
  terms <- tokenize(query)
  if (length(terms) == 0 || length(documents) == 0) {
    return(integer(0))
  }

  scores <- vapply(
    documents,
    function(doc) {
      doc_terms <- unique(tokenize(doc))
      sum(terms %in% doc_terms)
    },
    integer(1)
  )

  hits <- which(scores > 0)
  hits[order(scores[hits], decreasing = TRUE)][seq_len(min(n, length(hits)))]
}

tokenize <- function(x) {
  x <- tolower(paste(x, collapse = " "))
  x <- gsub("[^a-z0-9]+", " ", x)
  terms <- strsplit(trimws(x), "\\s+")[[1]]
  terms[nchar(terms) > 1]
}

df_to_markdown <- function(df, max_rows = 50) {
  n <- nrow(df)
  shown <- utils::head(df, max_rows)
  out <- knitr::kable(shown, format = "pipe")
  if (n > max_rows) {
    out <- c(out, "", sprintf("%d more rows not shown", n - max_rows))
  }
  paste(out, collapse = "\n")
}

df_to_html <- function(df, max_rows = 50) {
  n <- nrow(df)
  shown <- utils::head(df, max_rows)
  out <- paste(knitr::kable(shown, format = "html"), collapse = "")
  if (n > max_rows) {
    out <- paste0(out, sprintf("<p>%d more rows not shown</p>", n - max_rows))
  }
  out
}

# Collapse a multi-line prose field onto one line, e.g. for a bullet item.
flatten_inline <- function(x) {
  trimws(gsub("\\s*\\n\\s*", " ", x))
}

escape_regex <- function(x) {
  gsub("([][{}()+*^$|\\\\?.])", "\\\\\\1", x)
}

# Match `x` as a whole word, escaping any regex metacharacters it contains.
word_pattern <- function(x) {
  paste0("\\b", escape_regex(x), "\\b")
}

# Icons are decorative, so bsicons is optional.
maybe_icon <- function(name) {
  if (is_installed("bsicons")) {
    bsicons::bs_icon(name)
  } else {
    NULL
  }
}

# Run `expr` when `envir` exits, like withr::defer(). Works inside coro
# generator frames, which persist across yields and exit on completion.
defer <- function(expr, envir = parent.frame()) {
  thunk <- as.call(list(function() expr))
  do.call(on.exit, list(thunk, add = TRUE), envir = envir)
}

drop_nulls <- function(x) {
  x[!vapply(x, is.null, logical(1))]
}

# Every `commons_tag` carried by a ContentToolResult in the turns appended
# since `from_index` (i.e. `turns[from_index:length(turns)]`) -- a read-only
# walk, never a mutation, so it's safe to call on `self$get_turns()` mid- or
# post-stream without disturbing ellmer's turn store.
collect_appended_tags <- function(turns, from_index) {
  if (from_index > length(turns)) {
    return(character())
  }
  appended <- turns[from_index:length(turns)]
  tags <- unlist(
    lapply(appended, function(turn) {
      lapply(turn@contents, function(content) {
        if (S7::S7_inherits(content, ellmer::ContentToolResult)) {
          content@extra$commons_tag
        }
      })
    }),
    use.names = FALSE
  )
  tags %||% character()
}

# Shared by commons.R's turn_has_user_message() and trajectory-review.R's
# turn_has_tool_result().
is_tool_result_content <- function(content) {
  S7::S7_inherits(content, ellmer::ContentToolResult)
}
