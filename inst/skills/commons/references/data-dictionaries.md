# Use data dictionaries with commons

## Contents

- [Project convention](#project-convention)
- [What to capture](#what-to-capture)
- [How commons uses it](#how-commons-uses-it)
- [Warehouse reconciliation](#warehouse-reconciliation)
- [Governed definitions](#governed-definitions)
- [Validate](#validate)

Use this reference when creating, reviewing, or editing a data dictionary for
a commons agent. Follow the
[data-dict documentation](https://data-dict.tidyverse.org/) for the general
`data-dict.yaml` format. This reference describes how commons uses that format
and its commons-specific extensions.

## Project convention

Create one dictionary for each `data_source()` and name the file after the
source in the `commons()` call:

```r
sources <- list(
  warehouse = data_source(
    con,
    dictionary = "dictionaries/warehouse.yaml"
  )
)
```

Dictionary table names must identify tables exposed by that source. Do not
combine unrelated sources in one dictionary or use a dictionary to describe
tables the agent cannot query.

## What to capture

Prioritize information the agent needs to interpret and query the source:

* Dataset descriptions, details, and glossary terms.
* Table grain, purpose, and caveats.
* Column meanings, types, units, values, ranges, examples, and constraints.
* Relationships demonstrated by schemas, trusted code, or verified
  exploration.

Treat the dictionary as curated context, not a copy of the source schema. Be
mindful of its total size and do not document every column by default. If a
column entry would only repeat a name or type available from the live schema,
omit it unless the agent needs that column as a dimension or `where` operand
in `call_metrics`. Prioritize columns whose meaning, units, valid values,
caveats, relationships, or analytical role are not evident from the schema.

Prefer the dictionary over `context_layer()` for information that belongs to a
dataset, table, column, or relationship. Keep one authoritative copy of each
fact and do not add claims that the available evidence does not support.

## How commons uses it

Commons delivers dictionary content progressively:

* Dataset-level descriptions and details are available in the system prompt,
  along with as many glossary terms as fit within its size cap. Remaining
  glossary terms are searchable and arrive on first touch when a table entry
  references them.
* The first time a conversation uses a table, its description, details,
  documented columns, relationships, and governed definitions are delivered
  with the tool result. `describe_table` combines the dictionary entry with the
  live schema.
* Dictionary prose and governed definitions are indexed for context search.
  Column details remain first-touch content rather than a second searchable
  copy.

Put broadly applicable source guidance at the dataset level and table-specific
guidance on the table. This keeps ambient context small while making detailed
information available when it becomes relevant.

## Warehouse reconciliation

For Snowflake and Databricks sources, commons supplements an authored
dictionary with catalog metadata. Authored prose takes precedence, while
discovered column types and nullability remain authoritative.

Reconcile every authored table with the selected relations during onboarding.
Use fully qualified table names when a relative name could match more than one
relation. Surface missing, ambiguous, or unexpectedly excluded tables to the
user rather than silently changing the agent's scope.

## Governed definitions

Commons supports a table-level `definitions` field for named, typed, governed
SQL expressions:

```yaml
tables:
  - name: orders
    definitions:
      - name: realized
        type: boolean
        description: Orders that were shipped.
        expr: status_cd = 90
```

Each definition requires `name`, `type`, and `expr`. `label`, `description`,
and `details` are optional. Boolean definitions act as filters, aggregate
expressions act as metrics, and other expressions act as dimensions.
Definition names must be identifiers and must not shadow columns. Definitions
on the same table may refer to one another by name, but references must not
form a cycle. Boolean definitions must describe row-level values rather than
aggregate expressions.

The agent can apply definitions as `{{name}}` tokens in SQL. When the same name
exists on multiple tables in a query, qualify it as `{{table.name}}`. Metrics
can also be called through `call_metrics`. Add a definition only when its
business meaning and computation come from trusted existing material and the
user confirms any consequential choice. Do not invent a calculation merely
to complete the dictionary.

The typed definition envelope is a commons extension. Use data-dict validation
for the parts of the file it supports, but do not make support in the
data-dict CLI a prerequisite for using functionality supported by commons.

## Validate

Use data-dict validation where useful, then verify the commons integration:

* Confirm dictionary table names map to the intended exposed tables.
* Compare documented columns and types with the live schema.
* Confirm relationships and definition expressions use real tables and
  columns.
* Construct the data sources and agent to catch commons-specific parsing,
  naming, reference, and source-mapping errors.
* Exercise each definition against the live source with `run_sql` or
  `call_metrics`, as appropriate. Agent construction does not execute the SQL
  expressions, so it cannot catch missing columns or backend-specific SQL
  errors.
