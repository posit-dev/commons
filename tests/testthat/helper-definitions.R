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

validated_registry <- function(src) {
  registry <- definitions_registry(list(sales_db = src))
  validate_eager_definitions(registry, list(sales_db = src))
  registry
}
