snowflake_test_provider <- function(name) {
  con <- DBI::dbConnect(duckdb::duckdb())
  source <- new_catalog_source(
    "source:snowflake",
    "snowflake",
    dialect = "snowflake",
    identifier_case = "upper"
  )
  relation <- new_catalog_relation(
    paste0("relation:", name),
    source$id,
    new_source_path(c("DB", "PUBLIC", name), c("catalog", "schema", "table")),
    kind = "semantic_view"
  )
  provider <- new.env(parent = emptyenv())
  provider$con <- con
  provider$catalog <- new_commons_catalog(
    sources = list(source),
    relations = list(relation)
  )
  provider$relation_labels <- stats::setNames(name, relation$id)
  provider
}
