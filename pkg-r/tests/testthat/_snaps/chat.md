# commons_app requires a commons agent

    Code
      commons_app(test_client())
    Condition
      Error in `commons_app()`:
      ! `client` must be an agent created by `commons()`.

# commons_server requires a commons agent

    Code
      commons_server("chat", client = test_client())
    Condition
      Error in `commons_server()`:
      ! `client` must be an agent created by `commons()`.

