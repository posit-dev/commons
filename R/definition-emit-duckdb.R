definition_emit_duckdb <- function(ir, selection = NULL) {
  state <- new.env(parent = emptyenv())
  state$notes <- character()
  if (is.null(selection)) {
    code <- definition_duckdb_child(ir, 0L, "free", state)
  } else {
    code <- vapply(
      selection$columns,
      function(column) {
        selected <- definition_duckdb_identifier(column$path)
        definition_duckdb_child(ir, 2L, "free", state, selected)
      },
      character(1)
    )
    code <- paste(code, collapse = " AND ")
  }
  list(code = code, notes = sort(unique(state$notes)))
}

definition_duckdb_write <- function(node, state, selected = NULL) {
  kind <- node$kind
  if (identical(kind, "number")) {
    return(definition_duckdb_number(node))
  }
  if (identical(kind, "string")) {
    return(definition_duckdb_string(node$value))
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
    return("current_timestamp")
  }
  if (identical(kind, "column")) {
    return(definition_duckdb_identifier(node$path))
  }
  if (identical(kind, "selected")) {
    return(selected)
  }
  if (identical(kind, "negate")) {
    return(paste0(
      "-",
      definition_duckdb_child(node$operand, 7L, "right", state, selected)
    ))
  }
  if (identical(kind, "not")) {
    return(paste0(
      "NOT ",
      definition_duckdb_child(node$operand, 3L, "right", state, selected)
    ))
  }
  if (kind %in% c("and", "or")) {
    level <- if (identical(kind, "and")) 2L else 1L
    op <- toupper(kind)
    return(definition_duckdb_infix(
      node$lhs,
      node$rhs,
      op,
      level,
      state,
      selected
    ))
  }
  if (identical(kind, "arithmetic")) {
    level <- if (node$op %in% c("+", "-")) 5L else 6L
    return(definition_duckdb_infix(
      node$lhs,
      node$rhs,
      node$op,
      level,
      state,
      selected
    ))
  }
  if (identical(kind, "compare")) {
    if (node$lhs$type == "number" || node$rhs$type == "number") {
      definition_duckdb_note(state, definition_duckdb_nan_note)
    }
    op <- if (node$op %in% c("!=", "<>")) "<>" else node$op
    return(definition_duckdb_infix(
      node$lhs,
      node$rhs,
      op,
      4L,
      state,
      selected
    ))
  }
  if (identical(kind, "is_null")) {
    operand <- definition_duckdb_child(
      node$operand,
      4L,
      "left",
      state,
      selected
    )
    suffix <- if (isTRUE(node$negated)) " IS NOT NULL" else " IS NULL"
    return(paste0(operand, suffix))
  }
  if (identical(kind, "between")) {
    if (any(c(node$operand$type, node$lo$type, node$hi$type) == "number")) {
      definition_duckdb_note(state, definition_duckdb_nan_note)
    }
    operand <- definition_duckdb_child(
      node$operand,
      4L,
      "left",
      state,
      selected
    )
    lo <- definition_duckdb_child(node$lo, 4L, "right", state, selected)
    hi <- definition_duckdb_child(node$hi, 4L, "right", state, selected)
    op <- if (isTRUE(node$negated)) " NOT BETWEEN " else " BETWEEN "
    return(paste0(operand, op, lo, " AND ", hi))
  }
  if (identical(kind, "in")) {
    if (identical(node$operand$type, "number")) {
      definition_duckdb_note(state, definition_duckdb_nan_note)
    }
    operand <- definition_duckdb_child(
      node$operand,
      4L,
      "left",
      state,
      selected
    )
    items <- vapply(
      node$items,
      definition_duckdb_child,
      character(1),
      parent = 0L,
      side = "free",
      state = state,
      selected = selected
    )
    op <- if (isTRUE(node$negated)) " NOT IN (" else " IN ("
    return(paste0(operand, op, paste(items, collapse = ", "), ")"))
  }
  if (identical(kind, "like")) {
    return(definition_duckdb_like(node, state, selected))
  }
  if (identical(kind, "similar")) {
    operand <- definition_duckdb_child(
      node$operand,
      0L,
      "free",
      state,
      selected
    )
    pattern <- definition_duckdb_child(
      node$pattern,
      0L,
      "free",
      state,
      selected
    )
    prefix <- if (isTRUE(node$negated)) "NOT " else ""
    return(sprintf("%sregexp_full_match(%s, %s)", prefix, operand, pattern))
  }
  if (identical(kind, "interval")) {
    if (
      identical(node$n$kind, "number") &&
        identical(node$n$number_kind, "integer")
    ) {
      return(sprintf("INTERVAL '%s %s'", node$n$value, node$unit))
    }
    n <- definition_duckdb_child(node$n, 0L, "free", state, selected)
    return(sprintf("(%s * INTERVAL '1 %s')", n, node$unit))
  }
  if (identical(kind, "case")) {
    branches <- vapply(
      node$whens,
      function(branch) {
        condition <- definition_duckdb_child(
          branch$condition,
          0L,
          "free",
          state,
          selected
        )
        result <- definition_duckdb_child(
          branch$result,
          0L,
          "free",
          state,
          selected
        )
        sprintf(" WHEN %s THEN %s", condition, result)
      },
      character(1)
    )
    otherwise <- if (!is.null(node$otherwise)) {
      paste0(
        " ELSE ",
        definition_duckdb_child(
          node$otherwise,
          0L,
          "free",
          state,
          selected
        )
      )
    } else {
      ""
    }
    return(paste0("CASE", paste0(branches, collapse = ""), otherwise, " END"))
  }
  if (identical(kind, "function")) {
    return(definition_duckdb_function(node, state, selected))
  }
  cli::cli_abort("No DuckDB translation for expression node {.val {kind}}.")
}

definition_duckdb_function <- function(node, state, selected) {
  args <- vapply(
    node$args,
    definition_duckdb_child,
    character(1),
    parent = 0L,
    side = "free",
    state = state,
    selected = selected
  )
  simple <- c(
    length = "length",
    lower = "lower",
    upper = "upper",
    trim = "trim",
    starts_with = "starts_with",
    ends_with = "ends_with",
    abs = "abs",
    floor = "floor",
    ceil = "ceil",
    round = "round",
    is_finite = "isfinite",
    is_infinite = "isinf",
    is_nan = "isnan",
    min = "min",
    max = "max",
    avg = "avg",
    count = "count",
    any = "bool_or",
    all = "bool_and"
  )
  if (node$name %in% names(simple)) {
    return(sprintf("%s(%s)", simple[[node$name]], paste(args, collapse = ", ")))
  }
  if (identical(node$name, "sum")) {
    definition_duckdb_note(state, definition_duckdb_sum_note)
    return(sprintf("sum(%s)", paste(args, collapse = ", ")))
  }
  if (identical(node$name, "row_count")) {
    return("count(*)")
  }
  if (identical(node$name, "count_distinct")) {
    return(sprintf("count(DISTINCT %s)", args[[1]]))
  }
  if (identical(node$name, "mod")) {
    definition_duckdb_note(state, definition_duckdb_mod_note)
    y <- definition_duckdb_child(
      node$args[[2]],
      5L,
      "right",
      state,
      selected
    )
    return(sprintf(
      "mod(mod(%s, %s) + %s, %s)",
      args[[1]],
      args[[2]],
      y,
      args[[2]]
    ))
  }
  cli::cli_abort("No DuckDB translation for function {.val {node$name}}.")
}

definition_duckdb_like <- function(node, state, selected) {
  operand <- definition_duckdb_child(
    node$operand,
    4L,
    "left",
    state,
    selected
  )
  if (!identical(node$pattern$kind, "string")) {
    pattern <- definition_duckdb_child(
      node$pattern,
      4L,
      "right",
      state,
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
    return(paste0(operand, op, definition_duckdb_string(pattern)))
  }
  if (count == 1L && endsWith(pattern, "%")) {
    prefix <- if (isTRUE(node$negated)) "NOT " else ""
    return(sprintf(
      "%sstarts_with(%s, %s)",
      prefix,
      definition_duckdb_child(node$operand, 0L, "free", state, selected),
      definition_duckdb_string(substr(pattern, 1L, nchar(pattern) - 1L))
    ))
  }
  if (count == 1L && startsWith(pattern, "%")) {
    prefix <- if (isTRUE(node$negated)) "NOT " else ""
    return(sprintf(
      "%sends_with(%s, %s)",
      prefix,
      definition_duckdb_child(node$operand, 0L, "free", state, selected),
      definition_duckdb_string(substr(pattern, 2L, nchar(pattern)))
    ))
  }
  regex <- definition_duckdb_like_regex(pattern)
  prefix <- if (isTRUE(node$negated)) "NOT " else ""
  sprintf(
    "%sregexp_full_match(%s, %s)",
    prefix,
    definition_duckdb_child(node$operand, 0L, "free", state, selected),
    definition_duckdb_string(regex)
  )
}

definition_duckdb_like_regex <- function(pattern) {
  chars <- strsplit(pattern, "", fixed = TRUE)[[1]]
  mapped <- vapply(
    chars,
    function(char) {
      if (identical(char, "%")) {
        ".*"
      } else if (identical(char, "_")) {
        "."
      } else if (
        char %in%
          c(
            "\\",
            ".",
            "+",
            "*",
            "?",
            "(",
            ")",
            "|",
            "[",
            "]",
            "{",
            "}",
            "^",
            "$",
            "#",
            "-",
            "&",
            "~"
          )
      ) {
        paste0("\\", char)
      } else {
        char
      }
    },
    character(1)
  )
  paste0("^", paste0(mapped, collapse = ""), "$")
}

definition_duckdb_infix <- function(lhs, rhs, op, level, state, selected) {
  paste(
    definition_duckdb_child(lhs, level, "left", state, selected),
    op,
    definition_duckdb_child(rhs, level, "right", state, selected)
  )
}

definition_duckdb_child <- function(
  node,
  parent,
  side,
  state,
  selected = NULL
) {
  own <- definition_duckdb_precedence(node)
  code <- definition_duckdb_write(node, state, selected)
  if (own < parent || (own == parent && identical(side, "right"))) {
    paste0("(", code, ")")
  } else {
    code
  }
}

definition_duckdb_precedence <- function(node) {
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

definition_duckdb_identifier <- function(path) {
  paste(
    sprintf('"%s"', gsub('"', '""', path, fixed = TRUE)),
    collapse = "."
  )
}

definition_duckdb_string <- function(value) {
  sprintf("'%s'", gsub("'", "''", value, fixed = TRUE))
}

definition_duckdb_number <- function(node) {
  if (identical(node$number_kind, "integer")) {
    return(node$value)
  }
  if (is.nan(node$value)) {
    return("CAST('NaN' AS DOUBLE)")
  }
  if (is.infinite(node$value)) {
    sign <- if (node$value < 0) "-" else ""
    return(sprintf("CAST('%sInfinity' AS DOUBLE)", sign))
  }
  text <- definition_duckdb_float(node$value)
  if (!grepl("[.eE]", text)) paste0(text, ".0") else text
}

definition_duckdb_float <- function(value) {
  exponent <- if (value == 0) 0L else floor(log10(abs(value)))
  for (significant in seq_len(17L)) {
    places <- max(0L, significant - 1L - exponent)
    candidate <- sprintf(paste0("%.", places, "f"), value)
    parsed <- tryCatch(
      jsonlite::fromJSON(candidate),
      error = function(error) NA_real_
    )
    if (!is.na(parsed) && identical(as.double(parsed), as.double(value))) {
      return(candidate)
    }
  }
  sprintf("%.17f", value)
}

definition_duckdb_note <- function(state, note) {
  state$notes <- c(state$notes, note)
  invisible(NULL)
}

definition_duckdb_nan_note <- paste(
  "DuckDB compares a NaN as equal to itself and greater than every number,",
  "where data-dict answers false; a row holding one passes here and is reported there."
)

definition_duckdb_mod_note <- paste(
  "DuckDB yields null for an integer modulus by zero, where data-dict yields",
  "a NaN."
)

definition_duckdb_sum_note <- paste(
  "DuckDB sums integers at 128 bits, so a total data-dict reports as an",
  "overflow (D09) may succeed."
)
