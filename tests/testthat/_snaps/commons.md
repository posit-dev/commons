# commons() validates its inputs

    Code
      commons(client = "not a chat", source = test_source())
    Condition
      Error in `commons()`:
      ! `client` must be an <ellmer::Chat>, e.g. from `ellmer::chat_anthropic()`.

---

    Code
      commons(client = test_client(), source = "not a source")
    Condition
      Error in `commons()`:
      ! `source` must be a `data_source()`.

