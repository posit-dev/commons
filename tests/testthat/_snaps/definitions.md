# definition envelopes are validated

    Code
      definitions_source(definitions = c("      - name: emea",
        "        type: boolean"))
    Condition
      Error in `data_dictionary()`:
      ! Definition "emea" on table "sales" is missing expr.

---

    Code
      definitions_source(definitions = c("      - name: emea",
        "        expr: region = 'EMEA'"))
    Condition
      Error in `data_dictionary()`:
      ! Definition "emea" on table "sales" is missing type.

---

    Code
      definitions_source(definitions = c("      - name: not a name",
        "        type: boolean", "        expr: region = 'EMEA'"))
    Condition
      Error in `data_dictionary()`:
      ! Definition names must be identifiers (letters, digits, and underscores); "not a name" on table "sales" is not.
      i Names become tokens like `{{not a name}}` in SQL and bare references in sibling expressions.

# a definition can't shadow a documented column

    Code
      definitions_source(definitions = c("      - name: region",
        "        type: boolean", "        expr: region = 'EMEA'"))
    Condition
      Error in `data_dictionary()`:
      ! Definitions on table "sales" must not share a name with its documented columns: "region".

# reference cycles error at parse

    Code
      definitions_source(definitions = c("      - name: chicken",
        "        type: boolean", "        expr: egg AND revenue > 0",
        "      - name: egg", "        type: boolean",
        "        expr: chicken AND revenue < 10"))
    Condition
      Error in `data_dictionary()`:
      ! Definitions on table "sales" reference each other in a cycle: chicken -> egg -> chicken.

# definitions on unexposed tables abort registry construction

    Code
      definitions_registry(list(sales_db = src))
    Condition
      Error:
      ! The data dictionary declares definitions on table "elsewhere", which the data source does not expose.

# token resolution errors are actionable

    Code
      expand_definitions("SELECT {{nope}} FROM sales", records)
    Condition
      Error:
      ! No governed definition matches `{{nope}}`.
      i Available definitions: `{{emea}} (sales)`, `{{big_revenue}} (sales)`, and `{{region_band}} (sales)`.

---

    Code
      expand_definitions("SELECT {{emea}} FROM elsewhere", records)
    Condition
      Error:
      ! `{{emea}}` is defined on table "sales", which does not appear in this query.

# same-named definitions on several tables disambiguate by scope

    Code
      expand_definitions(
        "SELECT count(*) FROM sales JOIN reps USING (rep) WHERE {{deduplicated}}",
        records)
    Condition
      Error:
      ! `{{deduplicated}}` is ambiguous here: it is defined on several tables in this query.
      i Qualify the token: `{{sales.deduplicated}}` or `{{reps.deduplicated}}`.

