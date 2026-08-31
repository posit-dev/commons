test_that("data_source registers frames as queryable tables", {
  src <- test_source()
  expect_equal(list_tables(src), "sales")

  res <- source_query(src, "SELECT count(*) AS n FROM sales")
  expect_equal(res$n, 6)
})

test_that("source_describe returns schema and samples", {
  src <- test_source()
  d <- source_describe(src, "sales", n_sample = 2)

  expect_setequal(
    d$schema$column,
    c("order_id", "revenue", "region", "product_line", "rep")
  )
  expect_equal(nrow(d$sample), 2)
})

test_that("source_describe errors informatively for unknown tables", {
  expect_snapshot(source_describe(test_source(), "nope"), error = TRUE)
})

test_that("data_source wraps an existing connection without copying", {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbWriteTable(con, "sales", test_sales())
  DBI::dbWriteTable(con, "reps", data.frame(rep = "Ada"))

  src <- data_source(con)
  expect_identical(data_source_state(src)$con, con)
  expect_setequal(list_tables(src), c("sales", "reps"))

  src_one <- data_source(con, tables = "sales")
  expect_equal(list_tables(src_one), "sales")
})

test_that("data_source supports schema-qualified connection tables", {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "CREATE SCHEMA crm")
  DBI::dbExecute(con, "CREATE TABLE crm.sales (order_id VARCHAR, revenue DOUBLE)")
  DBI::dbExecute(con, "INSERT INTO crm.sales VALUES ('o01', 100)")

  src <- data_source(con, tables = "crm.sales")

  expect_equal(list_tables(src), "crm.sales")
  d <- source_describe(src, "crm.sales")
  expect_equal(d$schema$column, c("order_id", "revenue"))
  expect_equal(d$sample$order_id, "o01")
})

test_that("data_source supports explicit DBI identifiers", {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "CREATE SCHEMA crm")
  DBI::dbExecute(con, "CREATE TABLE crm.sales (order_id VARCHAR, revenue DOUBLE)")
  DBI::dbExecute(con, "INSERT INTO crm.sales VALUES ('o01', 100)")

  src <- data_source(
    con,
    tables = list(DBI::Id(schema = "crm", table = "sales"))
  )

  expect_equal(list_tables(src), "crm.sales")
  d <- source_describe(src, "crm.sales")
  expect_equal(d$sample$order_id, "o01")
})

test_that("data_source keeps default connection discovery unvalidated", {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "CREATE SCHEMA crm")
  DBI::dbExecute(con, "CREATE TABLE crm.sales (order_id VARCHAR)")

  src <- data_source(con)

  expect_equal(list_tables(src), "sales")
})

test_that("data_source errors for tables absent from the connection", {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbWriteTable(con, "sales", test_sales())

  expect_snapshot(data_source(con, tables = "nope"), error = TRUE)
})

test_that("source_query rejects non-SELECT statements", {
  src <- test_source()
  expect_error(source_query(src, "DROP TABLE sales"), "disallowed operation")
  expect_error(source_query(src, "DELETE FROM sales"), "disallowed operation")
  expect_error(
    source_query(src, "INSERT INTO sales VALUES ('o07', 1, 'EMEA', 'x', 'y')"),
    "disallowed operation"
  )
  expect_error(source_query(src, "VACUUM"), "must begin with")
  expect_equal(source_query(src, "SELECT count(*) AS n FROM sales")$n, 6)
})

test_that("check_query accepts one SELECT statement", {
  expect_invisible(check_query("SELECT 'dropped' AS status FROM sales"))
  expect_invisible(check_query("WITH total AS (SELECT 1) SELECT * FROM total"))
  expect_invisible(check_query("SELECT 1;"))
})

test_that("source_query rejects multiple statements without executing them", {
  src <- test_source()
  expect_error(
    source_query(src, "SELECT 1 AS ok; DROP TABLE sales;"),
    "disallowed semicolon"
  )
  expect_true(DBI::dbExistsTable(data_source_state(src)$con, "sales"))
})

test_that("the frame-path DuckDB is locked down", {
  src <- test_source()
  expect_error(
    DBI::dbExecute(data_source_state(src)$con, "SET enable_external_access = true")
  )
})

test_that("duckdb_connect supports coexisting connections in one process", {
  con1 <- duckdb_connect()
  withr::defer(DBI::dbDisconnect(con1, shutdown = TRUE))
  # home_directory is a process-global option; a second connection must not fail
  # trying to re-set it once the first instance exists.
  con2 <- expect_no_error(duckdb_connect())
  withr::defer(DBI::dbDisconnect(con2, shutdown = TRUE))

  dir <- file.path(tempdir(), "duckdb")
  expect_equal(
    DBI::dbGetQuery(con2, "SELECT current_setting('home_directory') AS h")$h,
    dir
  )
})

test_that("data_source defers reading a board's pins until first use", {
  skip_if_not_installed("pins")

  board <- board_with_pins(
    "team-orders" = data.frame(id = 1:3),
    "team-reps" = data.frame(rep = c("Ada", "Bo"))
  )

  src <- data_source(
    board,
    tables = c(orders = "team-orders", reps = "team-reps")
  )
  expect_setequal(list_tables(src), c("orders", "reps"))
  expect_length(DBI::dbListTables(data_source_state(src)$con), 0)
})

test_that("source_describe loads only the table it describes", {
  skip_if_not_installed("pins")

  board <- board_with_pins(
    "team-orders" = data.frame(id = 1:3),
    "team-reps" = data.frame(rep = c("Ada", "Bo"))
  )
  src <- data_source(
    board,
    tables = c(orders = "team-orders", reps = "team-reps")
  )

  d <- source_describe(src, "orders")
  expect_equal(d$schema$column, "id")
  expect_equal(DBI::dbListTables(data_source_state(src)$con), "orders")
})

test_that("source_query loads the tables a query references", {
  skip_if_not_installed("pins")

  board <- board_with_pins(
    "team-orders" = data.frame(id = 1:3, rep = c("Ada", "Bo", "Ada")),
    "team-reps" = data.frame(rep = c("Ada", "Bo"), team = c("x", "y")),
    "team-regions" = data.frame(region = "EMEA")
  )
  src <- data_source(
    board,
    tables = c(orders = "team-orders", reps = "team-reps", regions = "team-regions")
  )

  # A join over two pending tables, one named in a different case and one
  # quoted. The unreferenced `regions` table stays pending.
  res <- source_query(
    src,
    'SELECT o.id, r.team FROM ORDERS o JOIN "reps" r ON o.rep = r.rep'
  )
  expect_equal(nrow(res), 3)
  expect_setequal(DBI::dbListTables(data_source_state(src)$con), c("orders", "reps"))
  expect_equal(names(data_source_state(src)$pending$pins), "regions")

  source_query(src, "SELECT count(*) AS n FROM orders")
  expect_setequal(DBI::dbListTables(data_source_state(src)$con), c("orders", "reps"))
  expect_equal(names(data_source_state(src)$pending$pins), "regions")
})

test_that("source_query doesn't read a pin named only in a string literal", {
  skip_if_not_installed("pins")

  board <- board_with_pins(
    "team-orders" = data.frame(id = 1:3),
    "team-regions" = data.frame(region = "EMEA")
  )
  src <- data_source(
    board,
    tables = c(orders = "team-orders", regions = "team-regions")
  )
  # An unavailable pin that the query mentions only as a string literal must
  # not be read, so the valid query over `orders` still succeeds.
  suppressMessages(pins::pin_delete(board, "team-regions"))

  res <- source_query(src, "SELECT id, 'regions' AS label FROM orders")
  expect_equal(nrow(res), 3)
  expect_equal(names(data_source_state(src)$pending$pins), "regions")
})

test_that("source_query preserves a genuine query error, unmasked", {
  skip_if_not_installed("pins")

  board <- board_with_pins(
    "team-orders" = data.frame(id = 1:3),
    "team-regions" = data.frame(region = "EMEA")
  )
  src <- data_source(
    board,
    tables = c(orders = "team-orders", regions = "team-regions")
  )
  # The deleted pin would error if read; the bad column must surface instead.
  suppressMessages(pins::pin_delete(board, "team-regions"))

  expect_error(
    source_query(src, "SELECT nope_col FROM orders"),
    "nope_col"
  )
})

test_that("source_query loads a pin whose label ends in punctuation", {
  skip_if_not_installed("pins")

  board <- board_with_pins("team-orders" = data.frame(id = 1:3))
  src <- data_source(board, tables = c("orders-" = "team-orders"))

  res <- source_query(src, 'SELECT count(*) AS n FROM "orders-"')
  expect_equal(res$n, 3)
})

test_that("data_source rejects a board label colliding with a built-in relation", {
  skip_if_not_installed("pins")

  board <- board_with_pins("team-orders" = data.frame(id = 1:3))
  expect_snapshot(
    data_source(board, tables = c(duckdb_tables = "team-orders")),
    error = TRUE
  )
})

test_that("data_source validates board pin names at construction", {
  skip_if_not_installed("pins")

  board <- board_with_pins("team-orders" = data.frame(id = 1:3))

  expect_snapshot(
    data_source(board, tables = c(orders = "team-orders", missing = "nope")),
    error = TRUE
  )
  expect_snapshot(data_source(board), error = TRUE)
  expect_snapshot(
    data_source(board, tables = stats::setNames(character(0), character(0))),
    error = TRUE
  )
})

test_that("check_board_pins_exist resolves, flags missing, and flags ambiguous names", {
  skip_if_not_installed("pins")

  local_mocked_bindings(
    pin_list = function(board) c("alice/orders", "bob/orders", "alice/reps"),
    pin_exists = function(board, name) FALSE,
    .package = "pins"
  )
  board <- structure(list(), class = "pins_board")

  # Full name and a unique suffix both resolve.
  expect_no_error(check_board_pins_exist(board, c(o = "alice/orders")))
  expect_no_error(check_board_pins_exist(board, c(r = "reps")))

  expect_snapshot(check_board_pins_exist(board, c(x = "nope")), error = TRUE)
  # A bare name that suffix-matches two owners' pins is ambiguous.
  expect_snapshot(check_board_pins_exist(board, c(o = "orders")), error = TRUE)
})

test_that("check_board_pins_exist accepts a pin absent from a capped listing", {
  skip_if_not_installed("pins")

  # pin_list() caps at 1000 on Connect; a valid pin past the cap must not be
  # rejected as missing, but a genuinely absent one still is.
  local_mocked_bindings(
    pin_list = function(board) paste0("owner/pin", 1:1000),
    pin_exists = function(board, name) name == "owner/past-cap",
    .package = "pins"
  )
  board <- structure(list(), class = "pins_board")

  expect_no_error(check_board_pins_exist(board, c(late = "owner/past-cap")))
  expect_snapshot(check_board_pins_exist(board, c(x = "nope")), error = TRUE)
})

test_that("a failed pin read surfaces at use and is retried, not cached", {
  skip_if_not_installed("pins")

  board <- board_with_pins("team-orders" = data.frame(id = 1:3))
  src <- data_source(board, tables = c(orders = "team-orders"))

  suppressMessages(pins::pin_delete(board, "team-orders"))
  expect_error(source_describe(src, "orders"), "Failed to read pin")

  suppressMessages(
    pins::pin_write(board, data.frame(id = 1:5), "team-orders", type = "rds")
  )
  expect_equal(nrow(source_describe(src, "orders")$sample), 5)
})

test_that("a pin that isn't a data frame errors clearly", {
  skip_if_not_installed("pins")

  board <- board_with_pins("config" = list(threshold = 1))
  src <- data_source(board, tables = c(cfg = "config"))

  expect_snapshot(source_describe(src, "cfg"), error = TRUE)
})

test_that("prewarm_downloads() downloads best-effort, tolerating a bad pin", {
  skip_if_not_installed("pins")

  board <- board_with_pins(
    "team-orders" = data.frame(id = 1:3),
    "team-reps" = data.frame(rep = c("Ada", "Bo"))
  )
  suppressMessages(pins::pin_delete(board, "team-orders"))

  expect_equal(
    prewarm_downloads(board, c("team-orders", "team-reps")),
    c("team-orders" = FALSE, "team-reps" = TRUE)
  )
})

test_that("source_prewarm() spawns at most one live process per source", {
  skip_if_not_installed("pins")

  local_mocked_bindings(prewarm_downloads = function(board, pins) Sys.sleep(30))
  board <- board_with_pins("team-orders" = data.frame(id = 1:3))
  src <- data_source(board, tables = c(orders = "team-orders"))

  source_prewarm(src)
  p <- data_source_state(src)$pending$process
  withr::defer(p$kill())
  expect_true(p$is_alive())

  # A second prewarm (e.g. another agent sharing the source) doesn't respawn.
  source_prewarm(src)
  expect_identical(data_source_state(src)$pending$process, p)

  # Once the child is gone with pins still pending, prewarm respawns.
  p$kill()
  p$wait(5000)
  source_prewarm(src)
  expect_false(identical(data_source_state(src)$pending$process, p))
  withr::defer(data_source_state(src)$pending$process$kill())
})

test_that("source_prewarm() is a no-op without pending pins", {
  expect_no_error(source_prewarm(test_source()))

  skip_if_not_installed("pins")
  board <- board_with_pins("team-orders" = data.frame(id = 1:3))
  src <- data_source(board, tables = c(orders = "team-orders"))
  source_ensure_all(src)

  source_prewarm(src)
  expect_null(data_source_state(src)$pending$process)
})

test_that("dbWriteTable works after duckdb_lock_down", {
  con <- duckdb_connect()
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  duckdb_lock_down(con)

  expect_no_error(
    DBI::dbWriteTable(con, "t", data.frame(x = 1:2), overwrite = TRUE)
  )
  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM t")$n, 2)
})

test_that("data_source rejects unnamed or non-data-frame input", {
  expect_snapshot(data_source(data.frame(x = 1)), error = TRUE)
  expect_snapshot(data_source(a = 1), error = TRUE)
})

test_that("data_source spans record kind and table counts", {
  skip_if_not_installed("otelsdk")

  recorded <- otelsdk::with_otel_record(test_source())
  names <- vapply(recorded$traces, `[[`, character(1), "name")
  expect_setequal(
    names,
    c("commons_data_source_create", "commons_data_source_load_frames")
  )
  load_span <- recorded$traces[[which(names == "commons_data_source_load_frames")]]
  expect_equal(load_span$attributes[["commons.data_source.n_tables"]], 1L)
  create_span <- recorded$traces[[which(names == "commons_data_source_create")]]
  expect_equal(create_span$attributes[["commons.data_source.kind"]], "frames")
})

test_that("data_source spans record table counts for connections", {
  skip_if_not_installed("otelsdk")

  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbWriteTable(con, "sales", test_sales())

  recorded <- otelsdk::with_otel_record(data_source(con))
  names <- vapply(recorded$traces, `[[`, character(1), "name")
  list_span <- recorded$traces[[which(names == "commons_data_source_list_tables")]]
  expect_equal(list_span$attributes[["commons.data_source.n_tables"]], 1L)
})

test_that("board construction records a list-pins span, not a read span", {
  skip_if_not_installed("otelsdk")
  skip_if_not_installed("pins")

  board <- board_with_pins("team-orders" = data.frame(id = 1:3))

  recorded <- otelsdk::with_otel_record(
    data_source(board, tables = c(orders = "team-orders"))
  )
  names <- vapply(recorded$traces, `[[`, character(1), "name")
  expect_true("commons_data_source_list_pins" %in% names)
  expect_false("commons_data_source_read_board" %in% names)
  list_span <- recorded$traces[[which(names == "commons_data_source_list_pins")]]
  expect_equal(list_span$attributes[["commons.data_source.n_tables"]], 1L)
})

test_that("reading a board table records a read-board span", {
  skip_if_not_installed("otelsdk")
  skip_if_not_installed("pins")

  board <- board_with_pins("team-orders" = data.frame(id = 1:3))
  src <- data_source(board, tables = c(orders = "team-orders"))

  recorded <- otelsdk::with_otel_record(source_describe(src, "orders"))
  names <- vapply(recorded$traces, `[[`, character(1), "name")
  read_span <- recorded$traces[[which(names == "commons_data_source_read_board")]]
  expect_equal(read_span$attributes[["commons.data_source.n_tables"]], 1L)
})

test_that("as_data_sources wraps a bare data_source", {
  srcs <- as_data_sources(test_source())

  expect_length(srcs, 1)
  expect_false(rlang::have_name(srcs))
})

test_that("as_data_sources accepts multiple sources", {
  srcs <- as_data_sources(list(a = test_source(), b = test_source()))
  expect_named(srcs, c("a", "b"))

  # Accepts its own output because commons() calls it before agent construction.
  expect_identical(as_data_sources(srcs), srcs)
})

test_that("resolve_sql_source picks the source for a SQL tool call", {
  src <- test_source()
  expect_identical(resolve_sql_source(list(src), NULL), src)

  sources <- list(a = test_source(), b = src)
  expect_identical(resolve_sql_source(sources, "b"), src)

  expect_snapshot(resolve_sql_source(sources, "nope"), error = TRUE)
  expect_snapshot(resolve_sql_source(sources, NULL), error = TRUE)
})

test_that("as_data_sources validates its input", {
  expect_snapshot(as_data_sources("nope"), error = TRUE)
  expect_snapshot(as_data_sources(list()), error = TRUE)
  expect_snapshot(as_data_sources(list(sales_db = "not a source")), error = TRUE)
  expect_snapshot(
    as_data_sources(list(sales_db = test_source(), board = list())),
    error = TRUE
  )
  expect_snapshot(
    as_data_sources(list(test_source(), test_source())),
    error = TRUE
  )
  expect_snapshot(
    as_data_sources(list(a = test_source(), a = test_source())),
    error = TRUE
  )
})

test_that("parquet/csv pins register as zero-copy views over the pins cache", {
  skip_if_not_installed("pins")
  skip_if_not_installed("nanoparquet")

  board <- pins::board_temp()
  suppressMessages({
    pins::pin_write(board, data.frame(id = 1:3, v = letters[1:3]), "p-parquet", type = "parquet")
    pins::pin_write(board, data.frame(id = 4:6, v = letters[4:6]), "p-csv", type = "csv")
  })
  src <- data_source(
    board,
    tables = c(parquet_t = "p-parquet", csv_t = "p-csv")
  )

  state <- data_source_state(src)
  for (table in c("parquet_t", "csv_t")) {
    res <- source_query(src, sprintf("SELECT * FROM %s", table))
    expect_equal(nrow(res), 3)
    # Registered as a view over the cache file, not a copied table
    catalog <- DBI::dbGetQuery(
      state$con,
      "SELECT table_type FROM information_schema.tables WHERE table_name = $1",
      params = list(table)
    )
    expect_equal(catalog$table_type, "VIEW")
    # The view reads the pin's versioned file directly
    expect_true(file.exists(state$pending$views[[table]]$path))
  }
})

test_that("rds pins still load eagerly as tables", {
  skip_if_not_installed("pins")

  board <- board_with_pins("team-orders" = data.frame(id = 1:3))
  src <- data_source(board, tables = c(orders = "team-orders"))

  res <- source_query(src, "SELECT * FROM orders")
  expect_equal(nrow(res), 3)
  catalog <- DBI::dbGetQuery(
    data_source_state(src)$con,
    "SELECT table_type FROM information_schema.tables WHERE table_name = 'orders'"
  )
  expect_equal(catalog$table_type, "BASE TABLE")
})

test_that("a dangling pin view is re-resolved and retried transparently", {
  skip_if_not_installed("pins")
  skip_if_not_installed("nanoparquet")

  board <- pins::board_folder(withr::local_tempdir(), versioned = FALSE)
  suppressMessages(
    pins::pin_write(board, data.frame(id = 1L), "orders", type = "parquet")
  )
  src <- data_source(board, tables = c(orders = "orders"))

  expect_equal(source_query(src, "SELECT * FROM orders")$id, 1L)
  view_path <- data_source_state(src)$pending$views$orders$path

  # A rewrite on a non-versioned board deletes the old version's directory
  suppressMessages(
    pins::pin_write(board, data.frame(id = 1:2), "orders", type = "parquet")
  )
  expect_false(file.exists(view_path))

  # The next query re-resolves the latest version and succeeds
  expect_equal(source_query(src, "SELECT * FROM orders")$id, 1:2)
  expect_true(file.exists(data_source_state(src)$pending$views$orders$path))
})
