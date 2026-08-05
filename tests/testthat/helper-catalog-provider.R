catalog_provider_test_source <- function(kind = "table") {
  con <- DBI::dbConnect(duckdb::duckdb())
  DBI::dbWriteTable(con, "warehouse_object", data.frame(region = "EMEA"))
  source_record <- new_catalog_source("source:test", "duckdb")
  relation <- new_catalog_relation(
    "relation:test",
    source_record$id,
    new_source_path(c(table = "warehouse_object")),
    kind = kind
  )
  catalog <- new_commons_catalog(
    sources = list(source_record),
    relations = list(relation)
  )
  provider <- new.env(parent = emptyenv())
  provider$con <- con
  provider$backend <- "duckdb"
  provider$options <- data_source_options()
  provider$snapshot <- catalog_connection_snapshot(con, "duckdb")
  provider$capabilities <- list(native_semantics = TRUE)
  provider$table_ids <- list(
    warehouse_object = DBI::Id(table = "warehouse_object")
  )
  provider$relation_labels <- c("relation:test" = "warehouse_object")
  provider$selection_modes <- c("relation:test" = "namespace")
  provider$telemetry <- list()
  provider$catalog <- catalog
  provider$lazy <- FALSE
  source <- new_data_source(
    con,
    "warehouse_object",
    owned = FALSE,
    table_ids = provider$table_ids,
    catalog = catalog,
    provider = provider,
    relation_labels = provider$relation_labels
  )
  list(
    source = source,
    provider = provider,
    relation = relation,
    source_record = source_record,
    con = con
  )
}

catalog_provider_add_metric <- function(fixture, context = NULL, fields = FALSE) {
  model <- new_catalog_model(
    "model:test",
    fixture$source_record$id,
    "warehouse_model",
    datasets = fixture$relation$id,
    execution = list(
      kind = "snowflake_semantic_view",
      object = fixture$relation$path
    ),
    exposed = fixture$relation$id,
    dependencies = fixture$relation$id
  )
  definition <- new_catalog_definition(
    "definition:test",
    model$id,
    fixture$relation$id,
    "metric",
    "record_count",
    expressions = list(new_catalog_expression("snowflake", "COUNT(*)")),
    dependencies = fixture$relation$id
  )
  fixture$provider$catalog$models[[model$id]] <- model
  fixture$provider$catalog$definitions[[definition$id]] <- definition
  if (isTRUE(fields)) {
    definitions <- list(
      new_catalog_definition(
        "definition:dimension",
        model$id,
        fixture$relation$id,
        "dimension",
        "region",
        expressions = list(new_catalog_expression("snowflake", "region"))
      ),
      new_catalog_definition(
        "definition:filter",
        model$id,
        fixture$relation$id,
        "filter",
        "current_records",
        expressions = list(new_catalog_expression("snowflake", "is_current"))
      )
    )
    fixture$provider$catalog$definitions <- c(
      fixture$provider$catalog$definitions,
      stats::setNames(definitions, vapply(definitions, `[[`, character(1), "id"))
    )
  }
  if (!is.null(context)) {
    record <- new_catalog_context(
      "context:test",
      fixture$source_record$id,
      "instruction",
      context,
      scope = model$id,
      delivery = "retrieval"
    )
    fixture$provider$catalog$context[[record$id]] <- record
  }
  invisible(fixture)
}
