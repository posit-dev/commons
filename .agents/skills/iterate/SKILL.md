---
name: iterate
description: Improve and maintain a commons data agent by reading logged trajectories, finding recurring low-trust or slow answers, and proposing semantic-layer or context-layer changes.
---

# Iterate on a commons agent

Use this skill when asked to improve an existing `commons` agent from logged trajectories, user feedback, or repeated low-trust answers.

The task is to move recurring questions to the highest appropriate path, increasing trustworthiness and decreasing latency.

```text
Path A: semantic layer
The answer comes from a governed `measure()`. Prefer this for stable, recurring business metrics.

Path B, documented
The answer uses SQL, but the context layer identifies the right table, grain, filters, joins, caveats, or SQL shape. If there are recurring cases in this bucket, consider proposing changes to the semantic layer that would promote those cases into Path A.

Path B, exploratory
The answer uses SQL with little documentation and the agent had to inspect tables, write custom SQL, or make assumptions. Promote recurring cases out of this state.
```

## Workflow

1. Find the agent definition.
   Search for `commons(`, `semantic_layer(`, `measure(`, and `context_layer(`. Identify where the semantic layer and context layer are constructed. If they are wrapped in project helpers, follow those helpers.

2. Load trajectories.
   Use `commons::read_trajectories(...)`. If the path or pins board is unclear, inspect the project for `log =`, `COMMONS_LOG_DIR`, or deployment setup.

3. Read the conversations.
   Each trajectory is a list of ellmer turns.

```r
trajectories <- commons::read_trajectories(log_dir)
turns <- trajectories[[1]]

print(turns)
```

4. Analyze themes.
   Group conversations by the business concept being asked about, not by exact wording. Note which themes already hit Path A, which are documented Path B, and which are exploratory Path B.

5. Propose changes.
   Present the highest-value changes first. For each proposal, note the theme and current typical path, how many questions are described by that theme, and the recommended change. 

Prefer semantic-layer edits when the question is a stable governed metric. Prefer context-layer edits when the issue is table choice, grain, filters, joins, caveats, terminology, or reusable SQL shape.

6. Wait before editing.
   Do not make semantic-layer or context-layer edits until the user chooses which proposed changes to apply. The data scientist should confirm any new business definition, canonical table, exclusion rule, or SQL pattern.
