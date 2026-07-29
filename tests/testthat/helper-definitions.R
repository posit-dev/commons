local_definitions_dict <- function(
  definitions = c(
    "      - name: emea",
    "        type: boolean",
    "        description: EMEA rows only.",
    "        expr: region = 'EMEA'",
    "      - name: big_revenue",
    "        type: number(quantity)",
    "        description: Revenue over big EMEA orders.",
    "        expr: SUM(revenue) FILTER (WHERE emea AND revenue > 600)",
    "      - name: region_band",
    "        type: string",
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
      "        type: boolean",
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
