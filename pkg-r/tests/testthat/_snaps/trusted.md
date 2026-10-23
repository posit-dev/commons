# commons() builds an agent around a trusted() object

    Code
      commons(test_client(), tr, semantic_layer = semantic_layer())
    Condition
      Error in `commons()`:
      ! Pass `semantic_layer` and `context_layer` to `trusted()`, not `commons()`, when `data_sources` is a `trusted()` object.

# $search() names the trusted object's methods

    Code
      tr$search("big revenue region orders")
    Output
      ### {{big_revenue}} --- metric on table `sales`
      Revenue over big EMEA orders.
      Selected SQL(duckdb): `(sum(CASE WHEN ("region" = 'EMEA') AND "revenue" > 600 THEN "revenue" ELSE 0 END))`.
      Translation notes: DuckDB compares a NaN as equal to itself and greater than every number, where data-dict answers false; a row holding one passes here and is reported there. DuckDB sums integers at 128 bits, so a total data-dict reports as an overflow (D09) may succeed.
      Query with `$metrics("big_revenue")`.
      Filters and derived definitions on this table: {{emea}} (filter), {{region_band}} (derived).
      
      ### order_count
      Count orders, optionally filtered by region and a revenue ceiling.
      
      arguments:
        - region (array of {Americas, APAC, EMEA}, optional) 
        - revenue_under (number, optional) 
      Run with `$measure("order_count")`.
      
      ### {{emea}} --- filter on table `sales`
      EMEA rows only.
      Selected SQL(duckdb): `("region" = 'EMEA')`.
      Use as a `$metrics()` filter or dimension.
      
      ### {{region_band}} --- derived on table `sales`
      Coarse region grouping.
      Selected SQL(duckdb): `(CASE WHEN ("region" = 'EMEA') THEN 'east' ELSE 'west' END)`.
      Use as a `$metrics()` dimension.

# $metrics() accepts `where` as a string or unnamed triples

    Code
      tr$metrics("big_revenue", where = "region IN ('EMEA', 'APAC')")
    Condition
      Error in `tr$metrics()`:
      ! `where` must be simple conditions on documented columns.
      i Pass a string like `"project = 'dplyr' AND date >= '2026-06-01'"`, or a list of `c(column, op, value)` triples.
      i Operators: `=`, `!=`, `<`, `<=`, `>`, and `>=`, joined by `AND`.
    Code
      tr$metrics("big_revenue", where = list(c("region", "EMEA")))
    Condition
      Error in `tr$metrics()`:
      ! `where` must be simple conditions on documented columns.
      i Pass a string like `"project = 'dplyr' AND date >= '2026-06-01'"`, or a list of `c(column, op, value)` triples.
      i Operators: `=`, `!=`, `<`, `<=`, `>`, and `>=`, joined by `AND`.

