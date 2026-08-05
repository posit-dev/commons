# catalog calculation values are bound and identifiers are allowlisted

    Code
      call_catalog_calculation(registry, "sales_value",
        "{\"region\":\"EMEA\",\"column\":\"order_id; DROP TABLE sales\"}")
    Condition
      Error in `call_catalog_calculation()`:
      ! Calculation argument `column` is not an allowed value.
      i Allowed values: "order_id" and "revenue".

---

    Code
      call_catalog_calculation(registry, "sales_value", "{\"column\":\"order_id\"}")
    Condition
      Error in `call_catalog_calculation()`:
      ! Arguments do not match trusted calculation "sales_value".
      x Missing arguments: "region".

---

    Code
      call_catalog_calculation(registry, "sales_value",
        "{\"region\":\"EMEA\",\"column\":\"order_id\",\"extra\":1}")
    Condition
      Error in `call_catalog_calculation()`:
      ! Arguments do not match trusted calculation "sales_value".
      x Unknown arguments: "extra".

---

    Code
      call_catalog_calculation(registry, "sales_value",
        "{\"region\":12,\"column\":\"order_id\"}")
    Condition
      Error in `call_catalog_calculation()`:
      ! Calculation argument `region` must be a "string" value.

# catalog calculations do not trust rejected execution

    Code
      call_catalog_calculation(registry, "sales_count")
    Condition
      Error in `source_query()`:
      ! The query contains a disallowed operation: `DELETE`.
      i Only read-only SELECT queries are allowed.

