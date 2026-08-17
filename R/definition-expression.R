definition_expr_parse <- function(text, call = rlang::caller_env()) {
  if (!rlang::is_string(text) || !nzchar(trimws(text))) {
    cli::cli_abort(
      "A definition expression must be a non-empty string.",
      call = call
    )
  }
  parser <- definition_parser(text)
  out <- definition_parse_or(parser, call = call)
  definition_parser_skip_ws(parser)
  if (!definition_parser_eof(parser)) {
    definition_parse_abort(parser, "unexpected text after the expression", call)
  }
  out
}

definition_parser <- function(text) {
  parser <- new.env(parent = emptyenv())
  parser$text <- text
  parser$chars <- strsplit(text, "", fixed = TRUE)[[1]]
  parser$pos <- 1L
  parser
}

definition_parse_or <- function(parser, call) {
  lhs <- definition_parse_and(parser, call)
  while (definition_parser_match_word(parser, "or")) {
    rhs <- definition_parse_and(parser, call)
    lhs <- definition_expr_node("or", lhs$start, rhs$end, lhs = lhs, rhs = rhs)
  }
  lhs
}

definition_parse_and <- function(parser, call) {
  lhs <- definition_parse_not(parser, call)
  while (definition_parser_match_word(parser, "and")) {
    rhs <- definition_parse_not(parser, call)
    lhs <- definition_expr_node("and", lhs$start, rhs$end, lhs = lhs, rhs = rhs)
  }
  lhs
}

definition_parse_not <- function(parser, call) {
  definition_parser_skip_ws(parser)
  start <- parser$pos
  if (definition_parser_match_word(parser, "not")) {
    operand <- definition_parse_not(parser, call)
    return(definition_expr_node("not", start, operand$end, operand = operand))
  }
  definition_parse_predicate(parser, call)
}

definition_parse_predicate <- function(parser, call) {
  operand <- definition_parse_additive(parser, call)
  definition_parser_skip_ws(parser)
  op <- definition_parser_comparison(parser)
  if (!is.null(op)) {
    rhs <- definition_parse_additive(parser, call)
    return(definition_expr_node(
      "compare",
      operand$start,
      rhs$end,
      op = op,
      lhs = operand,
      rhs = rhs
    ))
  }
  if (definition_parser_match_word(parser, "is")) {
    negated <- definition_parser_match_word(parser, "not")
    definition_parser_expect_word(parser, "null", call)
    return(definition_expr_node(
      "is_null",
      operand$start,
      parser$pos - 1L,
      operand = operand,
      negated = negated
    ))
  }
  negated <- definition_parser_match_word(parser, "not")
  if (definition_parser_match_word(parser, "between")) {
    lo <- definition_parse_additive(parser, call)
    definition_parser_expect_word(parser, "and", call)
    hi <- definition_parse_additive(parser, call)
    return(definition_expr_node(
      "between",
      operand$start,
      hi$end,
      operand = operand,
      lo = lo,
      hi = hi,
      negated = negated
    ))
  }
  if (definition_parser_match_word(parser, "in")) {
    definition_parser_skip_ws(parser)
    definition_parser_expect(parser, "(", call)
    items <- list(definition_parse_or(parser, call))
    while (definition_parser_try(parser, ",", skip_ws = TRUE)) {
      items[[length(items) + 1L]] <- definition_parse_or(parser, call)
    }
    definition_parser_skip_ws(parser)
    definition_parser_expect(parser, ")", call)
    return(definition_expr_node(
      "in",
      operand$start,
      parser$pos - 1L,
      operand = operand,
      items = items,
      negated = negated
    ))
  }
  if (definition_parser_match_word(parser, "like")) {
    pattern <- definition_parse_additive(parser, call)
    return(definition_expr_node(
      "like",
      operand$start,
      pattern$end,
      operand = operand,
      pattern = pattern,
      negated = negated
    ))
  }
  if (definition_parser_match_word(parser, "similar")) {
    definition_parser_expect_word(parser, "to", call)
    pattern <- definition_parse_additive(parser, call)
    return(definition_expr_node(
      "similar",
      operand$start,
      pattern$end,
      operand = operand,
      pattern = pattern,
      negated = negated
    ))
  }
  if (negated) {
    definition_parse_abort(
      parser,
      "expected `BETWEEN`, `IN`, `LIKE`, or `SIMILAR TO` after `NOT`",
      call
    )
  }
  operand
}

definition_parse_additive <- function(parser, call) {
  lhs <- definition_parse_multiplicative(parser, call)
  repeat {
    definition_parser_skip_ws(parser)
    op <- definition_parser_peek(parser)
    if (is.null(op) || !op %in% c("+", "-")) {
      break
    }
    parser$pos <- parser$pos + 1L
    rhs <- definition_parse_multiplicative(parser, call)
    lhs <- definition_expr_node(
      "arithmetic",
      lhs$start,
      rhs$end,
      op = op,
      lhs = lhs,
      rhs = rhs
    )
  }
  lhs
}

definition_parse_multiplicative <- function(parser, call) {
  lhs <- definition_parse_unary(parser, call)
  repeat {
    definition_parser_skip_ws(parser)
    op <- definition_parser_peek(parser)
    if (is.null(op) || !op %in% c("*", "/")) {
      break
    }
    parser$pos <- parser$pos + 1L
    rhs <- definition_parse_unary(parser, call)
    lhs <- definition_expr_node(
      "arithmetic",
      lhs$start,
      rhs$end,
      op = op,
      lhs = lhs,
      rhs = rhs
    )
  }
  lhs
}

definition_parse_unary <- function(parser, call) {
  definition_parser_skip_ws(parser)
  start <- parser$pos
  if (identical(definition_parser_peek(parser), "-")) {
    parser$pos <- parser$pos + 1L
    operand <- definition_parse_unary(parser, call)
    return(definition_expr_node(
      "negate",
      start,
      operand$end,
      operand = operand
    ))
  }
  definition_parse_primary(parser, call)
}

definition_parse_primary <- function(parser, call) {
  definition_parser_skip_ws(parser)
  start <- parser$pos
  char <- definition_parser_peek(parser)
  if (is.null(char)) {
    definition_parse_abort(parser, "expected an expression", call)
  }
  if (identical(char, "(")) {
    parser$pos <- parser$pos + 1L
    out <- definition_parse_or(parser, call)
    definition_parser_skip_ws(parser)
    definition_parser_expect(parser, ")", call)
    out$start <- start
    out$end <- parser$pos - 1L
    return(out)
  }
  if (identical(char, "'")) {
    return(definition_parse_string(parser, call))
  }
  if (identical(char, "`")) {
    name <- definition_parse_quoted_name(parser, call)
    path <- definition_parse_field_path(parser, name, call)
    return(definition_expr_node(
      "column",
      start,
      parser$pos - 1L,
      path = path
    ))
  }
  if (grepl("^[0-9]$", char)) {
    return(definition_parse_number(parser, call))
  }
  if (definition_identifier_start(char)) {
    return(definition_parse_word_primary(parser, call))
  }
  definition_parse_abort(parser, "expected an expression", call)
}

definition_parse_string <- function(parser, call) {
  start <- parser$pos
  parser$pos <- parser$pos + 1L
  value <- character()
  repeat {
    char <- definition_parser_peek(parser)
    if (is.null(char)) {
      definition_parse_abort(parser, "unterminated string literal", call)
    }
    if (identical(char, "'")) {
      if (identical(definition_parser_peek(parser, 1L), "'")) {
        value <- c(value, "'")
        parser$pos <- parser$pos + 2L
      } else {
        parser$pos <- parser$pos + 1L
        break
      }
    } else {
      value <- c(value, char)
      parser$pos <- parser$pos + 1L
    }
  }
  definition_expr_node(
    "string",
    start,
    parser$pos - 1L,
    value = paste0(value, collapse = "")
  )
}

definition_parse_number <- function(parser, call) {
  start <- parser$pos
  while (
    !is.null(definition_parser_peek(parser)) &&
      grepl("^[0-9]$", definition_parser_peek(parser))
  ) {
    parser$pos <- parser$pos + 1L
  }
  kind <- "integer"
  if (
    identical(definition_parser_peek(parser), ".") &&
      !is.null(definition_parser_peek(parser, 1L)) &&
      grepl("^[0-9]$", definition_parser_peek(parser, 1L))
  ) {
    kind <- "float"
    parser$pos <- parser$pos + 1L
    while (
      !is.null(definition_parser_peek(parser)) &&
        grepl("^[0-9]$", definition_parser_peek(parser))
    ) {
      parser$pos <- parser$pos + 1L
    }
  }
  text <- paste0(parser$chars[start:(parser$pos - 1L)], collapse = "")
  if (identical(kind, "integer")) {
    normalized <- sub("^0+(?=.)", "", text, perl = TRUE)
    if (
      nchar(normalized) > 19L ||
        (nchar(normalized) == 19L && normalized > "9223372036854775807")
    ) {
      definition_parse_abort(
        parser,
        sprintf("`%s` is too large for a 64-bit integer", text),
        call,
        start
      )
    }
    value <- normalized
  } else {
    normalized <- sub("^0+(?=[0-9])", "", text, perl = TRUE)
    value <- tryCatch(
      jsonlite::fromJSON(normalized),
      error = function(error) Inf
    )
    if (!is.finite(value)) {
      definition_parse_abort(
        parser,
        sprintf("`%s` is too large for a number", text),
        call,
        start
      )
    }
  }
  definition_expr_node(
    "number",
    start,
    parser$pos - 1L,
    number_kind = kind,
    value = value
  )
}

definition_parse_word_primary <- function(parser, call) {
  start <- parser$pos
  word <- definition_parser_read_word(parser)
  lower <- tolower(word)
  if (lower %in% c("true", "false")) {
    return(definition_expr_node(
      "boolean",
      start,
      parser$pos - 1L,
      value = identical(lower, "true")
    ))
  }
  if (identical(lower, "null")) {
    return(definition_expr_node("null", start, parser$pos - 1L))
  }
  if (lower %in% c("inf", "nan")) {
    return(definition_expr_node(
      "number",
      start,
      parser$pos - 1L,
      number_kind = "float",
      value = if (identical(lower, "inf")) Inf else NaN
    ))
  }
  if (identical(lower, "case")) {
    return(definition_parse_case(parser, start, call))
  }
  if (identical(lower, "columns")) {
    return(definition_parse_columns(parser, start, call))
  }
  if (identical(lower, "now")) {
    definition_parser_skip_ws(parser)
    definition_parser_expect(parser, "(", call)
    definition_parser_skip_ws(parser)
    definition_parser_expect(parser, ")", call)
    return(definition_expr_node("now", start, parser$pos - 1L))
  }
  if (identical(lower, "interval")) {
    return(definition_parse_interval(parser, start, call))
  }
  if (lower %in% definition_reserved_words) {
    definition_parse_abort(
      parser,
      sprintf("unexpected keyword `%s`", toupper(word)),
      call,
      start
    )
  }
  after <- parser$pos
  definition_parser_skip_ws(parser)
  if (identical(definition_parser_peek(parser), "(")) {
    parser$pos <- parser$pos + 1L
    args <- definition_parse_arguments(parser, call)
    return(definition_expr_node(
      "function",
      start,
      parser$pos - 1L,
      name = lower,
      args = args
    ))
  }
  parser$pos <- after
  path <- definition_parse_field_path(parser, word, call)
  definition_expr_node("column", start, parser$pos - 1L, path = path)
}

definition_parse_arguments <- function(parser, call) {
  definition_parser_skip_ws(parser)
  if (definition_parser_try(parser, ")")) {
    return(list())
  }
  args <- list(definition_parse_or(parser, call))
  while (definition_parser_try(parser, ",", skip_ws = TRUE)) {
    args[[length(args) + 1L]] <- definition_parse_or(parser, call)
  }
  definition_parser_skip_ws(parser)
  definition_parser_expect(parser, ")", call)
  args
}

definition_parse_interval <- function(parser, start, call) {
  definition_parser_skip_ws(parser)
  definition_parser_expect(parser, "(", call)
  n <- definition_parse_or(parser, call)
  definition_parser_skip_ws(parser)
  definition_parser_expect(parser, ",", call)
  definition_parser_skip_ws(parser)
  unit_start <- parser$pos
  if (!definition_identifier_start(definition_parser_peek(parser))) {
    definition_parse_abort(parser, "expected an interval unit", call)
  }
  unit <- definition_parser_read_word(parser)
  definition_parser_skip_ws(parser)
  definition_parser_expect(parser, ")", call)
  definition_expr_node(
    "interval",
    start,
    parser$pos - 1L,
    n = n,
    unit = tolower(unit),
    unit_start = unit_start
  )
}

definition_parse_columns <- function(parser, start, call) {
  definition_parser_skip_ws(parser)
  definition_parser_expect(parser, "(", call)
  definition_parser_skip_ws(parser)
  char <- definition_parser_peek(parser)
  if (identical(char, "*")) {
    parser$pos <- parser$pos + 1L
    selector <- list(kind = "all")
  } else if (identical(char, "'")) {
    pattern <- definition_parse_string(parser, call)
    selector <- list(kind = "regex", pattern = pattern$value)
  } else if (identical(char, "[")) {
    parser$pos <- parser$pos + 1L
    names <- character()
    repeat {
      definition_parser_skip_ws(parser)
      char <- definition_parser_peek(parser)
      if (identical(char, "`")) {
        name <- definition_parse_quoted_name(parser, call)
      } else if (definition_identifier_start(char)) {
        name <- definition_parser_read_word(parser)
      } else {
        definition_parse_abort(parser, "expected a column name", call)
      }
      names <- c(names, name)
      definition_parser_skip_ws(parser)
      if (definition_parser_try(parser, ",")) {
        next
      }
      definition_parser_expect(parser, "]", call)
      break
    }
    selector <- list(kind = "list", names = names)
  } else {
    definition_parse_abort(
      parser,
      "expected `*`, a regex string, or `[names]`",
      call
    )
  }
  definition_parser_skip_ws(parser)
  definition_parser_expect(parser, ")", call)
  definition_expr_node(
    "columns",
    start,
    parser$pos - 1L,
    selector = selector
  )
}

definition_parse_case <- function(parser, start, call) {
  whens <- list()
  while (definition_parser_match_word(parser, "when")) {
    condition <- definition_parse_or(parser, call)
    definition_parser_expect_word(parser, "then", call)
    result <- definition_parse_or(parser, call)
    whens[[length(whens) + 1L]] <- list(condition = condition, result = result)
  }
  if (length(whens) == 0L) {
    definition_parse_abort(
      parser,
      "`CASE` needs at least one `WHEN ... THEN ...`",
      call
    )
  }
  otherwise <- if (definition_parser_match_word(parser, "else")) {
    definition_parse_or(parser, call)
  }
  definition_parser_expect_word(parser, "end", call)
  definition_expr_node(
    "case",
    start,
    parser$pos - 1L,
    whens = whens,
    otherwise = otherwise
  )
}

definition_parse_quoted_name <- function(parser, call) {
  parser$pos <- parser$pos + 1L
  value <- character()
  repeat {
    char <- definition_parser_peek(parser)
    if (is.null(char)) {
      definition_parse_abort(parser, "unterminated quoted name", call)
    }
    if (identical(char, "`")) {
      if (identical(definition_parser_peek(parser, 1L), "`")) {
        value <- c(value, "`")
        parser$pos <- parser$pos + 2L
      } else {
        parser$pos <- parser$pos + 1L
        break
      }
    } else {
      value <- c(value, char)
      parser$pos <- parser$pos + 1L
    }
  }
  value <- paste0(value, collapse = "")
  if (!nzchar(value)) {
    definition_parse_abort(parser, "a quoted name must not be empty", call)
  }
  value
}

definition_parse_field_path <- function(parser, first, call) {
  path <- first
  while (identical(definition_parser_peek(parser), ".")) {
    parser$pos <- parser$pos + 1L
    char <- definition_parser_peek(parser)
    if (identical(char, "`")) {
      name <- definition_parse_quoted_name(parser, call)
    } else if (definition_identifier_start(char)) {
      name <- definition_parser_read_word(parser)
    } else {
      definition_parse_abort(parser, "expected a field name after `.`", call)
    }
    path <- c(path, name)
  }
  path
}

definition_expr_node <- function(kind, start, end, ...) {
  c(list(kind = kind, start = start, end = end), list(...))
}

definition_parser_skip_ws <- function(parser) {
  while (
    !definition_parser_eof(parser) &&
      definition_parser_peek(parser) %in% c(" ", "\t", "\n", "\r", "\f", "\v")
  ) {
    parser$pos <- parser$pos + 1L
  }
  invisible(NULL)
}

definition_parser_eof <- function(parser) {
  parser$pos > length(parser$chars)
}

definition_parser_peek <- function(parser, offset = 0L) {
  pos <- parser$pos + offset
  if (pos < 1L || pos > length(parser$chars)) {
    return(NULL)
  }
  parser$chars[[pos]]
}

definition_parser_try <- function(parser, char, skip_ws = FALSE) {
  if (skip_ws) {
    definition_parser_skip_ws(parser)
  }
  if (!identical(definition_parser_peek(parser), char)) {
    return(FALSE)
  }
  parser$pos <- parser$pos + 1L
  TRUE
}

definition_parser_expect <- function(parser, char, call) {
  if (!definition_parser_try(parser, char)) {
    definition_parse_abort(parser, sprintf("expected `%s`", char), call)
  }
  invisible(NULL)
}

definition_parser_read_word <- function(parser) {
  start <- parser$pos
  while (
    !definition_parser_eof(parser) &&
      definition_identifier_part(definition_parser_peek(parser))
  ) {
    parser$pos <- parser$pos + 1L
  }
  paste0(parser$chars[start:(parser$pos - 1L)], collapse = "")
}

definition_parser_match_word <- function(parser, word) {
  save <- parser$pos
  definition_parser_skip_ws(parser)
  end <- parser$pos + nchar(word) - 1L
  if (end > length(parser$chars)) {
    parser$pos <- save
    return(FALSE)
  }
  candidate <- paste0(parser$chars[parser$pos:end], collapse = "")
  after <- if (end < length(parser$chars)) parser$chars[[end + 1L]]
  if (
    !identical(tolower(candidate), word) || definition_identifier_part(after)
  ) {
    parser$pos <- save
    return(FALSE)
  }
  parser$pos <- end + 1L
  TRUE
}

definition_parser_expect_word <- function(parser, word, call) {
  if (!definition_parser_match_word(parser, word)) {
    definition_parse_abort(
      parser,
      sprintf("expected `%s`", toupper(word)),
      call
    )
  }
  invisible(NULL)
}

definition_parser_comparison <- function(parser) {
  for (op in c(">=", "<=", "<>", "!=", "=", ">", "<")) {
    end <- parser$pos + nchar(op) - 1L
    if (
      end <= length(parser$chars) &&
        identical(paste0(parser$chars[parser$pos:end], collapse = ""), op)
    ) {
      parser$pos <- end + 1L
      return(op)
    }
  }
  NULL
}

definition_identifier_start <- function(char) {
  !is.null(char) && grepl("^[A-Za-z_]$", char)
}

definition_identifier_part <- function(char) {
  !is.null(char) && grepl("^[A-Za-z0-9_]$", char)
}

definition_parse_abort <- function(parser, message, call, at = parser$pos) {
  cli::cli_abort(
    c(
      "Invalid definition expression at character {at}.",
      x = message
    ),
    call = call
  )
}

definition_reserved_words <- c(
  "and",
  "or",
  "not",
  "is",
  "null",
  "between",
  "in",
  "like",
  "similar",
  "to",
  "when",
  "then",
  "else",
  "end",
  "true",
  "false",
  "inf",
  "nan",
  "case",
  "columns",
  "now",
  "interval"
)
