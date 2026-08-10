# Snowflake current namespace requires a database and schema

    Code
      snowflake_current_namespace(NULL)
    Condition
      Error:
      ! The Snowflake connection has no current database and schema.
      i Set both on the connection or supply `tables` as a <DBI::Id>.

