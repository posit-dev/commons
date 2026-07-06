# commons() validates its inputs

    Code
      commons(client = "not a chat", data_sources = test_source())
    Condition
      Error in `commons()`:
      ! `client` must be an <ellmer::Chat>, e.g. from `ellmer::chat_anthropic()`.

---

    Code
      commons(client = test_client(), data_sources = "not a source")
    Condition
      Error in `commons()`:
      ! `data_sources` must be a `data_source()` or a named list of them.

---

    Code
      commons(client = test_client(), data_sources = test_source(), context_layer = "not context")
    Condition
      Error in `commons()`:
      ! `context_layer` must be a `context_layer()` or `NULL`.

---

    Code
      commons(client = test_client(), data_sources = test_source(), semantic_layer = list())
    Condition
      Error in `commons()`:
      ! `semantic_layer` must be a `semantic_layer()`.

---

    Code
      commons(client = test_client(), data_sources = test_source(), resources = list(
        1, 2))
    Condition
      Error in `commons()`:
      ! `resources` must be a named list.

---

    Code
      commons(client = test_client(), data_sources = list(a = test_source(), b = test_source()))
    Condition
      Error in `initialize()`:
      ! `commons()` currently supports exactly one data source, not 2.

# commons() errors on injection parameters matching no name

    Code
      commons(client = test_client(), data_sources = list(sales_db = test_source()),
      semantic_layer = layer)
    Condition
      Error in `initialize()`:
      ! Measure "region_revenue" has undocumented argument `warehouse` matching no data source or resource name.
      i Available names: "sales_db".

---

    Code
      commons(client = test_client(), data_sources = test_source(), semantic_layer = layer)
    Condition
      Error in `initialize()`:
      ! Measure "region_revenue" has undocumented argument `warehouse` matching no data source or resource name.
      i No named data sources or resources are available.

# commons() rejects resource names that collide with source names

    Code
      commons(client = test_client(), data_sources = list(sales_db = test_source()),
      resources = list(sales_db = "duplicate"))
    Condition
      Error in `initialize()`:
      ! `resources` names must not collide with data source names: "sales_db".

