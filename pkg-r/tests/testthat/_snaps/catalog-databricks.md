# Databricks identifiers cannot skip components

    Code
      databricks_id_type(DBI::Id(catalog = "main", table = "orders"))
    Condition
      Error:
      ! Databricks <DBI::Id> entries in `tables` must follow catalog, schema, and table order without skipped or empty components.

# Databricks current namespace requires a catalog and schema

    Code
      databricks_current_namespace(NULL)
    Condition
      Error:
      ! The Databricks connection has no current catalog and schema.
      i Set both on the connection or supply `tables` as a <DBI::Id>.

