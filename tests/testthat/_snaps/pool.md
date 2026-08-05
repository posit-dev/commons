# rejected native metrics leave no trusted or callable surface

    Code
      call_metrics_impl(registry, list(warehouse = fixture$source), new_handle_store(),
      metrics = "record_count")
    Condition
      Error in `source_query()`:
      ! permission denied

# native definitions require qualification only when ambiguous

    Code
      resolve_pool_name("REVENUE", defs, "metric")
    Condition
      Error in `resolve_pool_name()`:
      ! Governed name "REVENUE" is ambiguous.
      i Use a qualified name: "DB.PUBLIC.MODEL_A.ORDERS.REVENUE" and "DB.PUBLIC.MODEL_B.ORDERS.REVENUE".

