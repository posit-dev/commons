calculation_test_source <- function(parameterized = FALSE) {
  source <- test_source()
  catalog_source <- new_catalog_source(
    "source:test",
    "duckdb",
    dialect = "duckdb"
  )
  if (parameterized) {
    arguments <- list(
      region = new_catalog_argument("string"),
      column = new_catalog_argument(
        "string",
        binding = "identifier",
        choices = c("order_id", "revenue")
      )
    )
    execution <- new_catalog_execution(
      "parameterized_sql",
      "duckdb",
      "SELECT {{region}} AS region, {{column}} FROM sales LIMIT 1",
      bindings = list(
        new_catalog_binding("region", token = "{{region}}"),
        new_catalog_binding("column", "identifier", "{{column}}")
      )
    )
    calculation <- new_catalog_calculation(
      "calculation:sales_value",
      catalog_source$id,
      "sales_value",
      "Return a selected sales value by region.",
      arguments = arguments,
      execution = execution
    )
  } else {
    calculation <- new_catalog_calculation(
      "calculation:sales_count",
      catalog_source$id,
      "sales_count",
      "Count all sales.",
      execution = new_catalog_execution(
        "verified_sql",
        "duckdb",
        "SELECT count(*) AS n FROM sales"
      )
    )
  }
  source$catalog <- new_commons_catalog(
    sources = list(catalog_source),
    calculations = list(calculation)
  )
  source
}
