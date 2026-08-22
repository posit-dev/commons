# semantic_layer validates its measures

    Code
      semantic_layer(2026)
    Condition
      Error in `semantic_layer()`:
      ! Every item in `semantic_layer` must be created by `measure()`.

---

    Code
      semantic_layer(count_measure_tool(), count_measure_tool())
    Condition
      Error in `semantic_layer()`:
      ! Measure names must be unique; duplicated name: "order_count".

# semantic_layer surfaces read_measures errors for bad paths

    Code
      semantic_layer("not a measure")
    Condition
      Error in `read_measures()`:
      ! Path does not exist: 'not a measure'.

# validate_measure_args rejects out-of-vocabulary enum values

    Code
      validate_measure_args(count_measure_tool(), list(region = "LATAM"))
    Condition
      Error:
      ! Invalid value for `region` of measure "order_count": "LATAM".
      i Allowed: "Americas", "APAC", and "EMEA".

# validate_measure_args rejects unknown arguments

    Code
      validate_measure_args(count_measure_tool(), list(nope = 1))
    Condition
      Error:
      ! Unknown argument for measure "order_count": "nope".
      i Valid arguments: "region" and "revenue_under".

# validate_measure_args enforces required arguments

    Code
      validate_measure_args(td, list())
    Condition
      Error:
      ! Measure "needs_x" requires argument `x`.

