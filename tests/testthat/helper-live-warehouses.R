local_warehouse_connection <- function(backend, env = parent.frame()) {
  backend <- match.arg(backend, c("snowflake", "databricks"))
  skip_unless_live_warehouse(backend)
  skip_if_not_installed("odbc")

  con <- switch(
    backend,
    snowflake = DBI::dbConnect(
      odbc::snowflake(),
      warehouse = live_warehouse_setting("COMMONS_SNOWFLAKE_WAREHOUSE")
    ),
    databricks = DBI::dbConnect(
      odbc::odbc(),
      Sys.getenv("COMMONS_DATABRICKS_DSN", unset = "Databricks")
    )
  )
  withr::defer(DBI::dbDisconnect(con), envir = env)
  con
}

live_warehouse_setting <- function(name) {
  value <- Sys.getenv(name, unset = NA_character_)
  if (is.na(value) || !nzchar(value)) {
    skip(paste("Missing live warehouse configuration:", name))
  }
  value
}

warehouse_test_objects <- function(backend) {
  backend <- match.arg(backend, c("snowflake", "databricks"))
  skip_unless_live_warehouse(backend)

  prefix <- toupper(backend)
  top_level <- if (identical(backend, "snowflake")) "DATABASE" else "CATALOG"
  names <- paste0(
    "COMMONS_", prefix, "_", c(top_level, "SCHEMA", "TABLE")
  )
  values <- Sys.getenv(names, unset = NA_character_)
  missing <- names[is.na(values) | !nzchar(values)]
  if (length(missing)) {
    skip(paste("Missing live warehouse configuration:", paste(missing, collapse = ", ")))
  }

  list(table = DBI::Id(
    catalog = unname(values[[1]]),
    schema = unname(values[[2]]),
    table = unname(values[[3]])
  ))
}

skip_unless_live_warehouse <- function(backend) {
  variable <- paste0("COMMONS_LIVE_", toupper(backend))
  skip_if_not(
    identical(tolower(Sys.getenv(variable)), "true"),
    paste0("Set ", variable, "=true to run live warehouse tests")
  )
}

warehouse_read_one <- function(con, id) {
  sql <- paste(
    "SELECT * FROM",
    DBI::dbQuoteIdentifier(con, id),
    "LIMIT 1"
  )
  DBI::dbGetQuery(con, sql)
}
