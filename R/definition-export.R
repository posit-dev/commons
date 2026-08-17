# This is a temporary, definition-only implementation of the contract produced
# by `data-dict export-spec`, ported against tidyverse/data-dict at
# d950c5ac90d0ab939d330600f3a5ee1bfde0f604. A definition's `expr` is written in
# data-dict's typed expression language, not in the SQL dialect of the attached
# source. Commons therefore cannot execute the source text directly: it must
# parse and type-check the expression against the authored dictionary, infer
# its kind and value type, resolve its direct column and sibling-definition
# references, and translate the checked expression through a target-specific
# emitter.
#
# Keep that work behind definition_export_spec(). The records returned here
# follow the definition portion of data-dict's JSON export: expression, kind,
# type, direct references, and translations. Only data-dict's DuckDB target is
# ported because commons does not consume its R targets. Runtime code should
# consume the export records rather than reach into the parser or typed IR. The
# implementation does not attempt to validate or export the rest of a data
# dictionary, and package checks compare it with an installed data-dict binary.
# R does not expose data-dict's Rust regex engine, so regex handling guards
# known PCRE-only constructs before compiling the remaining pattern with PCRE;
# cross-implementation conformance remains the authority.
#
# A data-dict R package wrapping the CLI's JSON interface can replace this
# adapter for the targets that interface returns. Such a wrapper may not expose
# typed IR, so commons-only SQL targets still need local lowering until
# data-dict either exposes that IR or emits those targets itself. Commons will
# continue to own source binding, sibling-translation composition, and
# invocation tokens.

definition_export_spec <- function(raw, call = rlang::caller_env()) {
  raw <- raw %||% list()
  tables <- definition_named_entries(raw$tables, "table", call = call)
  exported <- lapply(tables, definition_export_table, call = call)
  names(exported) <- names(tables)
  list(tables = exported)
}

definition_export_table <- function(table, call = rlang::caller_env()) {
  table_name <- table$name
  columns <- definition_named_entries(table$columns, "column", call = call)
  definitions <- definition_named_entries(
    table$definitions,
    "definition",
    call = call
  )
  collisions <- intersect(names(columns), names(definitions))
  if (length(collisions)) {
    cli::cli_abort(
      "Definitions on table {.val {table_name}} share names with columns: {.val {collisions}}.",
      call = call
    )
  }
  column_env <- definition_column_environment(columns, call = call)
  definitions <- definition_prepare_envelopes(
    definitions,
    table_name,
    call = call
  )
  references <- lapply(
    definitions,
    function(definition) {
      definition_direct_references(
        definition$ast,
        names(definitions),
        names(column_env)
      )$definitions
    }
  )
  resolved <- list()
  pending <- names(definitions)
  while (length(pending)) {
    ready <- pending[vapply(
      pending,
      function(name) all(references[[name]] %in% names(resolved)),
      logical(1)
    )]
    if (length(ready) == 0L) {
      cli::cli_abort(
        "Definitions on table {.val {table_name}} reference each other in a cycle: {.val {pending}}.",
        call = call
      )
    }
    for (name in ready) {
      resolved[[name]] <- definition_resolve_one(
        definitions[[name]],
        table_name,
        column_env,
        resolved,
        names(definitions),
        call = call
      )
    }
    pending <- setdiff(pending, ready)
  }
  list(
    name = table_name,
    definitions = unname(resolved[names(definitions)])
  )
}

definition_prepare_envelopes <- function(definitions, table, call) {
  lapply(definitions, function(definition) {
    name <- definition$name
    expression <- definition$expr
    if (!rlang::is_string(expression) || !nzchar(trimws(expression))) {
      cli::cli_abort(
        "Definition {.val {name}} on table {.val {table}} needs a non-empty {.field expr}.",
        call = call
      )
    }
    for (field in c("label", "description", "details", "todo")) {
      value <- definition[[field]]
      if (!is.null(value) && !rlang::is_string(value)) {
        cli::cli_abort(
          "Definition {.val {name}} on table {.val {table}} has a non-string {.field {field}}.",
          call = call
        )
      }
    }
    definition$ast <- tryCatch(
      definition_expr_parse(expression, call = call),
      error = function(error) {
        cli::cli_abort(
          "Definition {.val {name}} on table {.val {table}} has an invalid expression.",
          parent = error,
          call = call
        )
      }
    )
    definition
  })
}

definition_resolve_one <- function(
  definition,
  table,
  columns,
  resolved,
  definition_names,
  call
) {
  state <- new.env(parent = emptyenv())
  state$selection <- NULL
  state$selection_count <- 0L
  state$definition_selection_count <- 0L
  env <- list(columns = columns, definitions = resolved)
  ir <- tryCatch(
    definition_check_node(definition$ast, env, state, call = call),
    error = function(error) {
      cli::cli_abort(
        "Definition {.val {definition$name}} on table {.val {table}} does not type-check.",
        parent = error,
        call = call
      )
    }
  )
  total_selections <- state$selection_count + state$definition_selection_count
  if (total_selections > 1L) {
    cli::cli_abort(
      "Definition {.val {definition$name}} on table {.val {table}} recursively uses more than one {.code COLUMNS(...)} selection.",
      call = call
    )
  }
  if (total_selections > 0L && !ir$type %in% c("boolean", "any")) {
    cli::cli_abort(
      "Definition {.val {definition$name}} on table {.val {table}} uses {.code COLUMNS(...)} but is not a boolean filter.",
      call = call
    )
  }
  if (identical(ir$kind, "selected")) {
    definition_require_selection(state$selection, "boolean", "a filter", call)
  }
  if (identical(ir$type, "unknown")) {
    cli::cli_abort(
      "Definition {.val {definition$name}} on table {.val {table}} has no inferred type.",
      call = call
    )
  }
  references <- definition_direct_references(
    definition$ast,
    definition_names,
    names(columns),
    columns
  )
  emitted <- definition_emit_duckdb(ir, state$selection)
  kind <- if (ir$shape %in% c("agg", "const")) {
    "metric"
  } else if (identical(ir$type, "boolean")) {
    "filter"
  } else {
    "derived"
  }
  out <- list(
    name = definition$name,
    label = definition$label,
    description = definition$description,
    details = definition$details,
    todo = definition$todo,
    expression = definition$expr,
    kind = kind,
    type = definition_export_type(ir$type),
    columns = references$columns,
    definitions = references$definitions,
    translations = list(list(
      target = "SQL(duckdb)",
      code = emitted$code,
      error = NULL,
      notes = emitted$notes
    ))
  )
  attr(out, "ir") <- ir
  attr(out, "shape") <- ir$shape
  attr(out, "selection") <- state$selection
  attr(out, "selection_count") <- total_selections
  out
}

definition_check_node <- function(
  node,
  env,
  state,
  call = rlang::caller_env()
) {
  kind <- node$kind
  if (identical(kind, "number")) {
    return(definition_ir(node, "number", "const"))
  }
  if (identical(kind, "string")) {
    return(definition_ir(node, "string", "const"))
  }
  if (identical(kind, "boolean")) {
    return(definition_ir(node, "boolean", "const"))
  }
  if (identical(kind, "null")) {
    return(definition_ir(node, "any", "const"))
  }
  if (identical(kind, "now")) {
    return(definition_ir(node, "datetime", "const"))
  }
  if (identical(kind, "column")) {
    return(definition_check_reference(node, env, state, call))
  }
  if (identical(kind, "columns")) {
    selection <- definition_resolve_selection(node$selector, env$columns, call)
    state$selection_count <- state$selection_count + 1L
    if (state$selection_count > 1L) {
      cli::cli_abort(
        "An expression may use at most one {.code COLUMNS(...)}.",
        call = call
      )
    }
    state$selection <- selection
    return(definition_ir(
      node,
      "any",
      "row",
      .kind = "selected",
      selection = selection
    ))
  }
  if (kind %in% c("negate", "not")) {
    operand <- definition_check_node(node$operand, env, state, call)
    if (identical(kind, "negate")) {
      definition_require(operand, "number", "negation", call)
      return(definition_ir(
        node,
        "number",
        operand$shape,
        operand = operand
      ))
    }
    definition_require(operand, "boolean", "`NOT`", call)
    return(definition_ir(
      node,
      "boolean",
      operand$shape,
      operand = operand
    ))
  }
  if (kind %in% c("and", "or")) {
    lhs <- definition_check_node(node$lhs, env, state, call)
    rhs <- definition_check_node(node$rhs, env, state, call)
    definition_require(lhs, "boolean", "a logical operator", call)
    definition_require(rhs, "boolean", "a logical operator", call)
    return(definition_ir(
      node,
      "boolean",
      definition_shape_max(lhs$shape, rhs$shape),
      lhs = lhs,
      rhs = rhs
    ))
  }
  if (identical(kind, "arithmetic")) {
    lhs <- definition_check_node(node$lhs, env, state, call)
    rhs <- definition_check_node(node$rhs, env, state, call)
    temporal_shift <- node$op %in%
      c("+", "-") &&
      ((lhs$type %in%
        c("date", "datetime") &&
        rhs$type %in% c("interval", "any")) ||
        (rhs$type %in%
          c("date", "datetime") &&
          lhs$type %in% c("interval", "any")))
    if (temporal_shift) {
      type <- "datetime"
    } else {
      definition_require(lhs, "number", "arithmetic", call)
      definition_require(rhs, "number", "arithmetic", call)
      type <- "number"
    }
    return(definition_ir(
      node,
      type,
      definition_shape_max(lhs$shape, rhs$shape),
      lhs = lhs,
      rhs = rhs
    ))
  }
  if (identical(kind, "compare")) {
    operands <- definition_check_comparable(
      node$lhs,
      node$rhs,
      env,
      state,
      call
    )
    return(definition_ir(
      node,
      "boolean",
      definition_shape_max(operands$lhs$shape, operands$rhs$shape),
      lhs = operands$lhs,
      rhs = operands$rhs
    ))
  }
  if (identical(kind, "is_null")) {
    operand <- definition_check_node(node$operand, env, state, call)
    return(definition_ir(
      node,
      "boolean",
      operand$shape,
      operand = operand
    ))
  }
  if (identical(kind, "between")) {
    operand <- definition_check_node(node$operand, env, state, call)
    lo <- definition_check_node(node$lo, env, state, call)
    hi <- definition_check_node(node$hi, env, state, call)
    lower <- definition_comparable_ir(operand, lo, call)
    definition_comparable_ir(operand, hi, call)
    upper <- definition_coerce_temporal_pair(lower$lhs, hi)
    shape <- definition_shape_max(
      lower$lhs$shape,
      lower$rhs$shape,
      upper$rhs$shape
    )
    return(definition_ir(
      node,
      "boolean",
      shape,
      operand = upper$lhs,
      lo = lower$rhs,
      hi = upper$rhs
    ))
  }
  if (identical(kind, "in")) {
    operand <- definition_check_node(node$operand, env, state, call)
    items <- lapply(
      node$items,
      definition_check_node,
      env = env,
      state = state,
      call = call
    )
    for (i in seq_along(items)) {
      pair <- definition_comparable_ir(operand, items[[i]], call)
      items[[i]] <- pair$rhs
    }
    if (length(items)) {
      operand <- definition_coerce_temporal(operand, items[[1]]$type)
    }
    return(definition_ir(
      node,
      "boolean",
      do.call(
        definition_shape_max,
        c(list(operand$shape), lapply(items, `[[`, "shape"))
      ),
      operand = operand,
      items = items
    ))
  }
  if (kind %in% c("like", "similar")) {
    operand <- definition_check_node(node$operand, env, state, call)
    pattern <- definition_check_node(node$pattern, env, state, call)
    definition_require(operand, "string", sprintf("`%s`", toupper(kind)), call)
    definition_require(
      pattern,
      "string",
      sprintf("a `%s` pattern", toupper(kind)),
      call
    )
    if (identical(kind, "similar") && identical(pattern$kind, "string")) {
      definition_validate_regex(pattern$value, call)
    }
    return(definition_ir(
      node,
      "boolean",
      definition_shape_max(operand$shape, pattern$shape),
      operand = operand,
      pattern = pattern
    ))
  }
  if (identical(kind, "interval")) {
    n <- definition_check_node(node$n, env, state, call)
    definition_require(n, "number", "`INTERVAL`", call)
    if (!node$unit %in% c("seconds", "minutes", "hours", "days", "weeks")) {
      cli::cli_abort(
        "{.val {node$unit}} is not an interval unit; use seconds, minutes, hours, days, or weeks.",
        call = call
      )
    }
    return(definition_ir(node, "interval", n$shape, n = n))
  }
  if (identical(kind, "function")) {
    return(definition_check_function(node, env, state, call))
  }
  if (identical(kind, "case")) {
    whens <- lapply(node$whens, function(branch) {
      condition <- definition_check_node(branch$condition, env, state, call)
      result <- definition_check_node(branch$result, env, state, call)
      definition_require(condition, "boolean", "a `CASE` condition", call)
      list(condition = condition, result = result)
    })
    otherwise <- if (!is.null(node$otherwise)) {
      definition_check_node(node$otherwise, env, state, call)
    }
    result_types <- c(
      vapply(whens, function(branch) branch$result$type, character(1)),
      if (!is.null(otherwise)) otherwise$type
    )
    type <- definition_common_type(result_types)
    shapes <- c(
      unlist(lapply(whens, function(branch) {
        c(branch$condition$shape, branch$result$shape)
      })),
      if (!is.null(otherwise)) otherwise$shape
    )
    return(definition_ir(
      node,
      type,
      do.call(definition_shape_max, as.list(shapes)),
      whens = whens,
      otherwise = otherwise
    ))
  }
  cli::cli_abort("Unknown expression node {.val {kind}}.", call = call)
}

definition_check_reference <- function(node, env, state, call) {
  path <- node$path
  if (length(path) == 1L && !path[[1]] %in% names(env$columns)) {
    definition <- env$definitions[[path[[1]]]]
    if (is.null(definition)) {
      cli::cli_abort("Column {.val {path[[1]]}} not found.", call = call)
    }
    state$definition_selection_count <- state$definition_selection_count +
      (attr(definition, "selection_count") %||% 0L)
    return(definition_ir(
      node,
      definition$type %||% "any",
      attr(definition, "shape") %||% "row",
      reference = "definition"
    ))
  }
  column <- env$columns[[path[[1]]]]
  if (is.null(column)) {
    cli::cli_abort("Column {.val {path[[1]]}} not found.", call = call)
  }
  current <- column
  if (length(path) > 1L) {
    for (i in seq.int(2L, length(path))) {
      prefix <- paste(path[seq_len(i - 1L)], collapse = ".")
      if (identical(current$type, "list")) {
        cli::cli_abort(
          "{.val {prefix}} is a list, whose elements cannot be referenced.",
          call = call
        )
      }
      if (!identical(current$type, "struct")) {
        cli::cli_abort("{.val {prefix}} is not a struct.", call = call)
      }
      current <- current$fields[[path[[i]]]]
      if (is.null(current)) {
        cli::cli_abort(
          "Struct {.val {prefix}} has no field {.val {path[[i]]}}.",
          call = call
        )
      }
    }
  }
  definition_ir(
    node,
    current$type,
    "row",
    reference = "column"
  )
}

definition_check_function <- function(node, env, state, call) {
  signature <- definition_function_signatures[[node$name]]
  if (is.null(signature)) {
    cli::cli_abort("Unknown function {.val {node$name}}.", call = call)
  }
  if (!length(node$args) %in% signature$arities) {
    expected <- paste(signature$arities, collapse = " or ")
    cli::cli_abort(
      "{.code {toupper(node$name)}()} takes {expected} argument(s), not {length(node$args)}.",
      call = call
    )
  }
  args <- lapply(
    node$args,
    definition_check_node,
    env = env,
    state = state,
    call = call
  )
  if (!isTRUE(signature$unconstrained)) {
    for (arg in args) {
      definition_require(
        arg,
        signature$types,
        sprintf("`%s`", toupper(node$name)),
        call
      )
    }
  }
  if (
    isTRUE(signature$aggregate) &&
      any(vapply(args, function(arg) identical(arg$shape, "agg"), logical(1)))
  ) {
    cli::cli_abort(
      "{.code {toupper(node$name)}()} cannot aggregate an expression that is already aggregated.",
      call = call
    )
  }
  type <- if (identical(signature$return, "same")) {
    args[[1]]$type %||% "any"
  } else {
    signature[["return"]]
  }
  shape <- if (isTRUE(signature$aggregate)) {
    "agg"
  } else {
    do.call(definition_shape_max, lapply(args, `[[`, "shape"))
  }
  definition_ir(node, type, shape, args = args)
}

definition_check_comparable <- function(lhs, rhs, env, state, call) {
  lhs <- definition_check_node(lhs, env, state, call)
  rhs <- definition_check_node(rhs, env, state, call)
  definition_comparable_ir(lhs, rhs, call)
}

definition_comparable_ir <- function(lhs, rhs, call) {
  if (identical(lhs$kind, "selected")) {
    definition_require_selection_comparable(lhs$selection, rhs, call)
  }
  if (identical(rhs$kind, "selected")) {
    definition_require_selection_comparable(rhs$selection, lhs, call)
  }
  operands <- definition_coerce_temporal_pair(lhs, rhs)
  if (!definition_types_comparable(operands$lhs$type, operands$rhs$type)) {
    cli::cli_abort(
      "Cannot compare {.val {operands$lhs$type}} with {.val {operands$rhs$type}}.",
      call = call
    )
  }
  operands
}

definition_coerce_temporal_pair <- function(lhs, rhs) {
  lhs_type <- lhs$type
  rhs_type <- rhs$type
  lhs <- definition_coerce_temporal(lhs, rhs_type)
  rhs <- definition_coerce_temporal(rhs, lhs_type)
  list(lhs = lhs, rhs = rhs)
}

definition_require_selection_comparable <- function(selection, other, call) {
  for (column in selection$columns) {
    if (identical(column$type, "unknown")) {
      cli::cli_abort(
        "Column {.val {column$name}} has no declared type.",
        call = call
      )
    }
    value <- definition_ir(
      list(kind = "column", path = column$path),
      column$type,
      "row"
    )
    other_value <- definition_coerce_temporal(other, column$type)
    if (!definition_types_comparable(value$type, other_value$type)) {
      cli::cli_abort(
        "Column {.val {column$name}} cannot be compared with {.val {other$type}}.",
        call = call
      )
    }
  }
  invisible(NULL)
}

definition_types_comparable <- function(lhs, rhs) {
  if (lhs %in% c("struct", "list") || rhs %in% c("struct", "list")) {
    return(FALSE)
  }
  lhs %in%
    c("any", rhs) ||
    rhs == "any" ||
    (lhs %in% c("date", "datetime") && rhs %in% c("date", "datetime"))
}

definition_coerce_temporal <- function(ir, target) {
  if (!identical(ir$kind, "string")) {
    return(ir)
  }
  if (identical(target, "date") && definition_is_date(ir$value)) {
    ir$kind <- "date"
    ir$type <- "date"
  }
  if (identical(target, "datetime")) {
    value <- definition_as_datetime(ir$value)
    if (!is.null(value)) {
      ir$kind <- "datetime"
      ir$type <- "datetime"
      ir$value <- value
    }
  }
  ir
}

definition_require <- function(ir, types, context, call) {
  if (identical(ir$kind, "selected")) {
    definition_require_selection(ir$selection, types, context, call)
    return(invisible(ir$type))
  }
  if (identical(ir$type, "unknown")) {
    path <- paste(ir$path %||% "value", collapse = ".")
    cli::cli_abort("{.val {path}} has no declared type.", call = call)
  }
  if (!ir$type %in% c("any", types)) {
    cli::cli_abort(
      "{context} expects {.or {.val {types}}}, not {.val {ir$type}}.",
      call = call
    )
  }
  invisible(ir$type)
}

definition_require_selection <- function(selection, types, context, call) {
  for (column in selection$columns) {
    if (identical(column$type, "unknown")) {
      cli::cli_abort(
        "Column {.val {column$name}} has no declared type.",
        call = call
      )
    }
    if (!column$type %in% c("any", types)) {
      cli::cli_abort(
        "{context} expects {.or {.val {types}}}, but column {.val {column$name}} is {.val {column$type}}.",
        call = call
      )
    }
  }
  invisible(NULL)
}

definition_resolve_selection <- function(selector, columns, call) {
  names <- names(columns)
  if (identical(selector$kind, "regex")) {
    definition_validate_regex(selector$pattern, call)
    names <- names[vapply(
      names,
      function(name) grepl(selector$pattern, name, perl = TRUE),
      logical(1)
    )]
  }
  if (identical(selector$kind, "list")) {
    missing <- setdiff(selector$names, names)
    if (length(missing)) {
      cli::cli_abort("Columns not found: {.val {missing}}.", call = call)
    }
    names <- selector$names
  }
  list(
    form = selector$kind,
    pattern = selector$pattern,
    columns = unname(lapply(names, function(name) {
      list(name = name, path = name, type = columns[[name]]$type)
    }))
  )
}

definition_validate_regex <- function(pattern, call) {
  # Guard PCRE extensions that data-dict's Rust regex engine would reject.
  unsupported <- grepl(
    "\\(\\?(?:[=!>]|<[=!])|\\\\[1-9]",
    pattern,
    perl = TRUE
  )
  valid <- tryCatch(
    {
      grepl(pattern, "", perl = TRUE)
      TRUE
    },
    error = function(error) FALSE,
    warning = function(warning) FALSE
  )
  if (unsupported || !valid) {
    cli::cli_abort(
      "Invalid data-dict regular expression {.val {pattern}}.",
      call = call
    )
  }
  invisible(pattern)
}

definition_direct_references <- function(
  ast,
  definition_names,
  column_names,
  columns = NULL
) {
  out <- new.env(parent = emptyenv())
  out$columns <- character()
  out$definitions <- character()
  definition_ast_walk(ast, function(node) {
    if (identical(node$kind, "column")) {
      if (
        length(node$path) == 1L &&
          node$path[[1]] %in% definition_names &&
          !node$path[[1]] %in% column_names
      ) {
        out$definitions <- definition_append_unique(
          out$definitions,
          node$path[[1]]
        )
      } else {
        out$columns <- definition_append_unique(
          out$columns,
          paste(node$path, collapse = ".")
        )
      }
    }
    if (identical(node$kind, "columns") && !is.null(columns)) {
      selected <- definition_resolve_selection(
        node$selector,
        columns,
        rlang::caller_env()
      )
      selected <- vapply(selected$columns, `[[`, character(1), "name")
      if (!identical(node$selector$kind, "list")) {
        selected <- selected[vapply(
          selected,
          function(name) !identical(columns[[name]]$type, "unknown"),
          logical(1)
        )]
      }
      for (name in selected) {
        out$columns <- definition_append_unique(out$columns, name)
      }
    }
  })
  list(columns = out$columns, definitions = out$definitions)
}

definition_ast_walk <- function(node, fn) {
  fn(node)
  children <- switch(
    node$kind,
    negate = list(node$operand),
    not = list(node$operand),
    and = list(node$lhs, node$rhs),
    or = list(node$lhs, node$rhs),
    arithmetic = list(node$lhs, node$rhs),
    compare = list(node$lhs, node$rhs),
    is_null = list(node$operand),
    between = list(node$operand, node$lo, node$hi),
    `in` = c(list(node$operand), node$items),
    like = list(node$operand, node$pattern),
    similar = list(node$operand, node$pattern),
    interval = list(node$n),
    `function` = node$args,
    case = c(
      unlist(
        lapply(node$whens, function(branch) {
          list(branch$condition, branch$result)
        }),
        recursive = FALSE
      ),
      if (!is.null(node$otherwise)) list(node$otherwise)
    ),
    list()
  )
  for (child in children) {
    definition_ast_walk(child, fn)
  }
  invisible(NULL)
}

definition_named_entries <- function(
  entries,
  what,
  call = rlang::caller_env()
) {
  if (length(entries) == 0L) {
    return(list())
  }
  if (!is.list(entries)) {
    cli::cli_abort("The data dictionary's {what}s must be a list.", call = call)
  }
  out <- list()
  for (entry in entries) {
    if (
      !is.list(entry) || !rlang::is_string(entry$name) || !nzchar(entry$name)
    ) {
      cli::cli_abort(
        "Each {what} needs a non-empty {.field name}.",
        call = call
      )
    }
    if (entry$name %in% names(out)) {
      cli::cli_abort("Duplicate {what} name {.val {entry$name}}.", call = call)
    }
    out[[entry$name]] <- entry
  }
  out
}

definition_column_environment <- function(columns, call = rlang::caller_env()) {
  out <- lapply(columns, definition_column_descriptor, call = call)
  names(out) <- names(columns)
  out
}

definition_column_descriptor <- function(column, call = rlang::caller_env()) {
  type <- column$type
  if (is.null(type)) {
    kind <- "unknown"
  } else if (!rlang::is_string(type) || !nzchar(type)) {
    cli::cli_abort(
      "Column {.val {column$name}} has an invalid type.",
      call = call
    )
  } else {
    lower <- tolower(type)
    kind <- if (startsWith(lower, "number")) {
      "number"
    } else if (identical(lower, "enum")) {
      "string"
    } else if (startsWith(lower, "list(")) {
      "list"
    } else if (
      lower %in% c("string", "boolean", "date", "datetime", "struct")
    ) {
      lower
    } else {
      cli::cli_abort(
        "Column {.val {column$name}} has unsupported type {.val {type}}.",
        call = call
      )
    }
  }
  fields <- if (identical(kind, "struct")) {
    nested <- definition_named_entries(column$fields, "field", call = call)
    lapply(nested, definition_column_descriptor, call = call)
  } else {
    list()
  }
  list(type = kind, fields = fields)
}

definition_ir <- function(.node, .type, .shape, ..., .kind = .node$kind) {
  fields <- list(...)
  .node[names(fields)] <- fields
  .node$kind <- .kind
  .node$type <- .type
  .node$shape <- .shape
  .node
}

definition_common_type <- function(types) {
  types <- types[types != "any"]
  if (length(types) == 0L) {
    return("any")
  }
  if ("unknown" %in% types) {
    return("unknown")
  }
  if (length(unique(types)) == 1L) unique(types) else "any"
}

definition_shape_max <- function(...) {
  shapes <- unlist(list(...), use.names = FALSE)
  if (length(shapes) == 0L) {
    return("const")
  }
  levels <- c(const = 1L, agg = 2L, row = 3L)
  names(which.max(levels[shapes]))
}

definition_append_unique <- function(x, value) {
  if (value %in% x) x else c(x, value)
}

definition_export_type <- function(type) {
  if (
    type %in% c("number", "string", "boolean", "date", "datetime", "interval")
  ) {
    type
  }
}

definition_is_date <- function(value) {
  if (!grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", value)) {
    return(FALSE)
  }
  parsed <- suppressWarnings(as.Date(value))
  !is.na(parsed) && identical(format(parsed, "%Y-%m-%d"), value)
}

definition_as_datetime <- function(value) {
  pattern <- paste0(
    "^([0-9]{4}-[0-9]{2}-[0-9]{2})[Tt]",
    "([0-9]{2}:[0-9]{2}:[0-9]{2})",
    "(\\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})?$"
  )
  match <- regexec(pattern, value, perl = TRUE)
  pieces <- regmatches(value, match)[[1]]
  if (!length(pieces)) {
    return(NULL)
  }
  date <- pieces[[2]]
  time <- pieces[[3]]
  fraction <- definition_datetime_fraction(pieces[[4]])
  offset <- pieces[[5]]
  offset <- if (!nzchar(offset) || tolower(offset) == "z") {
    "+0000"
  } else {
    gsub(":", "", offset, fixed = TRUE)
  }
  normalized <- paste0(date, "T", time, offset)
  parsed <- suppressWarnings(as.POSIXct(
    normalized,
    format = "%Y-%m-%dT%H:%M:%S%z",
    tz = "UTC"
  ))
  if (is.na(parsed)) {
    return(NULL)
  }
  paste0(format(parsed, "%Y-%m-%d %H:%M:%S", tz = "UTC"), fraction)
}

definition_datetime_fraction <- function(fraction) {
  if (!nzchar(fraction)) {
    return("")
  }
  digits <- substr(substring(fraction, 2L), 1L, 9L)
  nanoseconds <- as.integer(paste0(digits, strrep("0", 9L - nchar(digits))))
  if (nanoseconds == 0L) {
    ""
  } else if (nanoseconds %% 1000000L == 0L) {
    sprintf(".%03d", nanoseconds %/% 1000000L)
  } else if (nanoseconds %% 1000L == 0L) {
    sprintf(".%06d", nanoseconds %/% 1000L)
  } else {
    sprintf(".%09d", nanoseconds)
  }
}

definition_function_signatures <- list(
  length = list(arities = 1L, types = "string", return = "number"),
  lower = list(arities = 1L, types = "string", return = "string"),
  upper = list(arities = 1L, types = "string", return = "string"),
  trim = list(arities = 1L, types = "string", return = "string"),
  starts_with = list(arities = 2L, types = "string", return = "boolean"),
  ends_with = list(arities = 2L, types = "string", return = "boolean"),
  abs = list(arities = 1L, types = "number", return = "number"),
  floor = list(arities = 1L, types = "number", return = "number"),
  ceil = list(arities = 1L, types = "number", return = "number"),
  round = list(arities = c(1L, 2L), types = "number", return = "number"),
  mod = list(arities = 2L, types = "number", return = "number"),
  is_finite = list(arities = 1L, types = "number", return = "boolean"),
  is_infinite = list(arities = 1L, types = "number", return = "boolean"),
  is_nan = list(arities = 1L, types = "number", return = "boolean"),
  min = list(
    arities = 1L,
    types = c("number", "string", "date", "datetime"),
    return = "same",
    aggregate = TRUE
  ),
  max = list(
    arities = 1L,
    types = c("number", "string", "date", "datetime"),
    return = "same",
    aggregate = TRUE
  ),
  sum = list(
    arities = 1L,
    types = "number",
    return = "number",
    aggregate = TRUE
  ),
  avg = list(
    arities = 1L,
    types = "number",
    return = "number",
    aggregate = TRUE
  ),
  count = list(
    arities = 1L,
    return = "number",
    aggregate = TRUE,
    unconstrained = TRUE
  ),
  row_count = list(
    arities = 0L,
    return = "number",
    aggregate = TRUE,
    unconstrained = TRUE
  ),
  count_distinct = list(
    arities = 1L,
    types = c("number", "string", "date", "datetime"),
    return = "number",
    aggregate = TRUE
  ),
  any = list(
    arities = 1L,
    types = "boolean",
    return = "boolean",
    aggregate = TRUE
  ),
  all = list(
    arities = 1L,
    types = "boolean",
    return = "boolean",
    aggregate = TRUE
  )
)
