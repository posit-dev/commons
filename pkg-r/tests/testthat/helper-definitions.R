local_definitions_dict <- function(
  definitions = c(
    "      - name: emea",
    "        description: EMEA rows only.",
    "        expr: region = 'EMEA'",
    "      - name: big_revenue",
    "        description: Revenue over big EMEA orders.",
    "        expr: SUM(CASE WHEN emea AND revenue > 600 THEN revenue ELSE 0 END)",
    "      - name: region_band",
    "        description: Coarse region grouping.",
    "        expr: CASE WHEN emea THEN 'east' ELSE 'west' END"
  ),
  env = parent.frame()
) {
  path <- withr::local_tempfile(fileext = ".yaml", .local_envir = env)
  writeLines(
    c(
      "name: retail sales",
      "description: Order and revenue data for a small retailer.",
      "tables:",
      "  - name: sales",
      "    description: One row per order line.",
      "    columns:",
      "      - name: revenue",
      "        type: number(quantity)",
      "      - name: region",
      "        type: enum",
      "        values: [Americas, APAC, EMEA]",
      "    definitions:",
      definitions
    ),
    path
  )
  path
}

definitions_source <- function(...) {
  data_source(sales = test_sales(), dictionary = local_definitions_dict(...))
}

sales_registry <- function(src) {
  definitions_registry(list(sales_db = src))
}

empty_definitions <- function() {
  definitions_registry(list())
}

# A roster that overflows the ambient prompt cap.
many_definitions <- function(n = 400) {
  unlist(lapply(seq_len(n), function(i) {
    c(
      sprintf("      - name: filter_%03d", i),
      sprintf("        expr: revenue > %d", i),
      sprintf("        description: Filter number %d of many.", i)
    )
  }))
}

# call_metrics_impl() with its registry and source wired up, so tests read as
# the tool call the model would make.
metrics_caller <- function(src = definitions_source(), store = NULL) {
  registry <- sales_registry(src)
  function(...) {
    call_metrics_impl(registry, list(sales_db = src), store, ...)
  }
}

# Records from the shared definition-rendering fixture, hydrated into the two
# shapes this package consumes: a row of the registry data frame, and the
# definition list the dictionary attaches to a table.
fixture_definition <- function(key) {
  record <- shared_fixture("definition-rendering")$records$values[[key]]
  record <- record[!vapply(record, is.null, logical(1))]
  for (field in intersect(definition_list_fields, names(record))) {
    record[[field]] <- as.character(unlist(record[[field]]))
  }
  record
}

fixture_registry <- function(keys) {
  rows <- lapply(keys, function(key) {
    record <- fixture_definition(key)
    row <- data.frame(
      name = record$name,
      table = record$table,
      source = record$source,
      stringsAsFactors = FALSE
    )
    for (field in definition_scalar_fields) {
      row[[field]] <- record[[field]] %||% NA_character_
    }
    row$mixed_grain <- record$mixed_grain
    for (field in definition_list_fields) {
      row[[field]] <- I(list(record[[field]] %||% character()))
    }
    row
  })
  list(defs = do.call(rbind, rows))
}

# The fixture names why a query must be refused; the wording is this package's.
definition_refusal_pattern <- c(
  table_not_in_query = "does not appear in this query",
  unknown_token = "No governed definition matches",
  ambiguous_token = "is ambiguous here"
)
