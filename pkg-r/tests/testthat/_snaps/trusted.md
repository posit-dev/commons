# trusted() runs measures and records the call

    Code
      print(n)
    Output
      [1] 3
      # trusted: measure order_count(region = "EMEA")

# commons() builds an agent around a trusted() object

    Code
      commons(test_client(), tr, semantic_layer = semantic_layer())
    Condition
      Error in `commons()`:
      ! Pass `semantic_layer` and `context_layer` to `trusted()`, not `commons()`, when `data_sources` is a `trusted()` object.

