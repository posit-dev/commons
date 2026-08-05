# catalog validation rejects dangling references

    Code
      new_commons_catalog(sources = list(source), relations = list(relation))
    Condition
      Error:
      ! Catalog entity "relation:test" has unknown source_id reference: "source:missing".

# dictionary projection rejects ambiguous table names

    Code
      catalog_to_data_dictionary(catalog)
    Condition
      Error:
      ! Catalog relations cannot be projected to a data dictionary because table names are ambiguous: "orders".

# relative authored relation matches must be unambiguous

    Code
      catalog_merge(discovered, authored)
    Condition
      Error:
      ! Authored relation "orders" is ambiguous; it matches "ANALYTICS.PUBLIC.ORDERS" and "ANALYTICS.STAGING.ORDERS".

# calculations require typed adapter-owned bindings

    Code
      new_catalog_calculation("calculation:bad", "source:test", "bad", arguments = arguments,
        execution = new_catalog_execution("parameterized_sql", "snowflake",
          "SELECT 1", list(new_catalog_binding("month"))))
    Condition
      Error in `catalog_execution()`:
      ! Execution bindings must correspond exactly to calculation arguments.
      x Missing bindings: "region".

---

    Code
      new_catalog_argument("string", binding = "identifier")
    Condition
      Error in `new_catalog_argument()`:
      ! Identifier calculation arguments require an explicit allowlist.

