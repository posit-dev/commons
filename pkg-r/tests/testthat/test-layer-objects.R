test_that("layer constructors return private R6 objects", {
  source <- data_source(sales = data.frame(x = 1))
  semantic <- semantic_layer()
  context <- context_layer()

  expect_s3_class(source, "commons_data_source")
  expect_s3_class(semantic, "commons_semantic_layer")
  expect_s3_class(context, "commons_context_layer")
  expect_true(inherits(source, "R6"))
  expect_true(inherits(semantic, "R6"))
  expect_true(inherits(context, "R6"))

  expect_setequal(ls(source), c("initialize", "print"))
  expect_setequal(ls(semantic), c("initialize", "print"))
  expect_setequal(ls(context), c("initialize", "print"))
  expect_setequal(ls(DataSource$public_methods), c("initialize", "print"))
  expect_setequal(ls(SemanticLayer$public_methods), c("initialize", "print"))
  expect_setequal(ls(ContextLayer$public_methods), c("initialize", "print"))
  expect_false("clone" %in% names(source))
  expect_false("clone" %in% names(semantic))
  expect_false("clone" %in% names(context))

  expect_false("tables" %in% names(source))
  expect_false("measures" %in% names(semantic))
  expect_false("docs" %in% names(context))
  expect_equal(data_source_state(source)$tables, "sales")
  expect_length(semantic_layer_state(semantic)$measures, 0L)
  expect_equal(context_layer_state(context)$docs, character())
})

test_that("layer objects and their state environments are locked", {
  source <- new_data_source(DBI::ANSI(), "sales", owned = FALSE)
  state <- data_source_state(source)
  alias <- source

  expect_true(environmentIsLocked(source))
  expect_true(environmentIsLocked(state))
  state$tables <- c("sales", "orders")
  expect_equal(data_source_state(alias)$tables, c("sales", "orders"))
  expect_error(state$other <- TRUE, "locked environment")
})

test_that("layer checks reject forged classed lists", {
  expect_error(
    check_data_source(structure(list(), class = "commons_data_source")),
    "data_source"
  )
  expect_error(
    check_semantic_layer(structure(list(), class = "commons_semantic_layer")),
    "semantic_layer"
  )
  expect_error(
    check_context_layer(structure(list(), class = "commons_context_layer")),
    "context_layer"
  )
  expect_error(
    check_data_source(structure(new.env(), class = "commons_data_source")),
    "data_source"
  )
  expect_error(
    check_semantic_layer(structure(new.env(), class = "commons_semantic_layer")),
    "semantic_layer"
  )
  expect_error(
    check_context_layer(structure(new.env(), class = "commons_context_layer")),
    "context_layer"
  )
  forged <- structure(
    new.env(parent = emptyenv()),
    class = c("commons_data_source", "R6")
  )
  expect_error(check_data_source(forged), "data_source")
})

test_that("layer print methods report their contents and return invisibly", {
  source_zero <- new_data_source(DBI::ANSI(), character(), owned = FALSE)
  source_one <- new_data_source(DBI::ANSI(), "sales", owned = FALSE)
  source_two <- new_data_source(
    DBI::ANSI(),
    c("sales", "orders"),
    owned = FALSE
  )
  semantic_zero <- new_semantic_layer()
  semantic_one <- new_semantic_layer(list(metric = "metric"))
  semantic_two <- new_semantic_layer(list(metric = "metric", count = "count"))
  context_zero <- new_context_layer(character())
  context_one <- new_context_layer("One")
  context_two <- new_context_layer(c("One", "Two"))

  expect_snapshot({
    print(source_zero)
    print(source_one)
    print(source_two)
    print(semantic_zero)
    print(semantic_one)
    print(semantic_two)
    print(context_zero)
    print(context_one)
    print(context_two)
  })
  for (object in list(source_one, semantic_one, context_one)) {
    printed <- withVisible(suppressMessages(print(object)))
    expect_false(printed$visible)
    expect_identical(printed$value, object)
  }
})

test_that("private state controls owned connection lifetime", {
  con <- duckdb_connect()
  source <- new_data_source(con, character(), owned = TRUE)
  state <- data_source_state(source)

  rm(source)
  gc()
  expect_true(DBI::dbIsValid(con))

  rm(state)
  gc()
  expect_false(DBI::dbIsValid(con))
})

test_that("borrowed connections outlive their wrappers", {
  con <- duckdb_connect()
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  source <- new_data_source(con, character(), owned = FALSE)

  rm(source)
  gc()

  expect_true(DBI::dbIsValid(con))
})
