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
      commons(client = test_client(), data_sources = test_source(), log = "yes")
    Condition
      Error in `commons()`:
      ! `log` must be `TRUE` or `FALSE`.

---

    Code
      commons(client = test_client(), data_sources = test_source(), log = TRUE,
      share_with = 1)
    Condition
      Error in `commons()`:
      ! `share_with` must be a character vector of Connect usernames.

# commons() errors on injection parameters matching no name

    Code
      commons(client = test_client(), data_sources = list(sales_db = test_source()),
      semantic_layer = layer)
    Condition
      Error in `initialize()`:
      ! Measure "region_revenue" has undocumented argument `warehouse` matching no data source.
      i Available sources: "sales_db".

---

    Code
      commons(client = test_client(), data_sources = test_source(), semantic_layer = layer)
    Condition
      Error in `initialize()`:
      ! Measure "region_revenue" has undocumented argument `warehouse` matching no data source.
      i `data_sources` has no named sources.

