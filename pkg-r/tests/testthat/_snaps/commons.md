# commons() requires named arguments

    Code
      commons(test_source())
    Condition
      Error in `commons()`:
      ! `...` must be empty.
      x Problematic argument:
      * ..1 = test_source()
      i Did you forget to name an argument?

---

    Code
      commons()
    Condition
      Error in `commons()`:
      ! `data_sources` is absent but must be supplied.

# commons() validates its inputs

    Code
      commons(data_sources = "not a source")
    Condition
      Error in `commons()`:
      ! `data_sources` must be a `data_source()` or a named list of them.

---

    Code
      commons(data_sources = test_source(), context_layer = "not context")
    Condition
      Error in `commons()`:
      ! `context_layer` must be a `context_layer()` or `NULL`.

---

    Code
      commons(data_sources = test_source(), semantic_layer = list())
    Condition
      Error in `commons()`:
      ! `semantic_layer` must be a `semantic_layer()`.

# commons() errors on injection parameters matching no name

    Code
      commons(data_sources = list(sales_db = test_source()), semantic_layer = layer)
    Condition
      Error in `commons()`:
      ! Measure "region_revenue" has undocumented argument `warehouse` matching no data source.
      i Available sources: "sales_db".

---

    Code
      commons(data_sources = test_source(), semantic_layer = layer)
    Condition
      Error in `commons()`:
      ! Measure "region_revenue" has undocumented argument `warehouse` matching no data source.
      i `data_sources` has no named sources.

# commons() still builds an agent when called the old way

    Code
      old <- commons(test_client(), list(sales_db = test_source()), layer, mode = "trusted only")
    Condition
      Warning:
      The `client` argument of `commons()` is deprecated as of commons 0.2.0.
      i Please use `agent()` instead.
      i Build the commons with `commons(data_sources = ...)`, then pass it to `agent(client, commons = commons)`.

---

    Code
      commons(client = "not a chat", data_sources = test_source())
    Condition
      Warning:
      The `client` argument of `commons()` is deprecated as of commons 0.2.0.
      i Please use `agent()` instead.
      i Build the commons with `commons(data_sources = ...)`, then pass it to `agent(client, commons = commons)`.
      Error in `agent()`:
      ! `client` must be an <ellmer::Chat>, e.g. from `ellmer::chat_anthropic()`.

---

    Code
      commons(test_client(), test_source(), NULL, NULL, "prompt")
    Condition
      Warning:
      The `client` argument of `commons()` is deprecated as of commons 0.2.0.
      i Please use `agent()` instead.
      i Build the commons with `commons(data_sources = ...)`, then pass it to `agent(client, commons = commons)`.
      Error in `commons()`:
      ! `...` must be empty.
      x Problematic argument:
      * ..1 = "prompt"
      i Did you forget to name an argument?

# $search() names the commons object's methods

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

# commons() prints its contents and method signatures

    Code
      tr
    Output
      <commons>
      Sources: sales_db. Tables: sales.
      Measures:
        - order_count: Count orders, optionally filtered by region and a revenue ceiling.
      Governed metrics: 3. Find them with `$search()`.
      Methods:
        $search(query)
        $measure(name, arguments = list())
        $metrics(metrics, dimensions = NULL, filters = NULL, where = NULL, arguments = list(), source = NULL)
        $context(query)
        $describe(table, source = NULL)
        $connection(source = NULL)
      This object provides access to trusted code and context. Before writing
      your own analysis code or SQL, look for existing code with `$search()`
      and run it with `$measure()` or `$metrics()`. When none fits, check
      `$context("your query")` for guidance on the approach. Say in your
      answer which numbers came from trusted calculations and which didn't.

# commons() lists only the calculation methods it can run

    Code
      commons(data_sources = list(sales_db = test_source()))
    Output
      <commons>
      Sources: sales_db. Tables: sales.
      Methods:
        $search(query)
        $context(query)
        $describe(table, source = NULL)
        $connection(source = NULL)
      This object provides access to trusted code and context. Before writing
      your own analysis code or SQL, check `$context("your query")` for
      guidance on the approach. Say in your answer which numbers came from
      trusted calculations and which didn't.

