# Snowflake and Databricks share precedence and most expression syntax. Keep
# their semantic differences at operations that require target-aware lowering.

definition_emit_sql <- function(ir, dialect, selection = NULL) {
  dialect <- match.arg(dialect, c("snowflake", "databricks"))
  state <- new.env(parent = emptyenv())
  state$notes <- character()
  code <- tryCatch(
    {
      if (is.null(selection)) {
        definition_sql_child(ir, 0L, "free", state, dialect)
      } else {
        code <- vapply(
          selection$columns,
          function(column) {
            selected <- definition_sql_identifier(column$path, dialect)
            definition_sql_child(
              ir,
              2L,
              "free",
              state,
              dialect,
              selected
            )
          },
          character(1)
        )
        paste(code, collapse = " AND ")
      }
    },
    commons_definition_unsupported = function(error) error
  )
  if (inherits(code, "commons_definition_unsupported")) {
    return(list(
      code = NULL,
      error = conditionMessage(code),
      notes = sort(unique(state$notes))
    ))
  }
  list(code = code, error = NULL, notes = sort(unique(state$notes)))
}

definition_sql_write <- function(
  node,
  state,
  dialect,
  selected = NULL
) {
  kind <- node$kind
  if (identical(kind, "number")) {
    return(definition_sql_number(node, dialect))
  }
  if (identical(kind, "string")) {
    return(definition_sql_string(node$value, dialect))
  }
  if (identical(kind, "boolean")) {
    return(if (isTRUE(node$value)) "TRUE" else "FALSE")
  }
  if (identical(kind, "null")) {
    return("NULL")
  }
  if (identical(kind, "date")) {
    return(sprintf("DATE '%s'", node$value))
  }
  if (identical(kind, "datetime")) {
    return(sprintf("TIMESTAMP '%s'", node$value))
  }
  if (identical(kind, "now")) {
    return("CURRENT_TIMESTAMP()")
  }
  if (identical(kind, "column")) {
    return(definition_sql_identifier(node$path, dialect))
  }
  if (identical(kind, "selected")) {
    return(selected)
  }
  if (identical(kind, "negate")) {
    return(paste0(
      "-",
      definition_sql_child(
        node$operand,
        7L,
        "right",
        state,
        dialect,
        selected
      )
    ))
  }
  if (identical(kind, "not")) {
    return(paste0(
      "NOT ",
      definition_sql_child(
        node$operand,
        3L,
        "right",
        state,
        dialect,
        selected
      )
    ))
  }
  if (kind %in% c("and", "or")) {
    level <- if (identical(kind, "and")) 2L else 1L
    return(definition_sql_infix(
      node$lhs,
      node$rhs,
      toupper(kind),
      level,
      state,
      dialect,
      selected
    ))
  }
  if (identical(kind, "arithmetic")) {
    shifted <- definition_sql_temporal_shift(node, state, dialect, selected)
    if (!is.null(shifted)) {
      return(shifted)
    }
    if (identical(node$op, "/")) {
      definition_sql_note(
        state,
        definition_sql_division_note[[dialect]]
      )
    }
    level <- if (node$op %in% c("+", "-")) 5L else 6L
    return(definition_sql_infix(
      node$lhs,
      node$rhs,
      node$op,
      level,
      state,
      dialect,
      selected
    ))
  }
  if (identical(kind, "compare")) {
    if (node$lhs$type == "number" || node$rhs$type == "number") {
      definition_sql_note(state, definition_sql_nan_note[[dialect]])
    }
    op <- if (node$op %in% c("!=", "<>")) "<>" else node$op
    return(definition_sql_infix(
      node$lhs,
      node$rhs,
      op,
      4L,
      state,
      dialect,
      selected
    ))
  }
  if (identical(kind, "is_null")) {
    operand <- definition_sql_child(
      node$operand,
      4L,
      "left",
      state,
      dialect,
      selected
    )
    suffix <- if (isTRUE(node$negated)) " IS NOT NULL" else " IS NULL"
    return(paste0(operand, suffix))
  }
  if (identical(kind, "between")) {
    if (any(c(node$operand$type, node$lo$type, node$hi$type) == "number")) {
      definition_sql_note(state, definition_sql_nan_note[[dialect]])
    }
    operand <- definition_sql_child(
      node$operand,
      4L,
      "left",
      state,
      dialect,
      selected
    )
    lo <- definition_sql_child(
      node$lo,
      4L,
      "right",
      state,
      dialect,
      selected
    )
    hi <- definition_sql_child(
      node$hi,
      4L,
      "right",
      state,
      dialect,
      selected
    )
    op <- if (isTRUE(node$negated)) " NOT BETWEEN " else " BETWEEN "
    return(paste0(operand, op, lo, " AND ", hi))
  }
  if (identical(kind, "in")) {
    if (identical(node$operand$type, "number")) {
      definition_sql_note(state, definition_sql_nan_note[[dialect]])
    }
    operand <- definition_sql_child(
      node$operand,
      4L,
      "left",
      state,
      dialect,
      selected
    )
    items <- vapply(
      node$items,
      definition_sql_child,
      character(1),
      parent = 0L,
      side = "free",
      state = state,
      dialect = dialect,
      selected = selected
    )
    op <- if (isTRUE(node$negated)) " NOT IN (" else " IN ("
    return(paste0(operand, op, paste(items, collapse = ", "), ")"))
  }
  if (identical(kind, "like")) {
    return(definition_sql_like(node, state, dialect, selected))
  }
  if (identical(kind, "similar")) {
    return(definition_sql_similar(node, state, dialect, selected))
  }
  if (identical(kind, "interval")) {
    definition_sql_abort_unsupported(
      dialect,
      "a standalone interval",
      "intervals are supported only when shifting a date or datetime"
    )
  }
  if (identical(kind, "case")) {
    branches <- vapply(
      node$whens,
      function(branch) {
        condition <- definition_sql_child(
          branch$condition,
          0L,
          "free",
          state,
          dialect,
          selected
        )
        result <- definition_sql_child(
          branch$result,
          0L,
          "free",
          state,
          dialect,
          selected
        )
        sprintf(" WHEN %s THEN %s", condition, result)
      },
      character(1)
    )
    otherwise <- if (!is.null(node$otherwise)) {
      paste0(
        " ELSE ",
        definition_sql_child(
          node$otherwise,
          0L,
          "free",
          state,
          dialect,
          selected
        )
      )
    } else {
      ""
    }
    return(paste0("CASE", paste0(branches, collapse = ""), otherwise, " END"))
  }
  if (identical(kind, "function")) {
    return(definition_sql_function(node, state, dialect, selected))
  }
  cli::cli_abort("No SQL translation for expression node {.val {kind}}.")
}

definition_sql_function <- function(node, state, dialect, selected) {
  args <- vapply(
    node$args,
    definition_sql_child,
    character(1),
    parent = 0L,
    side = "free",
    state = state,
    dialect = dialect,
    selected = selected
  )
  simple <- c(
    length = "length",
    lower = "lower",
    upper = "upper",
    trim = "trim",
    abs = "abs",
    floor = "floor",
    ceil = "ceil",
    min = "min",
    max = "max",
    avg = "avg",
    count = "count"
  )
  if (node$name %in% names(simple)) {
    if (identical(node$name, "trim")) {
      definition_sql_note(state, definition_sql_trim_note[[dialect]])
    }
    return(sprintf("%s(%s)", simple[[node$name]], paste(args, collapse = ", ")))
  }
  if (node$name %in% c("starts_with", "ends_with")) {
    fn <- switch(
      dialect,
      snowflake = if (node$name == "starts_with") "STARTSWITH" else "ENDSWITH",
      databricks = if (node$name == "starts_with") "startswith" else "endswith"
    )
    return(sprintf("%s(%s)", fn, paste(args, collapse = ", ")))
  }
  if (identical(node$name, "round")) {
    if (
      identical(dialect, "databricks") &&
        length(node$args) == 2L &&
        !(identical(node$args[[2]]$kind, "number") &&
          identical(node$args[[2]]$number_kind, "integer"))
    ) {
      definition_sql_abort_unsupported(
        dialect,
        "a dynamic ROUND() scale",
        "Databricks requires the scale to be an integer constant"
      )
    }
    return(sprintf("round(%s)", paste(args, collapse = ", ")))
  }
  if (identical(node$name, "mod")) {
    return(definition_sql_mod(node, args, state, dialect, selected))
  }
  if (node$name %in% c("is_finite", "is_infinite", "is_nan")) {
    return(definition_sql_non_finite(node$name, args[[1]], dialect))
  }
  if (identical(node$name, "sum")) {
    definition_sql_note(state, definition_sql_sum_note[[dialect]])
    return(sprintf("sum(%s)", args[[1]]))
  }
  if (identical(node$name, "row_count")) {
    return("count(*)")
  }
  if (identical(node$name, "count_distinct")) {
    return(sprintf("count(DISTINCT %s)", args[[1]]))
  }
  if (node$name %in% c("any", "all")) {
    fn <- switch(
      dialect,
      snowflake = if (node$name == "any") "BOOLOR_AGG" else "BOOLAND_AGG",
      databricks = if (node$name == "any") "bool_or" else "bool_and"
    )
    return(sprintf("%s(%s)", fn, args[[1]]))
  }
  cli::cli_abort("No SQL translation for function {.val {node$name}}.")
}

definition_sql_mod <- function(node, args, state, dialect, selected) {
  divisor <- definition_sql_child(
    node$args[[2]],
    5L,
    "right",
    state,
    dialect,
    selected
  )
  nan <- definition_sql_non_finite_literal("nan", dialect)
  value <- if (identical(dialect, "databricks")) {
    sprintf("pmod(%s, %s)", args[[1]], args[[2]])
  } else {
    sprintf(
      "MOD(MOD(%s, %s) + %s, %s)",
      args[[1]],
      args[[2]],
      divisor,
      args[[2]]
    )
  }
  sprintf("CASE WHEN %s = 0 THEN %s ELSE %s END", divisor, nan, value)
}

definition_sql_non_finite <- function(name, arg, dialect) {
  nan <- definition_sql_non_finite_literal("nan", dialect)
  inf <- definition_sql_non_finite_literal("inf", dialect)
  neg_inf <- definition_sql_non_finite_literal("-inf", dialect)
  if (identical(dialect, "snowflake")) {
    predicate <- switch(
      name,
      is_nan = sprintf("%s = %s", arg, nan),
      is_infinite = sprintf("%s IN (%s, %s)", arg, inf, neg_inf),
      is_finite = sprintf(
        "%s <> %s AND %s NOT IN (%s, %s)",
        arg,
        nan,
        arg,
        inf,
        neg_inf
      )
    )
    return(paste0("(", predicate, ")"))
  }
  predicate <- switch(
    name,
    is_nan = sprintf("isnan(%s)", arg),
    is_infinite = sprintf("%s IN (%s, %s)", arg, inf, neg_inf),
    is_finite = sprintf(
      "NOT isnan(%s) AND %s NOT IN (%s, %s)",
      arg,
      arg,
      inf,
      neg_inf
    )
  )
  sprintf("(CASE WHEN %s IS NULL THEN NULL ELSE %s END)", arg, predicate)
}

definition_sql_like <- function(node, state, dialect, selected) {
  operand <- definition_sql_child(
    node$operand,
    4L,
    "left",
    state,
    dialect,
    selected
  )
  if (!identical(node$pattern$kind, "string")) {
    definition_sql_note(state, definition_sql_like_note[[dialect]])
    pattern <- definition_sql_child(
      node$pattern,
      4L,
      "right",
      state,
      dialect,
      selected
    )
    op <- if (isTRUE(node$negated)) " NOT LIKE " else " LIKE "
    return(paste0(operand, op, pattern))
  }
  pattern <- node$pattern$value
  wildcards <- gregexpr("[%_]", pattern, perl = TRUE)[[1]]
  count <- if (wildcards[[1]] == -1L) 0L else length(wildcards)
  if (count == 0L) {
    op <- if (isTRUE(node$negated)) " <> " else " = "
    return(paste0(operand, op, definition_sql_string(pattern, dialect)))
  }
  if (count == 1L && endsWith(pattern, "%")) {
    prefix <- if (isTRUE(node$negated)) "NOT " else ""
    fn <- if (identical(dialect, "snowflake")) "STARTSWITH" else "startswith"
    return(sprintf(
      "%s%s(%s, %s)",
      prefix,
      fn,
      definition_sql_child(
        node$operand,
        0L,
        "free",
        state,
        dialect,
        selected
      ),
      definition_sql_string(substr(pattern, 1L, nchar(pattern) - 1L), dialect)
    ))
  }
  if (count == 1L && startsWith(pattern, "%")) {
    prefix <- if (isTRUE(node$negated)) "NOT " else ""
    fn <- if (identical(dialect, "snowflake")) "ENDSWITH" else "endswith"
    return(sprintf(
      "%s%s(%s, %s)",
      prefix,
      fn,
      definition_sql_child(
        node$operand,
        0L,
        "free",
        state,
        dialect,
        selected
      ),
      definition_sql_string(substr(pattern, 2L, nchar(pattern)), dialect)
    ))
  }
  regex <- definition_duckdb_like_regex(pattern)
  prefix <- if (isTRUE(node$negated)) "NOT " else ""
  sprintf(
    "%s%s(%s, %s)",
    prefix,
    if (identical(dialect, "snowflake")) "REGEXP_LIKE" else "regexp_like",
    definition_sql_child(
      node$operand,
      0L,
      "free",
      state,
      dialect,
      selected
    ),
    definition_sql_string(regex, dialect)
  )
}

definition_sql_similar <- function(node, state, dialect, selected) {
  definition_sql_note(state, definition_sql_regex_note[[dialect]])
  operand <- definition_sql_child(
    node$operand,
    0L,
    "free",
    state,
    dialect,
    selected
  )
  pattern <- definition_sql_child(
    node$pattern,
    0L,
    "free",
    state,
    dialect,
    selected
  )
  if (identical(dialect, "databricks")) {
    pattern <- sprintf("concat('^(?:', %s, ')$')", pattern)
  }
  prefix <- if (isTRUE(node$negated)) "NOT " else ""
  sprintf(
    "%s%s(%s, %s)",
    prefix,
    if (identical(dialect, "snowflake")) "REGEXP_LIKE" else "regexp_like",
    operand,
    pattern
  )
}

definition_sql_temporal_shift <- function(node, state, dialect, selected) {
  lhs_interval <- identical(node$lhs$type, "interval")
  rhs_interval <- identical(node$rhs$type, "interval")
  if (!lhs_interval && !rhs_interval) {
    return(NULL)
  }
  if (lhs_interval && identical(node$op, "-")) {
    definition_sql_abort_unsupported(
      dialect,
      "an interval minus a temporal value",
      "data-dict does not define an executable temporal shift for that order"
    )
  }
  interval <- if (lhs_interval) node$lhs else node$rhs
  base <- if (lhs_interval) node$rhs else node$lhs
  amount <- definition_sql_child(
    interval$n,
    0L,
    "free",
    state,
    dialect,
    selected
  )
  multiplier <- switch(
    interval$unit,
    seconds = "1000000",
    minutes = "60000000",
    hours = "3600000000",
    days = "86400000000",
    weeks = "604800000000"
  )
  amount <- sprintf("(%s) * %s", amount, multiplier)
  if (identical(node$op, "-") && rhs_interval) {
    amount <- paste0("-(", amount, ")")
  }
  value <- definition_sql_child(
    base,
    0L,
    "free",
    state,
    dialect,
    selected
  )
  fn <- if (identical(dialect, "snowflake")) "DATEADD" else "timestampadd"
  sprintf("%s(MICROSECOND, %s, %s)", fn, amount, value)
}

definition_sql_infix <- function(
  lhs,
  rhs,
  op,
  level,
  state,
  dialect,
  selected
) {
  paste(
    definition_sql_child(lhs, level, "left", state, dialect, selected),
    op,
    definition_sql_child(rhs, level, "right", state, dialect, selected)
  )
}

definition_sql_child <- function(
  node,
  parent,
  side,
  state,
  dialect,
  selected = NULL
) {
  own <- definition_sql_precedence(node)
  code <- definition_sql_write(node, state, dialect, selected)
  if (own < parent || (own == parent && identical(side, "right"))) {
    paste0("(", code, ")")
  } else {
    code
  }
}

definition_sql_precedence <- function(node) {
  switch(
    node$kind,
    or = 1L,
    and = 2L,
    not = 3L,
    compare = 4L,
    is_null = 4L,
    between = 4L,
    `in` = 4L,
    like = 4L,
    arithmetic = if (node$op %in% c("+", "-")) 5L else 6L,
    negate = 7L,
    8L
  )
}

definition_sql_identifier <- function(path, dialect) {
  if (identical(dialect, "snowflake") && length(path) > 1L) {
    out <- definition_sql_quote_identifier(path[[1]], dialect)
    for (field in path[-1L]) {
      out <- sprintf("GET(%s, %s)", out, definition_sql_string(field, dialect))
    }
    return(out)
  }
  paste(
    vapply(path, definition_sql_quote_identifier, character(1), dialect),
    collapse = "."
  )
}

definition_sql_quote_identifier <- function(name, dialect) {
  quote <- if (identical(dialect, "databricks")) "`" else '"'
  escaped <- gsub(quote, paste0(quote, quote), name, fixed = TRUE)
  paste0(quote, escaped, quote)
}

definition_sql_string <- function(value, dialect) {
  value <- gsub("'", "''", value, fixed = TRUE)
  if (identical(dialect, "databricks")) {
    value <- gsub("\\", "\\\\", value, fixed = TRUE)
  }
  sprintf("'%s'", value)
}

definition_sql_number <- function(node, dialect) {
  if (identical(node$number_kind, "integer")) {
    return(node$value)
  }
  if (is.nan(node$value)) {
    return(definition_sql_non_finite_literal("nan", dialect))
  }
  if (is.infinite(node$value)) {
    value <- if (node$value < 0) "-inf" else "inf"
    return(definition_sql_non_finite_literal(value, dialect))
  }
  text <- definition_duckdb_float(node$value)
  if (!grepl("[.eE]", text)) paste0(text, ".0") else text
}

definition_sql_non_finite_literal <- function(value, dialect) {
  literal <- switch(
    value,
    nan = "NaN",
    inf = if (identical(dialect, "snowflake")) "inf" else "Infinity",
    `-inf` = if (identical(dialect, "snowflake")) "-inf" else "-Infinity"
  )
  sprintf("CAST('%s' AS DOUBLE)", literal)
}

definition_sql_note <- function(state, note) {
  state$notes <- c(state$notes, note)
  invisible(NULL)
}

definition_sql_abort_unsupported <- function(dialect, what, why) {
  cli::cli_abort(
    "{what} is not supported for {dialect}: {why}.",
    class = "commons_definition_unsupported",
    call = NULL
  )
}

definition_sql_nan_note <- list(
  snowflake = paste(
    "Snowflake orders a NaN as equal to itself and greater than every number,",
    "where data-dict uses IEEE comparisons."
  ),
  databricks = paste(
    "Databricks orders a NaN as equal to itself and greater than every number,",
    "where data-dict uses IEEE comparisons."
  )
)

definition_sql_division_note <- list(
  snowflake = paste(
    "Snowflake raises an error for division by zero, where data-dict returns",
    "an infinity or NaN."
  ),
  databricks = paste(
    "Databricks may raise an error or return null for division by zero, where",
    "data-dict returns an infinity or NaN."
  )
)

definition_sql_trim_note <- list(
  snowflake = paste(
    "Snowflake TRIM removes spaces by default, where data-dict removes Unicode",
    "whitespace."
  ),
  databricks = paste(
    "Databricks trim removes spaces by default, where data-dict removes Unicode",
    "whitespace."
  )
)

definition_sql_like_note <- list(
  snowflake = paste(
    "A dynamic Snowflake LIKE pattern follows Snowflake escaping rules, which",
    "can differ from data-dict for backslashes."
  ),
  databricks = paste(
    "A dynamic Databricks LIKE pattern treats backslash as an escape, where",
    "data-dict treats it literally."
  )
)

definition_sql_regex_note <- list(
  snowflake = paste(
    "Snowflake evaluates POSIX regular expressions, which can differ from",
    "data-dict's Rust regex engine."
  ),
  databricks = paste(
    "Databricks evaluates Java regular expressions, which can differ from",
    "data-dict's Rust regex engine."
  )
)

definition_sql_sum_note <- list(
  snowflake = paste(
    "Snowflake numeric precision and overflow can differ from data-dict's",
    "64-bit integer and floating-point accumulation."
  ),
  databricks = paste(
    "Databricks numeric precision and overflow can differ from data-dict's",
    "64-bit integer and floating-point accumulation."
  )
)
