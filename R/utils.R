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
    out <- c(out, sprintf("", n - max_rows))
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

# Match `x` as a whole word, escaping any regex metacharacters it contains.
word_pattern <- function(x) {
  paste0("\\b", gsub("([][{}()+*^$|\\\\?.])", "\\\\\\1", x), "\\b")
}

# Icons are decorative, so bsicons is optional.
maybe_icon <- function(name) {
  if (is_installed("bsicons")) {
    bsicons::bs_icon(name)
  } else {
    NULL
  }
}

is_installed <- function(pkg) {
  requireNamespace(pkg, quietly = TRUE)
}
