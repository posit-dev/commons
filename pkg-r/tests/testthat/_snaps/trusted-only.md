# a trusted-only agent needs a trusted calculation

    Code
      trusted_agent()
    Condition
      Error:
      ! `mode = "trusted only"` needs at least one trusted calculation.
      i Add measures to `semantic_layer`, governed metric definitions to a data dictionary, or a warehouse semantic model.

# a trusted-only agent has no R session to open to the network

    Code
      trusted_agent(semantic_layer = semantic_layer(count_measure_tool()), network = "full")
    Condition
      Error in `commons()`:
      ! `network = "full"` can't be combined with `mode = "trusted only"`, which has no R session.

# call_metrics errors don't point at fallback tools

    Code
      call(dimensions = "above_minimum")
    Condition
      Error in `dimension_sql()`:
      ! Mixed-grain definition "above_minimum" cannot be grouped by with `call_metrics()`, and no other trusted calculation can group by it.

---

    Code
      call(filters = "above_minimum")
    Condition
      Error in `call_metrics_impl()`:
      ! Mixed-grain filter "above_minimum" cannot be applied by `call_metrics()`, and no other trusted calculation can apply it.

