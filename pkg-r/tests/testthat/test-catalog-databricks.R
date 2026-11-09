test_that("Databricks catalog rows match the shared contract", {
  spec <- shared_fixture("catalog-rows")$databricks

  catalog_rows_expect_relations(
    databricks_relations_from_information_schema(
      catalog_rows_frame(spec$relations$rows)
    ),
    spec$relations$expected,
    "databricks relations"
  )
  nullable <- vapply(spec$columns$nullable, function(x) x == "true", logical(1))
  catalog_rows_expect_columns(
    databricks_columns_from_describe(
      catalog_rows_frame(spec$columns$rows),
      nullable
    ),
    spec$columns$expected,
    "databricks columns"
  )
})

test_that("Databricks ODBC metadata identifies metric views", {
  rows <- data.frame(
    table_catalog = rep("main", 3),
    table_schema = rep("analytics", 3),
    table_name = c("orders", "summary", "sales_metrics"),
    table_type = c("MANAGED", "VIEW", "VIEW"),
    comment = c("", "", "Governed sales metrics."),
    stringsAsFactors = FALSE
  )
  object_types <- stats::setNames(
    c("table", "view", "metric view"),
    databricks_object_key(
      "analytics",
      c("orders", "summary", "sales_metrics")
    )
  )

  relations <- databricks_relations_from_information_schema(
    rows,
    object_types
  )

  expect_equal(
    vapply(relations, `[[`, character(1), "kind"),
    c("table", "view", "metric_view")
  )
  expect_equal(relations[[3]]$description, "Governed sales metrics.")
})

test_that("Databricks information schema identifies a metric view ODBC calls a view", {
  rows <- data.frame(
    table_catalog = "main",
    table_schema = "analytics",
    table_name = "sales_metrics",
    table_type = "METRIC_VIEW",
    comment = "",
    stringsAsFactors = FALSE
  )
  object_types <- stats::setNames(
    "VIEW",
    databricks_object_key("analytics", "sales_metrics")
  )

  relations <- databricks_relations_from_information_schema(rows, object_types)

  expect_equal(relations[[1]]$kind, "metric_view")
})

test_that("Databricks normalizes information schema names before ODBC lookup", {
  schemas <- NULL
  local_mocked_bindings(
    dbGetQuery = function(...) {
      data.frame(
        TABLE_CATALOG = "main",
        TABLE_SCHEMA = "analytics",
        TABLE_NAME = "sales_metrics",
        TABLE_TYPE = "VIEW",
        COMMENT = "",
        stringsAsFactors = FALSE
      )
    },
    .package = "DBI"
  )
  local_mocked_bindings(
    databricks_odbc_object_types = function(con, catalog, candidate_schemas) {
      schemas <<- candidate_schemas
      stats::setNames(
        "metric view",
        databricks_object_key("analytics", "sales_metrics")
      )
    }
  )

  relations <- databricks_list_unity_relations(
    DBI::ANSI(),
    DBI::Id(catalog = "main", schema = "analytics")
  )

  expect_equal(schemas, "analytics")
  expect_equal(relations[[1]]$kind, "metric_view")
})

test_that("Databricks metric YAML expands wildcard fields from metadata", {
  specification <- list(
    version = 1.1,
    comment = "Governed sales metrics.",
    fields = list(
      list(expr = "source.*"),
      list(
        name = "region",
        expr = "customer_region",
        comment = "Customer region.",
        display_name = "Sales Region",
        synonyms = c("territory", "market")
      )
    ),
    measures = list(
      list(
        name = "order_count",
        expr = "COUNT(*)",
        comment = "Number of orders."
      )
    )
  )
  id <- DBI::Id(
    catalog = "main",
    schema = "analytics",
    table = "sales_metrics"
  )
  columns <- list(
    list(
      name = "order_id",
      type = list(name = "bigint"),
      comment = "Order identifier."
    ),
    list(name = "region", type = list(name = "string")),
    list(
      name = "order_count",
      type = list(name = "bigint"),
      is_measure = TRUE
    )
  )

  model <- databricks_semantic_model_from_spec(
    id,
    specification,
    columns = columns
  )

  expect_s3_class(model, "commons_semantic_model")
  expect_equal(model$backend, "databricks_metric_view")
  expect_equal(model$description, "Governed sales metrics.")
  expect_equal(
    vapply(model$dimensions, `[[`, character(1), "name"),
    c("region", "order_id")
  )
  expect_equal(model$dimensions[[1]]$label, "Sales Region")
  expect_equal(model$dimensions[[1]]$synonyms, c("territory", "market"))
  expect_equal(model$dimensions[[2]]$type, "bigint")
  expect_equal(model$dimensions[[2]]$description, "Order identifier.")
  expect_equal(
    vapply(model$metrics, `[[`, character(1), "name"),
    "order_count"
  )
})

test_that("Databricks metric scope retains source and join dependencies", {
  specification <- list(
    version = 1.1,
    comment = "Governed order metrics.",
    ai_context = "Treat returned orders as active.",
    source = "main.sales.orders",
    filter = "source.is_active",
    joins = list(list(
      name = "customer",
      source = "main.sales.customers",
      on = "source.customer_id = customer.id",
      joins = list(list(
        name = "region",
        source = "`main`.`sales`.`sales regions`",
        using = "region_id"
      ))
    )),
    fields = list(list(name = "region", expr = "region.name")),
    measures = list(list(name = "revenue", expr = "SUM(source.revenue)"))
  )
  id <- DBI::Id(
    catalog = "main",
    schema = "sales",
    table = "order_metrics"
  )

  model <- databricks_semantic_model_from_spec(id, specification)

  expect_true(model$dependencies_complete)
  expect_equal(
    vapply(model$dependencies, table_id_label, character(1)),
    c(
      "main.sales.orders",
      "main.sales.customers",
      "main.sales.sales regions"
    )
  )
  expect_equal(model$relationships, specification$joins)
  expect_length(model$filters, 0L)
  expect_true(any(grepl(
    "Metric-view filter: source.is_active",
    model$context$first_touch,
    fixed = TRUE
  )))
  expect_true(any(grepl("Treat returned orders", model$context$retrieval)))
  expect_true(any(grepl("customer", model$context$first_touch)))
  expect_true(any(grepl("sales regions", model$context$retrieval)))
})

test_that("Databricks query-backed metrics fail closed for association", {
  model <- databricks_semantic_model_from_spec(
    DBI::Id(catalog = "main", schema = "sales", table = "order_metrics"),
    list(
      version = 1.1,
      source = "SELECT * FROM main.sales.orders",
      measures = list(list(name = "orders", expr = "COUNT(1)"))
    )
  )

  expect_false(model$dependencies_complete)
  expect_false(semantic_model_in_scope(
    model,
    list(list(id = DBI::Id(
      catalog = "main",
      schema = "sales",
      table = "orders"
    )))
  ))
})

test_that("Databricks rejects metric semantics it cannot query faithfully", {
  id <- DBI::Id(
    catalog = "main",
    schema = "analytics",
    table = "sales_metrics"
  )

  expect_error(
    databricks_semantic_model_from_spec(
      id,
      list(version = 1.1, fields = list(list(expr = "source.*")))
    ),
    "wildcard members require concrete column metadata",
    fixed = TRUE
  )
})

test_that("Databricks imports and binds metric-view parameters", {
  model <- databricks_semantic_model_from_spec(
    DBI::Id(
      catalog = "main",
      schema = "analytics",
      table = "sales_metrics"
    ),
    list(
      version = 1.1,
      parameters = list(list(
        name = "minimum_amount",
        data_type = "DECIMAL(10,2)",
        default = 10
      )),
      measures = list(list(name = "revenue", expr = "SUM(revenue)"))
    )
  )
  source <- test_source()
  state <- data_source_state(source)
  state$semantic_models <- list(model = model)
  members <- registry_semantic_members(
    semantic_models_registry(list(databricks = source))
  )
  metrics <- members[members$kind == "metric", , drop = FALSE]
  sql <- databricks_semantic_metric_sql(
    model,
    metrics,
    members[0, , drop = FALSE],
    where = NULL,
    members = members,
    con = DBI::ANSI(),
    arguments = list(minimum_amount = 25)
  )

  expect_equal(model$parameters$minimum_amount$type, "number")
  expect_equal(model$parameters$minimum_amount$default, 10)
  expect_match(
    sql,
    'FROM "main"."analytics"."sales_metrics"("minimum_amount" => ?)',
    fixed = TRUE
  )
})

test_that("Databricks hydrates only explicitly selected metric views", {
  metric <- list(
    id = DBI::Id(catalog = "main", schema = "analytics", table = "metrics"),
    kind = "metric_view"
  )
  label <- table_id_label(metric$id)
  orders <- list(
    id = DBI::Id(catalog = "main", schema = "analytics", table = "orders"),
    kind = "table"
  )
  orders_label <- table_id_label(orders$id)
  exact <- FALSE
  local_mocked_bindings(
    catalog_table_registry = function(...) {
      list(
        labels = c(orders_label, label),
        ids = stats::setNames(list(orders$id, metric$id), c(orders_label, label)),
        relations = stats::setNames(
          list(orders, metric),
          c(orders_label, label)
        ),
        validate = list(
          labels = if (exact) label else character(),
          ids = if (exact) stats::setNames(list(metric$id), label) else list()
        ),
        namespace_selected = !exact
      )
    },
    databricks_read_semantic_model = function(...) {
      databricks_unsupported_metric_view(
        metric$id,
        "unsupported parameter type ARRAY"
      )
    },
    databricks_associated_semantic_models = function(...) list()
  )

  discovered <- databricks_table_registry(DBI::ANSI())
  expect_length(discovered$semantic_models, 0L)
  expect_named(discovered$semantic_stubs, label)

  exact <- TRUE
  expect_error(
    databricks_table_registry(DBI::ANSI()),
    "selected Databricks metric views are not supported"
  )
})

test_that("Databricks reads unsupported parameter types as unsupported models", {
  view <- list(
    id = DBI::Id(catalog = "main", schema = "analytics", table = "metrics"),
    description = NULL
  )
  local_mocked_bindings(
    databricks_view_definition = function(...) paste(
      "version: 1.1",
      "parameters:",
      "  - name: dimensions",
      "    data_type: ARRAY",
      "measures:",
      "  - name: revenue",
      sep = "\n"
    )
  )

  model <- databricks_read_semantic_model(view, DBI::ANSI())
  expect_s3_class(model, "commons_unsupported_databricks_metric_view")
  expect_match(model$reason, "unsupported type", fixed = TRUE)
})

local_truncating_describe <- function(
  view_text,
  limit,
  definition = NULL,
  env = parent.frame()
) {
  local_mocked_bindings(
    databricks_view_definition = function(...) definition,
    .env = env
  )
  local_mocked_bindings(
    dbGetQuery = function(con, sql) {
      if (grepl("AS JSON", sql, fixed = TRUE)) {
        json <- strrep("{\"table_name\":\"metrics\"", 100L)
        return(data.frame(json_metadata = substr(json, 1L, limit)))
      }
      # The shape a live Unity Catalog metric view's plain DESCRIBE has.
      data.frame(
        col_name = c(
          "order_id", "revenue", "", "# Detailed Table Information", "View Text"
        ),
        data_type = c("bigint", "double measure", "", "", view_text),
        comment = c("Order identifier.", NA, "", "", "")
      )
    },
    .package = "DBI",
    .env = env
  )
}

test_that("Databricks reads a metric view's YAML when ODBC truncates its JSON", {
  view <- list(
    id = DBI::Id(catalog = "main", schema = "analytics", table = "metrics"),
    description = NULL
  )
  local_truncating_describe(
    paste(
      "version: 1.1",
      "source: main.analytics.orders",
      "measures:",
      "  - name: revenue",
      "    expr: SUM(total)",
      sep = "\n"
    ),
    limit = 1023L
  )

  model <- databricks_read_semantic_model(view, DBI::ANSI())

  expect_equal(vapply(model$metrics, `[[`, character(1), "name"), "revenue")
})

test_that("Databricks expands wildcard fields from DESCRIBE when ODBC truncates its JSON", {
  view <- list(
    id = DBI::Id(catalog = "main", schema = "analytics", table = "metrics"),
    description = NULL
  )
  local_truncating_describe(
    paste(
      "version: 1.1",
      "source: main.analytics.orders",
      "fields:",
      "  - expr: source.*",
      "measures:",
      "  - name: revenue",
      "    expr: SUM(total)",
      sep = "\n"
    ),
    limit = 1023L
  )

  model <- databricks_read_semantic_model(view, DBI::ANSI())

  expect_s3_class(model, "commons_semantic_model")
  expect_equal(vapply(model$dimensions, `[[`, character(1), "name"), "order_id")
  expect_equal(model$dimensions[[1]]$type, "bigint")
  expect_equal(model$dimensions[[1]]$description, "Order identifier.")
  expect_equal(vapply(model$metrics, `[[`, character(1), "name"), "revenue")
})

test_that("Databricks expands wildcards from DESCRIBE beside a full information schema definition", {
  view <- list(
    id = DBI::Id(catalog = "main", schema = "analytics", table = "metrics"),
    description = NULL
  )
  yaml <- paste(
    "version: 1.1",
    "source: main.analytics.orders",
    "fields:",
    "  - expr: source.*",
    "measures:",
    "  - name: revenue",
    "    expr: SUM(total)",
    sep = "\n"
  )
  limit <- 20L
  local_truncating_describe(
    substr(yaml, 1L, limit),
    limit = limit,
    definition = yaml
  )

  model <- databricks_read_semantic_model(view, DBI::ANSI())

  expect_equal(vapply(model$dimensions, `[[`, character(1), "name"), "order_id")
  expect_equal(vapply(model$metrics, `[[`, character(1), "name"), "revenue")
})

test_that("Databricks refuses metric view YAML cut at the ODBC string length", {
  view <- list(
    id = DBI::Id(catalog = "main", schema = "analytics", table = "metrics"),
    description = NULL
  )
  yaml <- paste(
    "version: 1.1",
    "source: main.analytics.orders",
    "measures:",
    "  - name: revenue",
    "    expr: SUM(total)",
    sep = "\n"
  )
  local_truncating_describe(yaml, limit = nchar(yaml, type = "bytes"))

  expect_error(
    databricks_read_semantic_model(view, DBI::ANSI()),
    "longer than the ODBC driver returns"
  )
})

test_that("Databricks metric SQL uses MEASURE and model fields", {
  model <- databricks_semantic_model_from_spec(
    DBI::Id(
      catalog = "main",
      schema = "analytics",
      table = "sales_metrics"
    ),
    list(
      version = 1.1,
      fields = list(list(name = "region", expr = "region")),
      measures = list(list(name = "revenue", expr = "SUM(revenue)"))
    )
  )
  source <- test_source()
  state <- data_source_state(source)
  label <- table_id_label(model$id)
  state$semantic_models <- stats::setNames(list(model), label)
  members <- registry_semantic_members(
    semantic_models_registry(list(databricks = source))
  )
  metrics <- members[members$kind == "metric", , drop = FALSE]
  dimensions <- members[members$kind == "dimension", , drop = FALSE]

  sql <- databricks_semantic_metric_sql(
    model,
    metrics,
    dimensions,
    where = list(list(column = "region", op = "=", value = "EMEA")),
    members = members,
    con = DBI::ANSI()
  )

  expect_equal(
    sql,
    paste(
      "SELECT \"region\", MEASURE(\"revenue\") AS \"revenue\"",
      "FROM \"main\".\"analytics\".\"sales_metrics\"",
      "WHERE (\"region\" = 'EMEA')",
      "GROUP BY \"region\""
    )
  )
})

test_that("Databricks view definitions are read in driver-sized chunks", {
  queries <- character()
  local_mocked_bindings(
    dbGetQuery = function(con, sql) {
      queries <<- c(queries, sql)
      if (grepl("length(view_definition)", sql, fixed = TRUE)) {
        return(data.frame(definition_length = 1000L))
      }
      data.frame(chunk_1 = "version: 1.1\n", chunk_2 = "measures: []\n")
    },
    .package = "DBI"
  )

  definition <- databricks_view_definition(
    DBI::ANSI(),
    DBI::Id(catalog = "main", schema = "analytics", table = "metrics")
  )

  expect_equal(definition, "version: 1.1\nmeasures: []\n")
  expect_match(queries[[2]], "substring(view_definition, 1, 900)", fixed = TRUE)
  expect_match(queries[[2]], "substring(view_definition, 901, 900)", fixed = TRUE)
})

test_that("Databricks descriptions retain columns and nullability", {
  rows <- data.frame(
    col_name = c(
      "Order ID",
      "notes",
      "# Partition Information",
      "notes"
    ),
    data_type = c("bigint", "string", "", "string"),
    comment = c("Primary key", NA, "", NA),
    stringsAsFactors = FALSE
  )
  nullable <- c("Order ID" = FALSE, notes = TRUE)

  columns <- databricks_columns_from_describe(rows, nullable)

  expect_equal(columns$column, c("Order ID", "notes"))
  expect_equal(columns$type, c("bigint", "string"))
  expect_identical(columns$nullable, c(FALSE, TRUE))
  expect_equal(columns$description, c("Primary key", NA))
})

test_that("Databricks identifiers distinguish namespaces and relations", {
  expect_equal(databricks_id_type(DBI::Id(catalog = "main")), "namespace")
  expect_equal(databricks_id_type(DBI::Id(schema = "default")), "namespace")
  expect_equal(
    databricks_id_type(DBI::Id(catalog = "main", schema = "default")),
    "namespace"
  )
  expect_equal(databricks_id_type(DBI::Id(table = "orders")), "relation")
  expect_equal(
    databricks_id_type(DBI::Id(schema = "default", table = "orders")),
    "relation"
  )
})

test_that("Databricks identifiers cannot skip components", {
  expect_snapshot(
    databricks_id_type(DBI::Id(catalog = "main", table = "orders")),
    error = TRUE
  )
})

test_that("Databricks current namespace requires a catalog and schema", {
  local_mocked_bindings(
    dbGetQuery = function(...) {
      data.frame(catalog = NA_character_, schema = NA_character_)
    },
    .package = "DBI"
  )

  expect_snapshot(
    databricks_current_namespace(NULL),
    error = TRUE
  )
})

# The Databricks metric view contract both packages consume. The Python suite
# runs the same cases from the same file. See tests/shared/README.md.
metric_view_cases <- function(section) {
  cases <- shared_fixture("databricks-metric-views")[[section]]$cases
  # An empty section would enumerate no cases and the runner would pass.
  expect_gt(length(cases), 0)
  cases
}

test_that("Databricks metric view definitions read as the shared fixture says", {
  member <- function(m) {
    list(
      name = m$name, kind = m$kind, parent = m$parent, label = m$label,
      description = m$description, type = m$type,
      synonyms = as.list(m$synonyms), filter = m$filter
    )
  }
  for (case in metric_view_cases("specifications")) {
    model <- tryCatch(
      databricks_semantic_model_from_spec(
        do.call(DBI::Id, case$id),
        yaml::yaml.load(case$yaml, handlers = yaml12_booleans()),
        description = case$description,
        columns = case$columns %||% list()
      ),
      error = function(err) err
    )
    if (!is.null(case$expected$unsupported)) {
      expect_s3_class(model, "commons_unsupported_semantic_parameter")
      for (mention in case$expected$unsupported) {
        expect_true(grepl(mention, conditionMessage(model), fixed = TRUE), info = case$name)
      }
      next
    }
    if (!is.null(case$expected$error)) {
      expect_fixture_error(model, case$expected, info = case$name)
      next
    }
    actual <- list(
      name = model$name,
      description = model$description,
      dimensions = lapply(model$dimensions, member),
      metrics = lapply(model$metrics, member),
      facts = lapply(model$facts, member),
      filters = lapply(model$filters, member),
      parameters = lapply(model$parameters, function(p) {
        list(
          type = p$type, description = p$description,
          has_default = p$has_default, default = p$default, sql_type = p$sql_type
        )
      }),
      dependencies = lapply(model$dependencies, function(id) as.list(id@name)),
      dependencies_complete = model$dependencies_complete,
      first_touch = as.list(model$context$first_touch),
      retrieval = as.list(model$context$retrieval)
    )
    expected <- case$expected
    if (length(expected$parameters) == 0L) {
      expected$parameters <- list()
      actual$parameters <- list()
    }
    expect_equal(actual, expected, info = case$name)
  }
})

test_that("Databricks qualified names split as the shared fixture says", {
  for (case in metric_view_cases("qualified_names")) {
    expect_identical(
      as.list(databricks_qualified_name_parts(case$value)),
      case$parts,
      info = case$value
    )
  }
})

test_that("Databricks column types read as the shared fixture says", {
  for (case in metric_view_cases("type_text")) {
    expect_identical(databricks_type_text(case$type), case$text, info = deparse(case$type))
  }
})

test_that("Databricks relation kinds follow the shared fixture", {
  for (case in metric_view_cases("relation_kinds")) {
    rows <- data.frame(
      table_catalog = "main", table_schema = "sales", table_name = "x",
      table_type = case$table_type, comment = NA_character_
    )
    object_types <- if (is.null(case$object_type)) {
      character()
    } else {
      stats::setNames(case$object_type, databricks_object_key("sales", "x"))
    }
    expect_identical(
      databricks_relations_from_information_schema(rows, object_types)[[1]]$kind,
      case$kind,
      info = paste(case$table_type, case$object_type)
    )
  }
})

test_that("Databricks metric view selection follows the shared fixture", {
  section <- shared_fixture("databricks-metric-views")$selection
  expect_gt(length(section$cases), 0)
  for (case in section$cases) {
    local_mocked_bindings(
      dbGetQuery = fixture_databricks_reply(section$warehouse),
      .package = "DBI"
    )
    result <- tryCatch(
      databricks_table_registry(
        DBI::ANSI(),
        if (is.null(case$tables)) NULL else unlist(case$tables),
        exclude = unlist(case$exclude)
      ),
      error = function(err) err
    )
    if (!is.null(case$expected$error)) {
      expect_fixture_error(result, case$expected, info = case$name)
      next
    }
    expect_equal(as.list(result$labels), case$expected$tables, info = case$name)
    expect_equal(as.list(names(result$semantic_models)), case$expected$models, info = case$name)
    expect_equal(as.list(names(result$semantic_stubs)), case$expected$stubs, info = case$name)
  }
})

test_that("Databricks metric view queries compile as the shared fixture says", {
  section <- shared_fixture("databricks-metric-views")$metric_sql
  spec <- section$model
  member <- function(entries, kind) {
    lapply(entries, function(entry) new_semantic_member(entry$name, kind))
  }
  model <- new_semantic_model(
    do.call(DBI::Id, spec$id),
    spec$label,
    backend = "databricks_metric_view",
    dimensions = member(spec$dimensions, "dimension"),
    metrics = member(spec$metrics, "metric")
  )
  source <- test_source()
  state <- data_source_state(source)
  state$semantic_models <- stats::setNames(list(model), spec$label)
  members <- registry_semantic_members(
    semantic_models_registry(list(warehouse = source)),
    "warehouse"
  )
  # DBI::ANSI() quotes identifiers in double quotes; Databricks uses backticks.
  backticks <- function(sql) gsub('"([^"]*)"', "`\\1`", sql)
  expect_gt(length(section$cases), 0)
  for (case in section$cases) {
    result <- tryCatch({
      arguments <- stats::setNames(
        as.list(seq_along(case$arguments)),
        unlist(case$arguments)
      )
      backticks(databricks_semantic_metric_sql(
        model,
        resolve_semantic_members(unlist(case$metrics), members, "metric"),
        resolve_semantic_members(unlist(case$dimensions), members, "dimension"),
        case$where,
        members,
        DBI::ANSI(),
        arguments = arguments
      ))
    }, error = function(err) err)
    if (is.null(case$expected$error)) {
      expect_identical(result, case$expected$sql, info = case$name)
    } else {
      expect_fixture_error(result, case$expected, info = case$name)
    }
  }
})
