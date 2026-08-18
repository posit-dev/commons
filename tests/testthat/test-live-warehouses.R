test_that("live Snowflake discovers and describes catalog relations", {
  table <- warehouse_test_table("snowflake")
  con <- local_warehouse_connection("snowflake")
  components <- table@name
  skip_if_not(
    all(c("catalog", "schema", "table") %in% names(components)),
    "The Snowflake test table must be fully qualified"
  )

  session <- DBI::dbGetQuery(
    con,
    paste(
      "SELECT CURRENT_USER() AS principal,",
      "CURRENT_ROLE() AS role,",
      "CURRENT_DATABASE() AS catalog,",
      "CURRENT_SCHEMA() AS schema"
    )
  )
  rows <- warehouse_read_one(con, table)
  names(session) <- tolower(names(session))
  label <- table_id_label(table)

  column <- names(rows)[[1]]
  dictionary <- warehouse_test_dictionary(label, column)
  exact <- data_source(con, tables = table, dictionary = dictionary)
  described <- source_describe(exact, label)

  namespace <- DBI::Id(
    catalog = components[["catalog"]],
    schema = components[["schema"]]
  )
  schema_source <- data_source(con, tables = namespace)
  catalog_source <- data_source(
    con,
    tables = DBI::Id(catalog = components[["catalog"]])
  )

  DBI::dbExecute(
    con,
    paste(
      "USE DATABASE",
      DBI::dbQuoteIdentifier(
        con,
        DBI::Id(catalog = components[["catalog"]])
      )
    )
  )
  DBI::dbExecute(
    con,
    paste("USE SCHEMA", DBI::dbQuoteIdentifier(con, namespace))
  )
  current_source <- data_source(con)

  expect_equal(nrow(session), 1)
  expect_named(session, c("principal", "role", "catalog", "schema"))
  expect_true(nzchar(session$principal[[1]]))
  expect_s3_class(rows, "data.frame")
  expect_true(nrow(rows) <= 1)
  expect_equal(list_tables(exact), label)
  expect_identical(exact$table_ids[[label]], table)
  expect_named(
    described$schema,
    c("column", "type", "nullable", "description")
  )
  expect_true(nrow(described$sample) <= 5)
  expect_equal(names(described$sample), described$schema$column)
  expect_equal(
    exact$dictionary$tables[[label]]$description,
    "Authored live table description."
  )
  expect_equal(
    exact$dictionary$tables[[label]]$columns[[column]]$type,
    described$schema$type[match(column, described$schema$column)]
  )
  expect_equal(
    exact$dictionary$tables[[label]]$columns[[column]]$description,
    "Authored live column description."
  )
  expect_true(exact$relations[[label]]$kind %in% c("table", "view"))
  expect_true(label %in% list_tables(schema_source))
  expect_true(label %in% list_tables(catalog_source))
  expect_true(label %in% list_tables(current_source))
  expect_true(all(vapply(
    schema_source$relations,
    function(x) x$kind %in% c("table", "view"),
    logical(1)
  )))

  tool <- describe_table_tool(exact, label)
  expect_match(tool@value, "Relation type")
  expect_match(tool@value, "nullable")
  expect_match(tool@value, "Sample summary")
})

test_that("live Snowflake rejects an ambiguous relative dictionary table", {
  table <- warehouse_test_table("snowflake")
  con <- local_warehouse_connection("snowflake")
  catalog <- table@name[["catalog"]]
  relations <- snowflake_list_relations(
    con,
    DBI::Id(catalog = catalog)
  )
  relation_names <- vapply(
    relations,
    function(relation) relation$id@name[["table"]],
    character(1)
  )
  duplicated_names <- unique(relation_names[
    duplicated(relation_names) | duplicated(relation_names, fromLast = TRUE)
  ])
  skip_if(
    length(duplicated_names) == 0L,
    "The selected Snowflake catalog has no ambiguous relation names"
  )

  authored_name <- duplicated_names[[1]]
  selected <- relations[relation_names == authored_name][1:2]
  dictionary <- new_data_dictionary(list(
    tables = stats::setNames(
      list(list(description = "Ambiguous authored description.")),
      authored_name
    )
  ))

  expect_error(
    data_source(
      con,
      tables = lapply(selected, `[[`, "id"),
      dictionary = dictionary
    ),
    "matches more than one selected relation"
  )
})

test_that("live Snowflake executes compiled definition mappings", {
  table <- warehouse_test_table("snowflake")
  con <- local_warehouse_connection("snowflake")
  source <- data_source(con, tables = table)
  compiled <- definition_compile_source(
    warehouse_definition_spec(source$tables[[1]]),
    source
  )
  definitions <- compiled$tables[[1]]$definitions
  names(definitions) <- vapply(definitions, `[[`, character(1), "name")

  round_half <- DBI::dbGetQuery(
    con,
    paste("SELECT", definitions$round_half$sql, "AS value")
  )[[1]][[1]]
  floored_modulus <- DBI::dbGetQuery(
    con,
    paste("SELECT", definitions$floored_modulus$sql, "AS value")
  )[[1]][[1]]
  negative_modulus <- DBI::dbGetQuery(
    con,
    paste("SELECT", definitions$negative_modulus$sql, "AS value")
  )[[1]][[1]]
  modulus_by_zero <- DBI::dbGetQuery(
    con,
    paste("SELECT", definitions$modulus_by_zero$sql, "AS value")
  )[[1]][[1]]
  division_by_zero <- DBI::dbGetQuery(
    con,
    paste("SELECT", definitions$division_by_zero$sql, "AS value")
  )[[1]][[1]]
  like_pattern <- DBI::dbGetQuery(
    con,
    paste("SELECT", definitions$like_pattern$sql, "AS value")
  )[[1]][[1]]
  similar_pattern <- DBI::dbGetQuery(
    con,
    paste("SELECT", definitions$similar_pattern$sql, "AS value")
  )[[1]][[1]]
  temporal_shift <- DBI::dbGetQuery(
    con,
    paste("SELECT", definitions$temporal_shift$sql, "AS value")
  )[[1]][[1]]
  boolean_fold <- DBI::dbGetQuery(
    con,
    paste("SELECT", definitions$boolean_fold$sql, "AS value")
  )[[1]][[1]]
  null_boolean_fold <- DBI::dbGetQuery(
    con,
    paste("SELECT", definitions$null_boolean_fold$sql, "AS value")
  )[[1]][[1]]
  empty_boolean_fold <- DBI::dbGetQuery(
    con,
    paste(
      "SELECT",
      definitions$boolean_fold$sql,
      "AS value FROM (SELECT 1 AS one) AS empty_rows WHERE FALSE"
    )
  )[[1]][[1]]

  expect_true(isTRUE(as.logical(round_half)))
  expect_true(isTRUE(as.logical(floored_modulus)))
  expect_true(isTRUE(as.logical(negative_modulus)))
  expect_true(isTRUE(as.logical(modulus_by_zero)))
  expect_true(isTRUE(as.logical(division_by_zero)))
  expect_true(isTRUE(as.logical(like_pattern)))
  expect_true(isTRUE(as.logical(similar_pattern)))
  expect_true(isTRUE(as.logical(temporal_shift)))
  expect_true(isTRUE(as.logical(boolean_fold)))
  expect_true(is.na(null_boolean_fold))
  expect_true(is.na(empty_boolean_fold))
})

test_that("live Databricks discovers and describes catalog relations", {
  table <- warehouse_test_table("databricks")
  con <- local_warehouse_connection("databricks")
  components <- table@name
  skip_if_not(
    all(c("catalog", "schema", "table") %in% names(components)),
    "The Databricks test table must be fully qualified"
  )

  session <- DBI::dbGetQuery(
    con,
    paste(
      "SELECT CURRENT_USER() AS principal,",
      "CURRENT_CATALOG() AS catalog,",
      "CURRENT_SCHEMA() AS schema"
    )
  )
  rows <- warehouse_read_one(con, table)
  names(session) <- tolower(names(session))
  label <- table_id_label(table)

  column <- names(rows)[[1]]
  dictionary <- warehouse_test_dictionary(
    components[["table"]],
    column
  )
  exact <- data_source(con, tables = table, dictionary = dictionary)
  described <- source_describe(exact, label)

  namespace <- DBI::Id(
    catalog = components[["catalog"]],
    schema = components[["schema"]]
  )
  schema_source <- data_source(con, tables = namespace)
  catalog_source <- data_source(
    con,
    tables = DBI::Id(catalog = components[["catalog"]])
  )
  current_source <- data_source(con)

  expect_equal(nrow(session), 1)
  expect_named(session, c("principal", "catalog", "schema"))
  expect_true(nzchar(session$principal[[1]]))
  expect_s3_class(rows, "data.frame")
  expect_true(nrow(rows) <= 1)
  expect_equal(list_tables(exact), label)
  expect_identical(exact$table_ids[[label]], table)
  expect_named(
    described$schema,
    c("column", "type", "nullable", "description")
  )
  expect_false(anyNA(described$schema$nullable))
  expect_true(nrow(described$sample) <= 5)
  expect_equal(names(described$sample), described$schema$column)
  expect_equal(
    exact$dictionary$tables[[label]]$description,
    "Authored live table description."
  )
  expect_equal(
    exact$dictionary$tables[[label]]$columns[[column]]$type,
    described$schema$type[match(column, described$schema$column)]
  )
  expect_equal(
    exact$dictionary$tables[[label]]$columns[[column]]$description,
    "Authored live column description."
  )
  expect_true(exact$relations[[label]]$kind %in% c("table", "view"))
  expect_true(label %in% list_tables(schema_source))
  expect_true(label %in% list_tables(catalog_source))
  expect_s3_class(current_source, "commons_data_source")
  expect_true(all(vapply(
    schema_source$relations,
    function(x) x$kind %in% c("table", "view"),
    logical(1)
  )))

  tool <- describe_table_tool(exact, label)
  expect_match(tool@value, "Relation type")
  expect_match(tool@value, "nullable")
  expect_match(tool@value, "Sample summary")
})

test_that("live Databricks handles quoted relation and column names", {
  warehouse_test_table("databricks")
  con <- local_warehouse_connection("databricks")
  DBI::dbExecute(con, "USE CATALOG `hive_metastore`")
  DBI::dbExecute(con, "USE SCHEMA `default`")

  table <- DBI::Id(table = "commons quoted.table")
  quoted <- DBI::dbQuoteIdentifier(con, table)
  DBI::dbExecute(
    con,
    paste(
      "CREATE TEMPORARY VIEW",
      quoted,
      "AS SELECT 1 AS `quoted column`"
    )
  )
  withr::defer(
    DBI::dbExecute(con, paste("DROP VIEW IF EXISTS", quoted))
  )

  source <- data_source(con, tables = table)
  described <- source_describe(source, "commons quoted.table")

  expect_identical(source$table_ids[["commons quoted.table"]], table)
  expect_equal(described$schema$column, "quoted column")
  expect_equal(described$sample[["quoted column"]], 1L)
})

test_that("live Databricks executes compiled definition mappings", {
  table <- warehouse_test_table("databricks")
  con <- local_warehouse_connection("databricks")
  source <- data_source(con, tables = table)
  compiled <- definition_compile_source(
    warehouse_definition_spec(source$tables[[1]]),
    source
  )
  definitions <- compiled$tables[[1]]$definitions
  names(definitions) <- vapply(definitions, `[[`, character(1), "name")

  round_half <- DBI::dbGetQuery(
    con,
    paste("SELECT", definitions$round_half$sql, "AS value")
  )[[1]][[1]]
  floored_modulus <- DBI::dbGetQuery(
    con,
    paste("SELECT", definitions$floored_modulus$sql, "AS value")
  )[[1]][[1]]
  negative_modulus <- DBI::dbGetQuery(
    con,
    paste("SELECT", definitions$negative_modulus$sql, "AS value")
  )[[1]][[1]]
  modulus_by_zero <- DBI::dbGetQuery(
    con,
    paste("SELECT", definitions$modulus_by_zero$sql, "AS value")
  )[[1]][[1]]
  division_by_zero <- DBI::dbGetQuery(
    con,
    paste("SELECT", definitions$division_by_zero$sql, "AS value")
  )[[1]][[1]]
  like_pattern <- DBI::dbGetQuery(
    con,
    paste("SELECT", definitions$like_pattern$sql, "AS value")
  )[[1]][[1]]
  similar_pattern <- DBI::dbGetQuery(
    con,
    paste("SELECT", definitions$similar_pattern$sql, "AS value")
  )[[1]][[1]]
  temporal_shift <- DBI::dbGetQuery(
    con,
    paste("SELECT", definitions$temporal_shift$sql, "AS value")
  )[[1]][[1]]
  boolean_fold <- DBI::dbGetQuery(
    con,
    paste("SELECT", definitions$boolean_fold$sql, "AS value")
  )[[1]][[1]]
  null_boolean_fold <- DBI::dbGetQuery(
    con,
    paste("SELECT", definitions$null_boolean_fold$sql, "AS value")
  )[[1]][[1]]
  empty_boolean_fold <- DBI::dbGetQuery(
    con,
    paste(
      "SELECT",
      definitions$boolean_fold$sql,
      "AS value FROM (SELECT 1 AS one) AS empty_rows WHERE FALSE"
    )
  )[[1]][[1]]

  expect_true(isTRUE(as.logical(round_half)))
  expect_true(isTRUE(as.logical(floored_modulus)))
  expect_true(isTRUE(as.logical(negative_modulus)))
  expect_true(isTRUE(as.logical(modulus_by_zero)))
  expect_true(isTRUE(as.logical(division_by_zero)))
  expect_true(isTRUE(as.logical(like_pattern)))
  expect_true(isTRUE(as.logical(similar_pattern)))
  expect_true(isTRUE(as.logical(temporal_shift)))
  expect_true(isTRUE(as.logical(boolean_fold)))
  expect_true(is.na(null_boolean_fold))
  expect_true(is.na(empty_boolean_fold))
})
