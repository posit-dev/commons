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
  model <- test_semantic_model(...)
  label <- table_id_label(model$id)
  source$semantic_models <- stats::setNames(list(model), label)
  source
}
