# Semantic Layer Landscape

Issue: [posit-dev/commons#6](https://github.com/posit-dev/commons/issues/6)

Date: 2026-06-24

## Summary

Issue 6 is right: `commons` currently uses "semantic layer" to mean a registry of
callable measures. The usual meaning is broader. A semantic layer is the governed
business model between raw data and consuming tools: metrics, dimensions, entities,
join paths, grain, canonical filters, access rules, and metadata that let BI tools and
AI agents ask for business concepts without rebuilding SQL logic each time.

For `commons`, the practical move is not to become a full semantic-layer product. It is
to treat existing `measure()` objects as the highest-trust subset of a broader
semantic layer, then let the layer also contain structured definitions that currently
get pushed into `context_layer()`: dimensions, allowed values, table grain, joins,
canonical segments, synonyms, metric provenance, and verified examples.

The short design direction:

- Keep `measure()` as a compatibility-preserving high-trust execution path.
- Broaden `semantic_layer()` from "list of measures" to "governed semantic catalog."
- Keep `context_layer()` for lower-trust or less-structured institutional knowledge.
- Make the agent's fallback from semantic layer to context layer explicit and visible.

## The issue in commons

Issue 6 says:

> "Currently just a set of measures."

and:

> "The usual usage of this term is broader"

That matches the code. In `R/measures.R`, `semantic_layer()` expands inputs into
`measure()` objects, checks that every item inherits from `ellmer::ToolDef`, and stores
them in the private state of a `commons_semantic_layer` R6 object. At runtime,
`R/tools.R` exposes that layer through `search_measures` and `call_measure`; the system
prompt requires every data question to start with `search_measures`.

So, in today's package, the semantic layer is effectively:

```r
semantic_layer(
  measure(
    "revenue_by_region",
    "Total revenue for a region.",
    function(region) {
      # trusted calculation body
    },
    arguments = list(region = ellmer::type_string("Sales region."))
  )
)
```

That is valuable, but it is closer to a metrics layer or function registry than to a
full semantic layer.

## How this shows up in tiles-agent

The private `posit-dev/tiles-agent` prototype exposes the mismatch clearly.

Its `R/measures.R` is careful about trust. Measures are wrappers around `dscoetools`
functions. The file distinguishes pass-through measures, where `dscoetools` already
returns the answer, from aggregating measures, where the wrapper adds a rollup and
therefore inherits less of the trusted upstream behavior.

That is exactly the right instinct for a high-trust metrics layer. But the repo also
has semantic material that is not a measure:

- `context-inventory.md` maps measure candidates, data sources, pins, always-on facts,
  table notes, and open questions.
- `measure-schemas.md` documents output columns, filterable columns, valid values, and
  inactive measure candidates.
- `dscoetools-datasources.md` maps each measure to lakehouse tables, Connect pins, board
  behavior, and source-specific gotchas.
- `questions.md` records benchmark questions and data availability notes.

In the current `commons` model, most of that structured knowledge is context, not
semantic layer. But in the usual product meaning, much of it is semantic:

- Tile size values are dimension values.
- "Mid-Market-3 to Enterprise-3" is a named segment/filter.
- "ARR under 100K" is a canonical interpretation rule that should map to a field.
- Measure output schemas and filterable columns are part of metric metadata.
- Lakehouse/pin/source-function mappings are provenance and lineage.
- Group 1 vs. Group 2 is trust/certification status.

The tiles app should not become a package dependency or fixture. But it is a useful
example of the missing abstraction: a semantic layer needs to represent governed
business structure, not only executable metric functions.

## Usual meaning across products

Across current products, "semantic layer" usually means an execution-oriented business
model, not a documentation pile.

AtScale's glossary gives the broad, vendor-neutral version: a semantic layer sits
between the warehouse and consuming tools, defines business terms, metrics, data
relationships, and access rules, and maps plain-English requests to the right tables
and calculations. It standardizes metrics, dimensions, relationships, terminology, and
access rules. [AtScale glossary](https://www.atscale.com/glossary/semantic-layer/)

Cube's framing is similar: define metrics, dimensions, join paths, and access rules
once, then serve them consistently to dashboards, embedded apps, spreadsheets, and AI
agents. Cube also emphasizes that the layer is not the warehouse and not the BI tool;
it sits between them and compiles governed requests into warehouse queries. [Cube
explainer](https://cube.dev/articles/what-is-a-semantic-layer)

Omni's buyer-oriented guide draws a useful line for `commons`: a metrics layer focuses
mainly on reusable measures, while a semantic layer is broader and includes dimensions,
entities, join paths, grain rules, permissions, and governance workflows. Its warning is
also relevant: weak semantic layers become reference libraries instead of controlling
analytics behavior. [Omni guide](https://omni.co/articles/best-semantic-layer-for-ai-and-bi-2026)

The pattern across products is:

| Concept | Usual role |
|---|---|
| Metric / measure | Named calculation, usually aggregate or KPI-like. |
| Dimension / field | Attribute used to group, filter, or slice metrics. |
| Entity | Business object and join key, such as account, order, user, opportunity. |
| Grain | Level at which a source or metric is valid. |
| Join path / relationship | Approved way to combine entities without fanout or double counting. |
| Segment / filter | Canonical population rule, like active customers or enterprise accounts. |
| Metadata | Display names, descriptions, synonyms, owners, provenance, freshness, certification. |
| Compiler / execution path | The mechanism that turns a semantic request into correct SQL or a function call. |

## Databricks analogue

Databricks' closest current analogue is Unity Catalog metric views, under "business
semantics."

Databricks describes metric views as the core implementation of Unity Catalog business
semantics. Metric views separate measure definitions from the fields used to group,
filter, and aggregate them, so metrics are defined once and queried at runtime.
[Unity Catalog metric views](https://docs.databricks.com/aws/en/business-semantics/metric-views/)

The basic Databricks metric-view model is a good checklist for `commons`. A metric view
has:

- `source`: a table, view, metric view, or SQL query.
- `fields`: attributes used to segment or group metrics.
- `measures`: aggregate expressions that produce metrics.
- `filter`: a SQL boolean expression that applies to all queries.
- `joins`: relationships that enrich the source.

Databricks says metric views "create a semantic layer" by defining what to measure, how
to aggregate it, and how to segment it, so users report the same value for a KPI across
the organization. [Model metric views](https://docs.databricks.com/aws/en/business-semantics/metric-views/basic-modeling)

The YAML reference makes the execution shape concrete:

```yaml
version: 1.1
source: catalog.schema.source_table
filter: order_date >= '2024-01-01'
joins:
  - name: customer
    source: catalog.schema.customer
    on: customer_id = id
fields:
  - name: customer_region
    expr: customer.region
measures:
  - name: revenue
    expr: SUM(price * quantity)
```

The important Databricks lesson is not the YAML syntax. It is the separation of
semantic roles:

- Measures are aggregate logic.
- Fields are query-time grouping/filtering attributes.
- Joins are declared and constrained.
- Filters can define scope for all queries.
- Metadata such as display names, formats, and synonyms supports agent and BI use.

Databricks also connects this to natural-language agents through Genie Spaces. A Genie
Space is a domain-specific chat interface curated with Unity Catalog datasets, example
SQL queries, SQL expressions for business semantics, and text instructions tailored to
company terminology. [Genie Spaces](https://docs.databricks.com/aws/en/genie/)

The best-practice docs are especially relevant to `commons`:

> "Prioritize SQL expressions and example SQL over text instructions"

Databricks recommends using structured SQL expressions for business semantics and text
instructions only when structured definitions and examples cannot cover the need.
[Curate an effective Genie Space](https://docs.databricks.com/aws/en/genie/best-practices)

That maps directly to Issue 6. Some things currently placed in `context_layer(always=)`
or indexed markdown should become structured semantic-layer objects first, with free
text as fallback.

## Other product shapes

dbt's Semantic Layer is built on MetricFlow. Its semantic models are nodes in a
semantic graph connected by entities. Dimensions are ways to organize metrics; entities
are join keys; metrics are centrally defined and queried through MetricFlow. [dbt
semantic models](https://docs.getdbt.com/docs/build/semantic-models), [dbt metrics](https://docs.getdbt.com/docs/build/build-metrics-intro)

dbt's join logic is particularly relevant for agents: MetricFlow uses entities to
construct a graph of semantic models and join paths, chooses joins automatically, and
restricts fanout and chasm joins. [dbt joins](https://docs.getdbt.com/docs/build/join-logic)

Looker uses LookML to create semantic data models. LookML describes dimensions,
aggregates, calculations, and data relationships, then Looker constructs SQL from that
model. [LookML introduction](https://docs.cloud.google.com/looker/docs/what-is-lookml)

Power BI's semantic model is closer to a BI-native model. Microsoft describes it as a
source of data ready for reporting and visualization. It can be imported, DirectQuery,
or composite; it includes model design, relationships, calculations, storage mode,
refresh, and row-level security considerations. [Power BI semantic models](https://learn.microsoft.com/en-us/power-bi/connect-data/service-datasets-understand)

Tableau Semantics exposes concepts that line up with the same object set: calculated
measures, relationships with join criteria and cardinality, metrics derived from one or
more measures, and join views. [Tableau Semantics concepts](https://developer.salesforce.com/docs/data/semantic-layer/guide/tableau-semantics-concepts.html)

The products differ in where the layer lives:

- Warehouse-native: Databricks metric views, Snowflake semantic views.
- Transformation-native: dbt Semantic Layer / MetricFlow.
- BI-native: Looker, Power BI, Tableau.
- Headless/API-first: Cube, AtScale, GoodData, Omni-like approaches.

But the shared shape is stable: governed objects, approved relationships, and an
execution path.

## What belongs in commons' semantic layer

`commons` should define a semantic layer as the governed layer of business meaning that
the agent must consult before free-form SQL. It should be broader than measures but
still narrower than all available context.

Proposed object model:

| Object | Purpose |
|---|---|
| `measure()` | Existing executable trusted calculation. |
| `metric()` | Named KPI definition, possibly declarative rather than R-executable. |
| `dimension()` | Field users may group/filter by, with type, values, synonyms, and display metadata. |
| `entity()` | Business object and key/grain declaration. |
| `relationship()` | Approved join path with cardinality and source/target entities. |
| `segment()` | Canonical reusable filter or population definition. |
| `semantic_model()` | Domain-scoped bundle of source, entities, dimensions, metrics, joins, and defaults. |
| `example_query()` | Verified prompt-to-query or prompt-to-measure example. |
| `source_provenance()` | Owner, source system, freshness, certification, and trust tier. |

This could start as metadata with retrieval behavior, not as a full compiler.

Example:

```r
semantic_layer(
  semantic_model(
    name = "accounts",
    source = "curr_accts",
    grain = entity("account", key = "account_id"),
    dimensions = list(
      dimension(
        "tile_size",
        expr = "size",
        values = c("SMB-1", "SMB-2", "SMB-3", "Mid-Market-1", "Mid-Market-2",
                   "Mid-Market-3", "Enterprise-1", "Enterprise-2", "Enterprise-3")
      ),
      dimension("arr", expr = "arr", type = "number")
    ),
    segments = list(
      segment(
        "mid_market_3_to_enterprise_3",
        expr = "size IN ('Mid-Market-3', 'Enterprise-1', 'Enterprise-2', 'Enterprise-3')",
        synonyms = c("MM3 to E3", "Mid-Market-3 to Enterprise-3")
      )
    )
  ),
  measure(
    "active_account_count",
    "Count accounts, optionally filtered by tile size and ARR ceiling.",
    active_account_count,
    arguments = list(
      tile_size = ellmer::type_array(ellmer::type_string()),
      arr_under = ellmer::type_number()
    )
  )
)
```

In that example, `active_account_count` remains the highest-trust answer path. But if a
question needs fallback SQL, the agent no longer has to infer the meaning of "MM3 to E3"
from prose. It can resolve it as a semantic segment.

## What should stay in the context layer

The context layer should remain the place for free-text or lower-trust knowledge:

- Product launch context.
- Business-process explanations.
- Caveats that are not yet encoded structurally.
- Open questions and data availability notes.
- Historical corrections and issue notes.
- Narrative reference docs.
- Retrieval over unstructured sources like tickets, calls, Slack, or docs.

Context is still necessary. OpenAI's in-house data-agent writeup describes layers such
as table usage, human annotations, code enrichment, institutional knowledge, memory, and
runtime context. Anthropic's writeup similarly argues that analytics accuracy is mostly
a context and verification problem, not a code-generation problem. The distinction for
`commons` should be trust and structure: context informs the agent, while semantic-layer
objects constrain and route the agent.

## A staged implementation path

### Stage 1: rename the mental model without breaking APIs

Keep `measure()` and `search_measures` exactly as-is. Update docs to say:

- Measures are the current supported semantic-layer object.
- The semantic layer will grow to include metrics, dimensions, entities, joins, segments,
  and provenance.
- The context layer is for unstructured or lower-trust support material.

This alone resolves some terminology debt without forcing a package rewrite.

### Stage 2: add a semantic catalog alongside measures

Extend `commons_semantic_layer` from:

```r
private = list(
  measures = NULL,
  fn_sources = NULL
)
```

to something like:

```r
private = list(
  measures = NULL,
  fn_sources = NULL,
  models = NULL,
  dimensions = NULL,
  entities = NULL,
  relationships = NULL,
  segments = NULL,
  examples = NULL
)
```

Then add a read-only discovery tool:

```r
search_semantic_layer(query)
```

This tool should return measures first, then relevant structured semantic objects. It
can be implemented with the same lexical retrieval machinery initially.

### Stage 3: make provenance and trust explicit

Every semantic object should carry a source and trust tier:

```r
provenance(
  source = "dscoetools::get_tile_average_new_logo_deal_size",
  owner = "DSCOE",
  trust = "certified",
  refreshed = "live",
  notes = "Pass-through wrapper; no local rollup."
)
```

Useful trust tiers:

- `certified`: executable measure or engine-enforced metric/view.
- `curated`: human-authored semantic metadata or vetted example.
- `derived`: generated from code, dashboards, query logs, or schema inspection.
- `contextual`: prose retrieved from docs.
- `exploratory`: raw table inspection or newly authored SQL.

This also lets the UI explain whether an answer came from path A, path B, or something
lower-confidence.

### Stage 4: compile when possible, retrieve otherwise

Do not start by building a full MetricFlow/Cube/Databricks compiler. Instead:

- If a `measure()` covers the question, call it.
- If a semantic object maps directly to a safe SQL fragment or segment, use it to
  constrain fallback SQL.
- If an external semantic-layer adapter is configured, delegate compilation.
- If no semantic object covers the need, fall back to context retrieval and raw SQL.

Potential adapters:

```r
semantic_layer(
  databricks_metric_views(con),
  dbt_semantic_layer(path = "semantic_models/"),
  cube_semantic_layer(api_url = Sys.getenv("CUBE_API_URL")),
  measures = "R/measures.R"
)
```

`commons` would then be a client and orchestrator, not the authoritative semantic-layer
server.

### Stage 5: promote context into semantics

Critique Mode and online validation should be able to propose promotions:

- A repeated correction becomes a `segment()` or synonym.
- A verified SQL answer becomes an `example_query()`.
- A commonly used field and filter combination becomes a `metric()`.
- A table relationship used successfully across evals becomes a `relationship()`.

The promotion should be human-reviewed. The Anthropic writeup is clear that having an
LLM auto-generate metric definitions from raw tables and query logs produced plausible
but ambiguity-preserving definitions; the useful pattern is LLM-assisted drafting with
human ownership.

## Design principles for commons

1. A measure is a semantic-layer object, not the semantic layer.

2. Prefer structured semantics over prompt instructions. If a fact can be represented
   as a dimension, segment, relationship, metric, or example query, put it there before
   putting it in always-on prose.

3. Keep fallback SQL, but make it visibly lower-trust. The user should know when the
   agent left the governed path.

4. Be vendor-agnostic at the boundary. Let organizations bring Databricks metric views,
   dbt semantic models, LookML, Cube, Power BI, or hand-authored R measures.

5. Do not make `commons` know about any one use case. The tiles-agent example should
   inform the abstraction, but package examples and tests should stay generic.

6. Optimize for the agent's routing problem. The value is helping the agent map a user
   question to the right governed object, not merely documenting everything that exists.

## Immediate candidates from tiles-agent

These are generic patterns that could move from context-like material into semantic
objects:

| Current shape | Better semantic object |
|---|---|
| Tile-size list in `always` facts | `dimension(values = ...)` |
| "MM3 to E3" text rule | `segment(synonyms = ...)` |
| `measure-schemas.md` output/filter tables | Measure metadata and dimensions |
| Group 1 vs. Group 2 comments | `provenance(trust = ...)` |
| `dscoetools-datasources.md` source maps | Lineage/provenance metadata |
| Benchmark prompt examples | `example_query()` or eval seeds |
| "customer care is not a segment" | Negative synonym / ambiguity rule |

The package-level version should use examples like orders, accounts, revenue, customers,
and products, not tiles.

## Source notes

Local sources read:

- `README.Rmd`
- `R/measures.R`
- `R/context-layer.R`
- `R/tools.R`
- `R/prompt.R`
- `inst/prompts/system-prompt.md`
- `inst/tiles/commons-demo.R`
- `inst/tiles/commons-measures.R`
- `inst/references/context-semantic-graph-layers.md`
- `inst/resources/anthropic-self-service-data-analytics.md`
- `inst/resources/openai-in-house-data-agent.md`
- `posit-dev/commons#6`
- `posit-dev/tiles-agent`: `README.md`, `CLAUDE.md`, `R/agent.R`, `R/measures.R`,
  `context-inventory.md`, `measure-schemas.md`, `dscoetools-datasources.md`,
  `open-questions.md`, `questions.md`

External sources:

- Databricks: [Unity Catalog metric views](https://docs.databricks.com/aws/en/business-semantics/metric-views/),
  [model metric views](https://docs.databricks.com/aws/en/business-semantics/metric-views/basic-modeling),
  [metric view YAML reference](https://docs.databricks.com/aws/en/business-semantics/metric-views/yaml-reference),
  [Genie Spaces](https://docs.databricks.com/aws/en/genie/), and
  [Genie Space best practices](https://docs.databricks.com/aws/en/genie/best-practices)
- dbt: [semantic models](https://docs.getdbt.com/docs/build/semantic-models),
  [metrics](https://docs.getdbt.com/docs/build/build-metrics-intro), and
  [joins](https://docs.getdbt.com/docs/build/join-logic)
- Looker: [Introduction to LookML](https://docs.cloud.google.com/looker/docs/what-is-lookml)
- Microsoft: [Power BI semantic models](https://learn.microsoft.com/en-us/power-bi/connect-data/service-datasets-understand)
- Tableau: [Tableau Semantics concepts](https://developer.salesforce.com/docs/data/semantic-layer/guide/tableau-semantics-concepts.html)
- Cube: [What is a semantic layer?](https://cube.dev/articles/what-is-a-semantic-layer)
- AtScale: [Semantic layer glossary](https://www.atscale.com/glossary/semantic-layer/)
- Omni: [Semantic layer for AI and BI](https://omni.co/articles/best-semantic-layer-for-ai-and-bi-2026)
