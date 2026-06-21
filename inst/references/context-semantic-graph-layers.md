# Context, Semantic, and Knowledge-Graph Layers for AI Data Agents: A Map

*Prepared for the design of `commons`, a vendor-agnostic, self-service data-agent toolkit.*

## TL;DR

The **semantic layer** (governed, declarative metric definitions → deterministic SQL)
and the **context layer** (broader, searchable knowledge the agent reads before
authoring SQL) are real and distinct. But in 2026 the major vendors are collapsing
"context layer," "knowledge graph," and "ontology" into a *single learned-graph product*
that sits **above** the semantic layer and is largely **mined automatically** rather than
hand-curated. The live debate is no longer "semantic layer vs. context layer" — it's
**human-curated trust vs. agent-learned coverage**, and every vendor has staked a
position. AWS sits at one pole ("learns from agents, no re-curation"); dbt/Cube sit at the
other (pure human-authored spec). Snowflake, Databricks, and Microsoft are deliberately
hybrid.

The most important correction to the naive mental model: **"ontology" and "knowledge
graph" are now used by Databricks and AWS to mean the context layer itself**, not a
separate entity-relationship resolution aid. They are the same artifact viewed
structurally.

---

## (a) Glossary: distinguishing the terms

| Term | What it actually is | What lives in it | Author | How an agent consumes it |
|---|---|---|---|---|
| **Semantic layer** (a.k.a. **metrics layer**, **headless BI**) | Governed, declarative definitions of metrics + dimensions + joins + grain that compile deterministically to SQL. | `revenue`, `churn`, `active_users` as reusable objects; join paths; time grains; allowed filters. | **Human** (analysts/engineers), declared in YAML/code. | Emits a **structured spec**, calls a **compiler** that generates and runs SQL. The calculation body is fixed. |
| **Semantic model** | A *single packaged instance* of a semantic layer scoped to a domain/dataset (e.g. a Cortex Analyst YAML, a Power BI model, a Genie Space's verified logic). | The metrics + tables + synonyms + sample questions for one subject area. | Human, sometimes AI-drafted. | Same as semantic layer; it's the unit you point an agent at. |
| **Context layer** | A broader, searchable knowledge body the agent reads to *ground its own reasoning* before/while authoring queries. | Table/column descriptions, business glossary, lineage, docs, runbooks, query patterns, past corrections, "institutional knowledge." | Mix: human docs **+** mined from query logs/code/dashboards **+** agent feedback. | **Retrieval** — vector/keyword search, MCP tool calls, file reads — then the model authors SQL. Lower-trust, free-form. |
| **Knowledge graph** | The *structural representation* of a context layer: entities + relationships as nodes/edges. | Accounts, metrics, tables, owners, docs, join paths — and the edges between them. | Increasingly **mined/inferred automatically**; humans review/promote. | **Graph traversal** + agentic search APIs to resolve references and navigate lineage. |
| **Ontology** | The *schema/vocabulary* of the knowledge graph — what entity types and relationship types are allowed; the shared business vocabulary. | "A Customer has Orders"; "Revenue is derived from Line Items"; canonical definitions of business terms. | Historically curated; now **vendors use "ontology" to name the whole learned context layer** (Databricks, Microsoft). | Through the graph; often the thing that disambiguates a NL term to a governed object. |

**Subset/overlap relationships:**

- **Metrics layer ⊆ Semantic layer ⊆ Context layer.** Metrics are the narrowest,
  most-governed core. The semantic layer adds dimensions/joins/grain. The context layer is
  the broad superset that *includes* the semantic layer plus everything free-form around it.
- **Knowledge graph is the *shape* of the context layer; ontology is the *vocabulary* of
  that graph.** They're two views of one artifact, not three separate things.
- **"Semantic model" means two different things** even within one vendor. In Snowflake, a
  *Semantic View* is a SQL object stored in the database (engine-enforced), while a
  *Semantic Model* is an external YAML file on a stage that feeds Cortex Analyst. Same
  word, different governance guarantees.
  ([Select Star guide](https://www.selectstar.com/resources/snowflake-cortex-analyst))

**The biggest terminology drift:** the intuitive model places "knowledge graph" as a
*resolution/lineage aid* sitting beside the other two. In the current vendor framing, the
knowledge graph **is** the context layer — Databricks calls theirs the "Genie Ontology... a
living graph," AWS calls theirs a self-learning "knowledge graph." So the three-box model is
really **two boxes**: (1) the governed semantic/metrics layer, and (2) the context layer,
whose internal structure happens to be a knowledge graph described by an ontology.

---

## (b) How the named vendors instantiate these

| Vendor / product | Their name for it | What it contains | Built by | Agent retrieves via | Curated ↔ Learned |
|---|---|---|---|---|---|
| **dbt Semantic Layer (MetricFlow)** | "Semantic layer" / semantic graph | Entities, dimensions, measures, metrics in YAML; join/grain logic. Open-sourced Apache 2.0 Oct 2025. | **100% human**, in dbt project code. | Spec → MetricFlow **compiles SQL**, warehouse serves it. | **Pure curated.** Highest trust, highest maintenance. |
| **Cube** | "Semantic layer" + "agentic layer" | Same as dbt (can read dbt models) **plus** caching, pre-aggregations, multi-tenant security, multi-API serving. | Human (reads dbt). | API/spec → Cube **serves** (Cube owns the serving layer, not just definitions). | **Curated**, optimized for embedded + AI workflows. |
| **AtScale** | "Semantic layer" (OLAP) | Enterprise OLAP cubes for Excel/Power BI. | Human. | Compiler → SQL/MDX. | **Curated**, enterprise OLAP niche. |
| **Snowflake Horizon Context** (in Horizon Catalog) | "Governed context layer" | Four signal types: **structural** (relationships, lineage), **operational** (queries, freshness), **semantic** (definitions, metrics via Semantic Views), **behavioral** (usage, popularity). Pulls external metadata (Tableau, Power BI, Airflow). | **Hybrid.** Semantic Studio (AI-assisted IDE, Git-versioned) for manual; **Semantic View Autopilot** auto-generates views from SQL/Tableau/Power BI. | **Cortex Analyst** + external agents via **MCP** (Claude, Cursor). CoCo auto-discovers the right semantic view. | **Hybrid, engine-enforced.** Security/logic enforced at engine level — "cannot be circumvented" by querying tables directly. |
| **Databricks Genie** (Genie One / Agents / **Ontology**) | "Genie Ontology — an automatic context layer / living graph" | Metric definitions, business terms, calculations, relationships between concepts/metrics/tables/teams; mined from tables, queries, dashboards, pipelines, connected apps. Sits above **Unity Catalog Metrics** (governed KPI objects). | **Largely automated.** "Genie solves the context problem, without asking your teams to hand-curate it." Trust via **PageRank-like weighting** (source authority, usage frequency, ties to certified assets, freshness). | Unified chat agent **synthesizes certified Genie Spaces, governed dashboards, Apps** — "reusing the logic already embedded there," not text-to-SQL. **Genie Code** now leans on UC metric views over local ones. | **Learned, but anchored to curated cores.** Explicitly "**not another error-prone text-to-SQL interface**." Reported 84.5% vs. 52.4% for a general coding agent. |
| **Microsoft Fabric IQ** (over OneLake) | "Fabric IQ" + **ontology** for semantic grounding | Data agents query across OneLake: Lakehouses, Warehouses, **Power BI semantic models**, KQL DBs, and **ontologies**. Up to 5 sources/agent; 15k-char instruction pane. | Hybrid: Power BI semantic models (curated) + ontology grounding. | Azure OpenAI Assistant APIs turn NL into **read-only** queries; integrates M365 Copilot. | **Hybrid**, leans on existing curated Power BI models. |
| **AWS Context** (Glue / SageMaker Unified Studio / Lake Formation) | "Self-learning knowledge graph" / "context intelligence" | Datasets, dashboards, metadata, inferred relationships, **Glue "skill assets"** (runbooks, query patterns, usage rules attached at catalog layer). | **Most learned.** "Observes which sources produce correct results, which join paths agents rely on, and which curated rules get applied." One agent's discovery propagates to others "**without requiring a human re-curate the graph**." Stewards *review/promote* inferred edges. | **Agentic search APIs + MCP tools** (Bedrock AgentCore, EKS). **Identity-aware**: inherits caller's IAM + Lake Formation permissions per call. | **Most learned pole.** Swami Sivasubramanian: *"Your agents now get smarter without you having to rebuild anything from scratch."* |
| **Anthropic / OpenAI framing** | "Context engineering" (RAG 2.0 / agentic retrieval) | Not a product — a *discipline*: "filling the context window with just the right information at each step of an agent's trajectory." MCP treats retrieval as a tool. | N/A (technique). | Iterative retrieval + tool calls; contextual retrieval (+35% retrieval accuracy per Anthropic). | Framing layer that sits over *any* of the above. |

---

## (c) The curated-vs-learned tension, mapped

This is the field's actual fault line. Plotting the vendors:

```
PURE CURATED                                              PURE LEARNED
(high trust, high maintenance)              (low maintenance, lower trust)

dbt SL ── Cube ── AtScale ──┬── Snowflake Horizon ── MS Fabric IQ ──┬── Databricks Genie ──── AWS Context
                            │         (hybrid, engine-enforced)     │   Ontology (learned,
 human-authored spec,       │                                        │   anchored to certified
 deterministic compile      │   curated core + auto-generated/       │   cores via PageRank)
                            │   mined surround                       │
                                                                          agent-trained graph,
                                                                          steward-reviewed
```

**Stated tradeoffs, by pole:**

- **Curated (dbt/Cube/AtScale):** correctness is *guaranteed* because a human owns the
  calculation body; the model only parameterizes. The cost is maintenance — every metric,
  join, and grain must be authored and kept current, and coverage is limited to what's been
  modeled. The "vetted functions with safe arguments" analogy is exactly right here.
- **Learned (AWS):** near-zero upfront integration; the graph "improves itself over time"
  and discoveries propagate across agents. AWS's explicit pitch is that "building a context
  layer between enterprise data stores and AI agents is bespoke work, with no standard
  service to automate or maintain the graphs." The cost is **trust**: inferred join paths
  and relationships are probabilistic, which is why stewards still *review and promote*
  before production.
- **Hybrid (Snowflake/Databricks/Microsoft):** the dominant real-world pattern. Keep a
  **small governed core** (Semantic Views / Unity Catalog Metrics / Power BI models) that is
  human-trusted, and **auto-generate or mine the surround** (descriptions, lineage, usage,
  glossary). Databricks' PageRank-style weighting is the clearest articulation: the system
  *learns broadly* but *ranks by curated-ness* — definitions tied to "certified and
  widely-used assets" outrank scraped ones. This is how they get coverage without
  surrendering trust.

The key insight: **trust is not binary, it's a gradient that vendors are learning to
*rank*.** The interesting design question isn't "curated or learned" but "how do you let an
agent reach for the lower-trust context only when the high-trust layer doesn't cover the
question, and signal that downgrade?"

A second tension worth flagging: **governance is not free in the learned world.** "RAG is
not necessarily safer." A learned context layer can leak relationships or definitions a user
isn't authorized to see — which is precisely why AWS makes its graph *identity-aware* (every
call inherits IAM/Lake Formation perms) and Snowflake enforces logic *at the engine level*
so it "cannot be circumvented."

---

## (d) Direct relevance to `commons`

`commons` wants to be vendor-agnostic and connect to whichever layer an org already has. The
landscape above suggests several concrete design positions:

**1. Model the two-layer reality, not the three-box one.** Internally, treat the world as
**(A) a governed semantic/metrics layer** (deterministic, trusted, spec-in/SQL-out) and
**(B) a context layer** (free-form, retrieved, model authors SQL). "Knowledge graph" and
"ontology" are *how a context layer is structured*, not a third peer. This keeps the agent's
decision crisp: *can I answer from a governed spec, or must I drop to authored SQL grounded
in context?*

**2. The "trust gradient" is the core abstraction.** Mirror what Databricks/Snowflake
learned: tag every piece of context with a trust/provenance level (certified metric >
engine-enforced semantic view > human doc > mined-from-query-log > agent-inferred). Let the
agent **prefer the highest-trust source that covers the question** and *fall through*
explicitly. This is the deepest module `commons` could own that's genuinely vendor-neutral —
vendors expose the sources; few expose a clean cross-source trust-ranking policy.

**3. Connect via the emerging lingua franca: MCP.** Snowflake (Horizon → Cortex via MCP),
AWS (agentic search + MCP tools), and Microsoft (Copilot/agent surfaces) are all converging
on **MCP as the agent-to-layer interface**. A vendor-agnostic `commons` should treat "the
org's semantic/context layer" as a **pluggable backend** with adapters: a
dbt/Cube/Snowflake/Databricks semantic-layer adapter that returns *specs and compiles SQL
deterministically*, and a context adapter that does retrieval (MCP, vector search, or file
reads). This matches the strength of the R-package position: not building the layer, but
being the **client that knows how to interrogate whichever one exists.**

**4. Don't over-index on "build the knowledge graph."** AWS's whole thesis is that
hand-building this graph is bespoke, unmaintainable work — and they've productized away from
it. `commons` should *not* try to be the graph. It should be the thing that (a) reads an
org's existing governed definitions, (b) retrieves their existing context, and (c) authors
SQL only when (a) and (b) fall short — with the fallback clearly marked as lower-trust to the
user.

**5. The differentiator vendors agree on: never lead with raw text-to-SQL.** Databricks:
"not another error-prone text-to-SQL interface." Snowflake/Microsoft route through semantic
models first. The validated pattern for `commons`: **try the governed spec path first;
author SQL only as the grounded fallback.** Making the *ordering* a first-class, enforced
part of the agent loop — not a prompt suggestion — is the consensus design.

**6. The context layer is becoming *less* free-form.** The naive context-layer definition
("lower-trust, free-form, model reads it then authors SQL") matches every vendor — *but* the
leading vendors are rapidly making the context layer **less free-form** by giving it graph
structure and authority-weighting. A future-proof `commons` context adapter should accept
*structured* context (entities/edges/provenance) where available, degrading gracefully to
plain doc retrieval where it isn't.

---

## Sources

- [AWS enters the context layer race with a graph that learns from agents, not manual curation — VentureBeat](https://venturebeat.com/data/aws-enters-the-context-layer-race-with-a-graph-that-learns-from-agents-not-manual-curation) (via [mirror](https://www.dataworldbank.net/2026/06/18/aws-enters-the-context-layer-race-with-a-graph-that-learns-from-agents-not-manual-curation/))
- [Context intelligence for your data and AI agents at scale — AWS ML Blog](https://aws.amazon.com/blogs/machine-learning/context-intelligence-for-your-data-and-ai-agents-at-scale/)
- [Next-generation Databricks Genie — Databricks Blog](https://www.databricks.com/blog/next-generation-databricks-genie)
- [Introducing Genie One, Genie Ontology, and Genie Agents — Databricks Blog](https://www.databricks.com/blog/introducing-genie-one-genie-ontology-and-genie-agents)
- [What's new in Genie Code at Data + AI Summit 2026 — Databricks Blog](https://www.databricks.com/blog/whats-new-genie-code-data-ai-summit-2026)
- [Horizon Context | Governed Semantic Layer & Data Catalog — Snowflake](https://www.snowflake.com/en/product/features/horizon-context/)
- [Guide to Snowflake Cortex Analyst and Semantic Models — Select Star](https://www.selectstar.com/resources/snowflake-cortex-analyst)
- [What is Fabric IQ? — Microsoft Learn](https://learn.microsoft.com/en-us/fabric/iq/overview) and [Fabric data agent creation](https://learn.microsoft.com/en-us/fabric/data-science/concept-data-agent)
- [dbt Semantic Layer Alternatives (2026) — Cube](https://cube.dev/articles/dbt-semantic-layer-alternatives-2026)
- [Semantic Layer Architectures: Warehouse vs dbt vs Cube — Typedef](https://www.typedef.ai/resources/semantic-layer-architectures-explained-warehouse-native-vs-dbt-vs-cube)
- [Is RAG Dead? The Rise of Context Engineering and Semantic Layers for Agentic AI — Towards Data Science](https://towardsdatascience.com/beyond-rag/)

*Note: the VentureBeat and The New Stack original pages returned 403/truncated to direct
fetch; AWS-specific claims and quotes are corroborated across the AWS ML Blog, the
VentureBeat mirror, and search excerpts.*
