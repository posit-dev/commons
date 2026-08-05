# Snowflake reports a missing current namespace

    Code
      snowflake_default_objects(NULL, rlang::current_env())
    Condition
      Error:
      ! The Snowflake connection does not have both a current database and schema.
      i Set both on the connection or select a namespace with `data_source_options(include = DBI::Id(catalog = "...", schema = "..."))`.

# Snowflake semantic-view variables are typed and quoted

    Code
      snowflake_variable_clause(variables, "{}", con)
    Condition
      Error in `snowflake_variable_clause()`:
      ! Semantic-view variables do not match the model.
      x Missing variables: "threshold".

---

    Code
      snowflake_variable_clause(variables, "{\"threshold\":\"not numeric\"}", con)
    Condition
      Error in `snowflake_variable_value()`:
      ! Semantic-view variable type "NUMBER(10,2)" requires a number.

