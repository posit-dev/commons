test_semantic_model <- function(
  name = "revenue_model",
  metric = "total_revenue"
) {
  new_semantic_model(
    DBI::Id(catalog = "ANALYTICS", schema = "PUBLIC", table = name),
    name,
    description = "Revenue semantics.",
    backend = "snowflake_semantic_view",
    dimensions = list(
      new_semantic_member(
        "region",
        "dimension",
        parent = "orders",
        description = "Sales region."
      )
    ),
    metrics = list(
      new_semantic_member(
        metric,
        "metric",
        description = "Total realized revenue."
      )
    )
  )
}

test_semantic_source <- function(...) {
  source <- test_source()
  state <- data_source_state(source)
  model <- test_semantic_model(...)
  label <- table_id_label(model$id)
  state$semantic_models <- stats::setNames(list(model), label)
  source
}

# A source holding the models a shared fixture declares, keyed by label.
fixture_semantic_source <- function(models, parameters = list(), stubs = list()) {
  members <- function(entries, kind) {
    lapply(entries, function(entry) {
      new_semantic_member(
        entry$name,
        kind,
        parent = entry$parent,
        label = entry$label,
        description = entry$description,
        filter = isTRUE(entry$filter)
      )
    })
  }
  built <- lapply(models, function(model) {
    new_semantic_model(
      do.call(DBI::Id, model$id %||% list(
        catalog = "ANALYTICS",
        schema = "PUBLIC",
        table = model$label
      )),
      model$label,
      backend = "snowflake_semantic_view",
      dimensions = members(model$dimensions, "dimension"),
      metrics = members(model$metrics, "metric"),
      facts = members(model$facts, "fact"),
      filters = members(model$filters, "filter"),
      parameters = if (length(parameters)) {
        parameters
      } else if (length(model$parameters)) {
        fixture_parameters(model$parameters)
      } else {
        list()
      }
    )
  })
  source <- test_source()
  state <- data_source_state(source)
  state$semantic_models <- stats::setNames(
    built,
    vapply(models, `[[`, character(1), "label")
  )
  state$semantic_stubs <- stats::setNames(
    lapply(stubs, function(stub) {
      parts <- strsplit(stub$label, ".", fixed = TRUE)[[1]]
      new_semantic_model_stub(
        list(
          id = DBI::Id(catalog = parts[[1]], schema = parts[[2]], table = parts[[3]]),
          description = stub$description
        ),
        "snowflake_semantic_view"
      )
    }),
    vapply(stubs, `[[`, character(1), "label")
  )
  source
}

fixture_parameters <- function(specs) {
  parameters <- lapply(specs, function(spec) {
    new_typed_argument(
      spec$name,
      spec$type,
      description = spec$description,
      default = spec$default,
      has_default = isTRUE(spec$has_default)
    )
  })
  stats::setNames(parameters, vapply(specs, `[[`, character(1), "name"))
}

# Whether an error matches a shared fixture's pinned kind and mentions.
expect_fixture_error <- function(err, expected, info = NULL) {
  expect_s3_class(err, "error")
  message <- cli::ansi_strip(conditionMessage(err))
  for (mention in expected$mentions) {
    expect_true(grepl(mention, message, fixed = TRUE), info = paste(info, mention))
  }
}

# A dbGetQuery stand-in answering a Snowflake catalog listing from a shared
# fixture's `warehouse`: relations and semantic views, all in ANALYTICS.PUBLIC.
fixture_snowflake_reply <- function(warehouse) {
  views <- warehouse$semantic_views %||% list()
  relations <- unlist(warehouse$relations %||% list())
  like <- function(sql) {
    match <- regmatches(sql, regexec("LIKE '([^']*)'", sql))[[1]]
    if (length(match)) match[[2]] else NULL
  }
  function(con, sql, ...) {
    if (startsWith(sql, "SELECT CURRENT_DATABASE()")) {
      return(data.frame(CATALOG = "ANALYTICS", SCHEMA = "PUBLIC"))
    }
    if (startsWith(sql, "SHOW OBJECTS")) {
      names <- relations
      if (!is.null(like(sql))) names <- intersect(names, like(sql))
      return(data.frame(
        name = names,
        database_name = rep("ANALYTICS", length(names)),
        schema_name = rep("PUBLIC", length(names)),
        kind = rep("TABLE", length(names)),
        comment = rep("", length(names))
      ))
    }
    if (startsWith(sql, "SHOW SEMANTIC VIEWS")) {
      if (isTRUE(warehouse$semantic_listing_fails)) {
        stop("SHOW SEMANTIC VIEWS is not authorized")
      }
      names <- names(views)
      if (!is.null(like(sql))) names <- intersect(names, like(sql))
      return(data.frame(
        name = names,
        database_name = rep("ANALYTICS", length(names)),
        schema_name = rep("PUBLIC", length(names)),
        comment = rep("", length(names))
      ))
    }
    if (startsWith(sql, "SELECT SYSTEM$READ_YAML_FROM_SEMANTIC_VIEW")) {
      name <- sub('.*"([^"]*)"\'\\).*', "\\1", sql)
      return(data.frame(specification = views[[name]]))
    }
    stop("unexpected query: ", sql)
  }
}
