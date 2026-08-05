# Databricks metric-view parameters are typed and quoted

    Code
      databricks_metric_source(object, parameters, "{}", con)
    Condition
      Error in `databricks_metric_source()`:
      ! Metric-view parameters do not match the model.
      x Missing parameters: "discount".

---

    Code
      databricks_metric_source(object, parameters, "{\"discount\":\"not a number\"}",
        con)
    Condition
      Error in `databricks_parameter_value()`:
      ! Metric-view parameter type "double" requires a number.

