# commons() validates its inputs

    Code
      commons(client = "not a chat", data_source = test_source())
    Condition
      Error in `commons()`:
      ! `client` must be an <ellmer::Chat>, e.g. from `ellmer::chat_anthropic()`.

---

    Code
      commons(client = test_client(), data_source = "not a source")
    Condition
      Error in `commons()`:
      ! `data_source` must be a `data_source()`.

---

    Code
      commons(client = test_client(), data_source = test_source(), context_layer = "not context")
    Condition
      Error in `commons()`:
      ! `context_layer` must be a `context_layer()` or `NULL`.

---

    Code
      commons(client = test_client(), data_source = test_source(), semantic_layer = list())
    Condition
      Error in `commons()`:
      ! `semantic_layer` must be a `semantic_layer()`.

