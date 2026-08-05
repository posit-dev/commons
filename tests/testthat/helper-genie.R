genie_test_provider <- function() {
  con <- DBI::dbConnect(duckdb::duckdb())
  source <- new_catalog_source(
    "source:databricks",
    "databricks",
    dialect = "databricks",
    principal = "executor@example.com",
    namespace = list(catalog = "samples", schema = "nyctaxi")
  )
  columns <- list(
    new_catalog_column("pickup_zip"),
    new_catalog_column("rider_email", examples = "rider@example.com")
  )
  relation <- new_catalog_relation(
    "relation:trips",
    source$id,
    new_source_path(
      c("samples", "nyctaxi", "trips"),
      c("catalog", "schema", "table")
    ),
    columns = columns,
    access = new_catalog_access("queryable", "test fixture")
  )
  provider <- new.env(parent = emptyenv())
  provider$con <- con
  provider$catalog <- new_commons_catalog(
    sources = list(source),
    relations = list(relation),
    provider = provider
  )
  provider$relation_labels <- c("relation:trips" = "trips")
  provider$telemetry <- list()
  provider$snapshot <- list(
    principal = "executor@example.com",
    namespace = list(catalog = "samples", schema = "nyctaxi")
  )
  provider
}
