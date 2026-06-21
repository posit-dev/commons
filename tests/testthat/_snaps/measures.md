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

