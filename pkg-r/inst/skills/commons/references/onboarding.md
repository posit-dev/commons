# Onboarding

## Contents

- [When to use this reference](#when-to-use-this-reference)
- [Purpose](#purpose)
- [Work with the user](#work-with-the-user)
- [Workflow](#workflow)

## When to use this reference

Use this reference to create a new commons agent from existing data, documentation, and trusted code. Unless the user has a clear plan for what they want to do, start with a small working scope, use it to understand the pieces, and then expand it.

Use the [extraction reference](extracting-from-artifacts.md) after the project scaffold exists and the user has confirmed the agent's scope and data source mapping. Use the [trajectory reference](iterating-from-trajectories.md) to improve an agent from logged conversations.

## Purpose

Onboarding should:

- Give the coding agent the commons knowledge needed to do the work.
- Develop an evidence-based understanding of the user's data, code, and existing artifacts.
- Give the user the mental models needed to make informed design decisions.
- Produce a functional commons agent from that shared understanding.

Consider both what you need to implement the agent and what the user needs to understand and decide. Do not optimize for implementation alone.

## Work with the user

Do routine investigation and implementation without interrupting the user. Pause when a decision affects scope, trust, business meaning, data source selection, or the user's understanding of the data.

Explain a principle in plain language when it materially affects a user decision, especially the solid-but-not-perfect foundation and the fine-grained-versus-prepared data tradeoff. Do not present the full principles list as required reading. Do not begin onboarding with a general explanation of commons or its principles; introduce only the context needed for the current question.

Trusted code may be distributed across multiple repositories. When the user identifies those repositories as relevant sources, inspect them in place and consider the evidence from all of them. Recommend excluding a repository only when there is a concrete concern about its relevance, trustworthiness, or fit with the confirmed scope; explain that concern and let the user decide.

At each decision point:

1. Summarize the evidence, uncertainties, and conflicting information.
2. Explain the available options and make a recommendation.
3. End with one clearly scoped prompt labeled `**Your decision:**`.
4. End the response and wait for the user.

Maintain concise project guidance in the project instruction file recognized by the coding agent doing the work. For example, use `AGENTS.md` for Codex or Posit Assistant and `CLAUDE.md` for Claude Code; use the corresponding convention for other coding agents. Reuse and preserve an applicable existing file, and do not create or maintain multiple agent-specific files solely for onboarding. If the coding agent has no project instruction file convention, do not create one just for this workflow. Record only durable information a future coding agent needs to work on the project safely: the agent's intended scope, data boundaries and source mapping, trusted artifacts, consequential business constraints, and unresolved issues that affect implementation. Do not use the file as a transcript, decision log, status report, or record of routine and completed choices.

Reconcile new evidence with earlier assumptions and decisions as it appears. Surface contradictions, unsupported claims, and unresolved uncertainty when discovered; do not defer them to the final review or silently resolve them.

## Workflow

1. **Orient to commons.** Before scaffolding, identify the installed commons version and locate the corresponding package source when available. Read the relevant commons documentation and skill references, then inspect the implementation, examples, and tests for the APIs the agent will use. At minimum, examine:
   - `commons()`, `data_source()`, `semantic_layer()`, and `context_layer()`;
   - `commons_theme()` and `commons_server()`, including per-session construction;
   - measure loading and data-dictionary behavior; and
   - dependency and deployment expectations for a commons app.

2. **Scaffold the project.** Create the project layout in `SKILL.md`, including `DESCRIPTION`, `app.R`, `agent.R`, and the relevant agent instruction file. Add only boilerplate at this stage: create the directories and required fields, but do not invent domain content or calculations. If the applicable instruction file already exists, preserve its instructions and add commons-specific guidance only as it becomes known.

3. **Discovery: Collect the source material.** Collect source material incrementally. Do not present the full discovery checklist in one message. Ask one focused question, inspect what the user provides, and use the resulting evidence to determine the next question. Do not ask the user for information that can be discovered from supplied files, repositories, or connections.

   Begin with the strongest available scope anchor. Ask:

   > What existing app, report, or question set best represents what you want this agent to support? If there isn't one, share 2-3 representative questions it should answer.

   After the user provides the scope anchor, and before asking for additional source material, give this compact overview:

   | Part | Contains | Usually comes from |
   | --- | --- | --- |
   | Data sources | Queryable tables | Warehouses, databases, pins, and prepared files |
   | Data dictionaries | Table grain, columns, relationships, meanings, and governed definitions | Schemas, existing dictionaries, trusted code, and verified exploration |
   | Semantic layer | Trusted callable calculations | Existing apps, reports, R, and SQL |
   | Context layer | Relevant knowledge not represented elsewhere | Documentation, methodology, and glossaries |

   Tell the user that you will identify material for these parts incrementally and that they do not need to organize it themselves.

   Retain representative questions for scoping and later testing. After inspecting the scope-defining artifact or questions, collect only the missing information, one topic at a time:
   1. Clarify who should use the agent and what they should be able to ask.
   2. Locate the underlying data and establish how it can be accessed.
   3. Locate documentation for the selected data.
   4. Locate trusted code that works with the selected data.

   Ask for a link or file path when the relevant material is not already available. When requesting each source, tell the user to include only material they trust and that is relevant to the intended agent. Do not front-load this guidance before it affects a source-selection decision.

   If supplied materials include domains or artifacts whose relevance to the intended scope is unclear, surface that uncertainty. When a smaller first scope would materially reduce implementation risk or help the user validate the design sooner, explain that benefit and recommend what to defer. Treat this as a decision point, not a prerequisite: if the user chooses to implement the full scope now, accept that decision and proceed without repeatedly pushing to narrow it. Do not treat distribution across multiple repositories as a reason by itself to reduce scope.

4. **Investigate the data and artifacts.** Inspect the supplied data, documentation, schemas, source code, and data pipelines. Run scratch code to understand table grain, joins, transformations, update processes, and surprising behavior that may need to appear in a data dictionary.

   When the environment has several data layers or sources, create a legible data-flow HTML diagram showing the relevant end-to-end flow and where the commons agent would operate. Ask the user to correct or confirm the resulting understanding.

5. **Confirm trust, scope, and the data boundary.** Identify which layer or layers the agent could access, such as warehouse tables, views, pins, or pipeline outputs. Present the tradeoffs and recommend the cleanest ready-to-analyze source that fits the user's environment.

   Prefer data whose preparation and quality controls are managed outside commons. A commons agent is not a data preparation pipeline: measures should implement analysis, not routine cleaning or substantial reshaping. For example, prefer a maintained table or view that already applies the required preparation over reimplementing that preparation inside a measure, unless ownership or control requirements point elsewhere.

   Map each selected artifact's data inputs to the proposed data sources. Before building, make sure it is clear which data sources will form the agent's data layer, which selected artifacts and files contain computations the user considers trusted, and how those artifacts map to the selected sources.

   Do not ask the user to design the detailed division among the dictionary, semantic layer, and remaining context. Steps 6 through 8 determine that placement from the available evidence.

   If discovery supports one coherent approach, summarize the intended users and questions, selected sources and trusted artifacts, data flow, and source mapping; recommend the initial scope; and ask the user to confirm it. If a foundational choice remains unclear or has consequential alternatives, work through one choice at a time: summarize the evidence, uncertainties, options, and recommendation, then ask one `**Your decision:**` question and wait. Add the confirmed high-level scope, data boundary, source mapping, and trusted artifacts to the agent instruction file; omit example questions and the history of how the decisions were reached.

6. **Build the data dictionaries.** Create one `data-dict.yaml` for each selected data source. Follow the [data dictionary reference](data-dictionaries.md) for commons-specific behavior and the upstream data-dict documentation for the general format. Use existing dictionaries, schemas, notes, verified exploration, and trusted code. Use joins demonstrated by trusted code to document relationships. Before extraction, review each draft dictionary against the evidence again. Look specifically for surprising facts that are not yet represented and claims that are not supported by verified sources; correct them or surface the uncertainty. Preserve existing governed definitions, but defer adding or redesigning them until step 7, when trusted artifacts can establish their meaning and computation.

7. **Extract from selected trusted artifacts.** For each artifact selected during discovery and mapped to a confirmed data source, follow the [extraction reference](extracting-from-artifacts.md). Use it to draft and reconcile measures, governed definitions, dictionary edits, and free-text context. Apply only the proposals the user confirms. Add an unresolved gap to the agent instruction file only when it constrains future implementation.

   If the selected artifacts do not contain trusted computation for a needed calculation, leave that part of the semantic layer incomplete. Record the gap rather than authoring new calculation or data-processing logic.

8. **Add remaining context.** Review approved source material gathered during discovery that was not already incorporated during extraction. Add residual knowledge needed for the intended questions that does not belong in the dictionaries or semantic layer to `context/*.md`. Preserve provenance and avoid duplicating information stored elsewhere.

   Construct the `context_layer()` to confirm that every configured context file exists and can be read. Identify representative searches that should retrieve its most important guidance, and verify them after connecting the context layer to the agent in step 10.

9. **Revisit the assembled design.** Review the dictionaries, measures, governed definitions, and free-text context together against the confirmed scope, intended questions, source mapping, and data flow. Check for contradictions, duplication, unsupported claims, missing provenance, and information stored in the wrong layer. Reconsider the dictionary, semantic layer, and context layer design now that the extracted artifacts are visible. Treat consequential changes as decision points, and update the agent instruction file only when they change its durable guidance.

10. **Complete the agent.** Fill in `DESCRIPTION`, `agent.R`, and `app.R`. Ensure each Shiny session receives a fresh agent, as required by `commons_server()`. Construct it directly inside the server function or call reusable construction code from `agent.R`; do not pass one global agent object to every session. Ask the user which model provider the agent should use, and recommend a model with Thinking enabled.

   commons owns the base system prompt; a system prompt set on the client is ignored. Decide whether the agent needs additional `instructions`. Use them only for concise, durable guidance that every conversation must have before using tools, such as the meaning of an agent-specific name or acronym or an organization-wide convention. Do not restate the commons agent's role or add generic domain framing such as "You answer pharmaceutical questions." Keep data knowledge, calculations, and longer reference material in their appropriate layers. Because instructions consume tokens in every session, omit them when nothing genuinely needs to be ambient. If instructions are needed, place them in a short `instructions.md` file and ask the user to confirm them.

   Connect the selected data sources, dictionaries, semantic layer, remaining context, and any additional instructions.

   In `agent.R`, you might set `options(commons.context_cache)` to a folder in the project directory before constructing the agent. Then, in the file that deploys the agent, call `agent$prewarm()` before deployment so the deployed app starts with a built context index and populated pins cache.

   Verify that the agent starts, that representative context searches retrieve the intended guidance, and that it can answer a few representative questions.

   Give the user a working way to try out the agent. Ask them to verify that representative answers, business meanings, source choices, and stated limitations match their expectations. Treat their acceptance and any issues they identify as a decision point. Add only unresolved implementation constraints to the agent instruction file; do not record the review itself. Follow the scope the user confirmed, whether incremental or comprehensive. Once the user chooses a comprehensive first version, do not defer confirmed material merely to produce a smaller agent.
