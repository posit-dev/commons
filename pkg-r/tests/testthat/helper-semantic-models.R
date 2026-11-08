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
fixture_semantic_source <- function(models, parameters = list()) {
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
      parameters = parameters
    )
  })
  source <- test_source()
  state <- data_source_state(source)
  state$semantic_models <- stats::setNames(
    built,
    vapply(models, `[[`, character(1), "label")
  )
  source
}

# Whether an error matches a shared fixture's pinned kind and mentions.
expect_fixture_error <- function(err, expected, info = NULL) {
  expect_s3_class(err, "error")
  message <- cli::ansi_strip(conditionMessage(err))
  for (mention in expected$mentions) {
    expect_true(grepl(mention, message, fixed = TRUE), info = paste(info, mention))
  }
}
