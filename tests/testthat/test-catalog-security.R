catalog_security_test_source <- function() {
  source <- test_source()
  source$relations <- list(sales = list(
    id = source$table_ids$sales,
    kind = "table",
    description = NULL,
    columns = NULL
  ))
  source$manifest <- new_catalog_manifest(source$relations, TRUE)
  source
}

test_that("session snapshots retain authority-bearing fields", {
  snowflake <- catalog_session_row(data.frame(
    principal = "ANALYST",
    role = "REPORTER",
    catalog = "ANALYTICS",
    schema = "PUBLIC"
  ), "snowflake", role = TRUE)
  databricks <- catalog_session_row(data.frame(
    principal = "analyst@example.com",
    catalog = "main",
    schema = "default"
  ), "databricks")

  expect_equal(snowflake$principal, "ANALYST")
  expect_equal(snowflake$role, "REPORTER")
  expect_equal(
    snowflake$namespace,
    list(catalog = "ANALYTICS", schema = "PUBLIC")
  )
  expect_null(databricks$role)
  expect_equal(databricks$namespace, list(catalog = "main", schema = "default"))
})

test_that("catalog operations reject changed sessions", {
  source <- test_source()
  source$session <- list(
    backend = "snowflake",
    principal = "ANALYST",
    role = "REPORTER",
    namespace = list(catalog = "ANALYTICS", schema = "PUBLIC")
  )
  local_mocked_bindings(
    catalog_session_snapshot = function(...) {
      list(
        backend = "snowflake",
        principal = "ANALYST",
        role = "ADMIN",
        namespace = list(catalog = "ANALYTICS", schema = "PUBLIC")
      )
    }
  )

  expect_error(
    source_query(source, "SELECT * FROM sales"),
    class = "commons_catalog_session_changed"
  )
  expect_error(
    source_describe(source, "sales"),
    class = "commons_catalog_session_changed"
  )
  expect_error(
    catalog_search(source, "sales"),
    class = "commons_catalog_session_changed"
  )
})

test_that("transient access failures remain retryable", {
  source <- catalog_security_test_source()
  calls <- 0L
  local_mocked_bindings(
    catalog_probe_relation = function(...) {
      calls <<- calls + 1L
      if (calls == 1L) {
        return(list(state = "transient", error = simpleError("timed out")))
      }
      list(state = "queryable", error = NULL)
    }
  )

  expect_error(
    catalog_ensure_queryable(source, "sales"),
    class = "commons_catalog_transient_error"
  )
  expect_equal(source$manifest$access[["sales"]], "unknown")
  expect_no_error(catalog_ensure_queryable(source, "sales"))
  expect_equal(source$manifest$access[["sales"]], "queryable")
  expect_equal(calls, 2L)
})

test_that("authorization failures are cached per relation", {
  source <- catalog_security_test_source()
  calls <- 0L
  local_mocked_bindings(
    catalog_probe_relation = function(...) {
      calls <<- calls + 1L
      list(state = "authorization", error = simpleError("permission denied"))
    }
  )

  expect_error(
    catalog_ensure_queryable(source, "sales"),
    class = "commons_catalog_authorization_error"
  )
  expect_error(
    catalog_ensure_queryable(source, "sales"),
    class = "commons_catalog_authorization_error"
  )
  expect_equal(source$manifest$access[["sales"]], "authorization")
  expect_equal(calls, 1L)
})

test_that("warehouse access errors are classified conservatively", {
  authorization <- structure(
    list(message = "hidden", call = NULL, sqlstate = "42501"),
    class = c("error", "condition")
  )

  expect_equal(catalog_access_error_kind(authorization), "authorization")
  expect_equal(
    catalog_access_error_kind(simpleError("warehouse is temporarily unavailable")),
    "transient"
  )
  expect_equal(catalog_access_error_kind(simpleError("bad syntax")), "unknown")
})

test_that("namespace semantic models hide authorization failures", {
  exact <- test_semantic_model("exact_model")
  discovered <- test_semantic_model("discovered_model")
  registry <- list(
    semantic_models = list(exact = exact, discovered = discovered),
    semantic_validate = "exact"
  )
  local_mocked_bindings(
    catalog_probe_semantic_model = function(...) {
      list(state = "authorization", error = simpleError("permission denied"))
    }
  )

  expect_error(
    catalog_filter_semantic_access(DBI::ANSI(), registry),
    class = "commons_catalog_authorization_error"
  )

  registry$semantic_validate <- character()
  filtered <- catalog_filter_semantic_access(DBI::ANSI(), registry)
  expect_length(filtered$semantic_models, 0L)
})

test_that("transient semantic probes fail without caching startup state", {
  registry <- list(
    semantic_models = list(discovered = test_semantic_model()),
    semantic_validate = character()
  )
  calls <- 0L
  local_mocked_bindings(
    catalog_probe_semantic_model = function(...) {
      calls <<- calls + 1L
      list(state = "transient", error = simpleError("warehouse starting"))
    }
  )

  expect_error(
    catalog_filter_semantic_access(DBI::ANSI(), registry),
    class = "commons_catalog_transient_error"
  )
  expect_error(
    catalog_filter_semantic_access(DBI::ANSI(), registry),
    class = "commons_catalog_transient_error"
  )
  expect_equal(calls, 2L)
})

test_that("semantic model probes use native zero-row queries", {
  snowflake <- catalog_semantic_probe_sql(
    DBI::ANSI(),
    test_semantic_model()
  )
  databricks <- test_semantic_model()
  databricks$backend <- "databricks_metric_view"
  databricks_sql <- catalog_semantic_probe_sql(DBI::ANSI(), databricks)

  expect_match(snowflake, "SEMANTIC_VIEW", fixed = TRUE)
  expect_match(snowflake, "LIMIT 0", fixed = TRUE)
  expect_match(databricks_sql, "MEASURE", fixed = TRUE)
  expect_match(databricks_sql, "LIMIT 0", fixed = TRUE)
})
