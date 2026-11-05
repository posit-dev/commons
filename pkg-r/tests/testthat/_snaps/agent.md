# agent() validates its inputs

    Code
      agent(client = "not a chat", commons = cm)
    Condition
      Error in `agent()`:
      ! `client` must be an <ellmer::Chat>, e.g. from `ellmer::chat_anthropic()`.

---

    Code
      agent(test_client(), commons = test_source())
    Condition
      Error in `agent()`:
      ! `commons` must be a `commons()` object, not a <commons_data_source> object.
      i Gather data sources and layers with `commons(data_sources = ...)`.

---

    Code
      agent(test_client(), commons = cm, log = TRUE, share_with = 1)
    Condition
      Error in `agent()`:
      ! `share_with` must be a character vector of Connect usernames.

