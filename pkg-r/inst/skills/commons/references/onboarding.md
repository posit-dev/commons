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
- Help the user decide what the agent should cover and which sources and calculations to trust.
- Produce a functional commons agent from that shared understanding.

## Work with the user

Work from what the user provides. Do routine investigation and implementation without interrupting them, and ask only for what you cannot discover from supplied files, repositories, or connections. When you need several things, ask for them together.

Wait for user approval only on the agent's scope and data access; which artifacts, calculations, and sources to trust; and any new business definition, canonical table, exclusion rule, or dictionary caveat. Also confirm the contents of `instructions` and the model provider, since the provider determines where the user's data is sent. Summarize the evidence and options, recommend an approach, and ask a specific question. Group decisions that are ready at the same time.

For reversible choices, such as file layout or where content goes among the dictionaries, semantic layer, and context layer, proceed with a sensible default, say what you assumed, and let the user correct it.

Explain a principle in plain language when it materially affects a user decision, especially the solid-but-not-perfect foundation and the fine-grained-versus-prepared data tradeoff, which shape the data boundary in step 5. Do not begin onboarding with a general explanation of commons or its principles.

Trusted code may be distributed across multiple repositories. Inspect the repositories the user identifies in place and consider the evidence from all of them. Recommend excluding one only for a concrete concern about its relevance, trustworthiness, or fit with the confirmed scope, and let the user decide.

Maintain concise project guidance in the project instruction file recognized by the coding agent doing the work. For example, use `AGENTS.md` for Codex or Posit Assistant and `CLAUDE.md` for Claude Code; use the corresponding convention for other coding agents. Reuse and preserve an applicable existing file, and do not create or maintain multiple agent-specific files solely for onboarding. If the coding agent has no project instruction file convention, do not create one just for this workflow. Record only durable information a future coding agent needs to work on the project safely: the agent's intended scope, data boundaries and source mapping, trusted artifacts, consequential business constraints, and unresolved issues that affect implementation. Do not use the file as a transcript, decision log, status report, or record of routine and completed choices.

Reconcile new evidence with earlier assumptions and decisions as it appears. Surface contradictions, unsupported claims, and unresolved uncertainty when discovered; do not defer them to the final review or silently resolve them.

## Workflow

1. **Orient to commons.** Before scaffolding, identify the installed commons version and locate the corresponding package source when available. Read the relevant commons documentation and skill references, then inspect the implementation, examples, and tests for the APIs the agent will use. At minimum, examine:
   - `agent()`, `commons()`, `data_source()`, `semantic_layer()`, and `context_layer()`;
   - `commons_theme()` and `commons_server()`, including per-session construction;
   - measure loading and data-dictionary behavior; and
   - dependency and deployment expectations for a commons app.

2. **Scaffold the project.** Create the project layout in `SKILL.md`, including `DESCRIPTION`, `app.R`, `agent.R`, `deploy.R`, and the relevant agent instruction file. Add only boilerplate at this stage: create the directories and required fields, but do not invent domain content or calculations. If the applicable instruction file already exists, preserve its instructions and add commons-specific guidance only as it becomes known.

3. **Discovery: Collect the source material.** Start with an existing app, report, or set of questions that best represents what the agent should support. If the user has not given one, ask for it, or for 2-3 representative questions. Keep representative questions for scoping and later testing.

   After reviewing it, collect only the missing information:
   1. Clarify who should use the agent and what they should be able to ask.
   2. Locate the underlying data and establish how it can be accessed.
   3. Locate documentation for the selected data.
   4. Locate trusted code that works with the selected data.

   Ask for a link or file path when the relevant material is not already available. When asking for sources, tell the user to include only material they trust and that is relevant to the agent.

   If the user is new to commons, a short overview helps them know what material is useful. They do not need to organize their material into these parts:

   | Part | Contains | Usually comes from |
   | --- | --- | --- |
   | Data sources | Queryable tables | Warehouses, databases, pins, and prepared files |
   | Data dictionaries | Table grain, columns, relationships, meanings, and governed definitions | Schemas, existing dictionaries, trusted code, and verified exploration |
   | Semantic layer | Trusted callable calculations | Existing apps, reports, R, and SQL |
   | Context layer | Relevant knowledge not represented elsewhere | Documentation, methodology, and glossaries |

   If some supplied domains or artifacts seem outside the intended scope, say so. When a smaller first scope would reduce implementation risk or let the user validate the design sooner, recommend what to defer; if the user wants the full scope now, proceed without pushing again. Distribution across multiple repositories is not by itself a reason to reduce scope.

   Encourage fewer agents rather than more. When the user already has a commons agent, consider extending it to a new domain before creating a separate one. Most measures, table details, and context are retrieved only when needed. Supporting more domains therefore adds little to the prompt sent with every conversation, provided dataset-level dictionary text and instructions stay concise. A separate agent makes sense when there is a concrete reason, such as a different audience or different data permissions that are not addressed by table/row-level security (e.g. with `odbc::databricks()` or `odbc::snowflake()`.).

4. **Investigate the data and artifacts.** Inspect the supplied data, documentation, schemas, source code, and data pipelines. Run scratch code to understand table grain, joins, transformations, update processes, and surprising behavior that may need to appear in a data dictionary.

   When the environment has several data layers or sources, create a legible data-flow HTML diagram showing the relevant end-to-end flow and where the commons agent would operate, and include it in the step 5 summary.

   When two sources, tables, or trusted artifacts could answer the same question, such as a curated mart and the raw tables beneath it, compute the answer each way and compare. If the answers differ, investigate why and summarize the discrepancy in step 5. Ask the user which source or definition the agent should use. If the discrepancy comes from an error, recommend fixing it upstream rather than working around it in commons. If both sources stay, record which one should answer which questions in their dictionary entries.

5. **Confirm trust, scope, and the data boundary.** Identify which layer or layers the agent could access, such as warehouse tables, views, pins, or pipeline outputs. Present the tradeoffs and recommend the cleanest ready-to-analyze source that fits the user's environment.

   Prefer data whose preparation and quality controls are managed outside commons. A commons agent is not a data preparation pipeline: measures should implement analysis, not routine cleaning or substantial reshaping. For example, prefer a maintained table or view that already applies the required preparation over reimplementing that preparation inside a measure, unless ownership or control requirements point elsewhere. If no such table exists, recommend preparing one elsewhere, such as by materializing views over the raw data, and making that the data source, but do so inside of the commons if the user recommends doing so.

   Map each selected artifact's data inputs to the proposed data sources. Before building, make sure it is clear which data sources will form the agent's data layer, which selected artifacts and files contain computations the user considers trusted, and how those artifacts map to the selected sources.

   Do not ask the user to design the detailed division among the dictionary, semantic layer, and remaining context. Steps 6 through 8 determine that placement from the available evidence.

   Before building, present one design summary: the intended users and questions, selected sources and trusted artifacts, the data flow and source mapping, any conflicts found in step 4, and the recommended initial scope. Include any unresolved decisions, with a recommendation for each. This is the main checkpoint before building; wait for the user to confirm or correct it. If one open choice determines others, such as which source is canonical, settle it on its own first. Then add the confirmed high-level scope, data boundary, source mapping, and trusted artifacts to the agent instruction file; omit example questions and the history of how the decisions were reached.

6. **Build the data dictionaries.** Create one `data-dict.yaml` for each selected data source. Follow the [data dictionary reference](data-dictionaries.md) for commons-specific behavior and the upstream data-dict documentation for the general format. Use existing dictionaries, schemas, notes, verified exploration, and trusted code. Use joins demonstrated by trusted code to document relationships. Before extraction, review each draft dictionary against the evidence again. Look specifically for surprising facts that are not yet represented and claims that are not supported by verified sources; correct them or surface the uncertainty. Preserve existing governed definitions, but defer adding or redesigning them until step 7, when trusted artifacts can establish their meaning and computation.

7. **Extract from selected trusted artifacts.** For each artifact selected during discovery and mapped to a confirmed data source, follow the [extraction reference](extracting-from-artifacts.md). Use it to draft and reconcile measures, governed definitions, dictionary edits, and free-text context. Group related small proposals for review, for example those from one artifact, and apply only what the user approves. Add an unresolved gap to the agent instruction file only when it constrains future implementation.

   If the selected artifacts do not contain trusted computation for a needed calculation, leave that part of the semantic layer incomplete. Record the gap rather than authoring new calculation or data-processing logic.

8. **Add remaining context.** Review approved source material gathered during discovery that was not already incorporated during extraction. Add residual knowledge needed for the intended questions that does not belong in the dictionaries or semantic layer to `context/*.md`. Preserve provenance and avoid duplicating information stored elsewhere.

   Construct the `context_layer()` to confirm that every configured context file exists and can be read. Identify representative searches that should retrieve its most important guidance, and verify them after connecting the context layer to the agent in step 10.

9. **Revisit the assembled design.** Review the dictionaries, measures, governed definitions, and free-text context together against the confirmed scope, intended questions, source mapping, and data flow. Check for contradictions, duplication, unsupported claims, missing provenance, and information stored in the wrong layer. Reconsider the dictionary, semantic layer, and context layer design now that the extracted artifacts are visible. Fix routine problems directly and raise only changes that affect trust or business meaning. Update the agent instruction file only when a change affects its durable guidance.

10. **Complete the agent.** Fill in `DESCRIPTION`, `agent.R`, and `app.R`. Ensure each Shiny session receives a fresh agent, as required by `commons_server()`. Construct it directly inside the server function or call reusable construction code from `agent.R`; do not pass one global agent object to every session. Ask the user which model provider the agent should use, since that decides where their data is sent; if one is already configured, recommend it. Enable thinking in the ellmer chat passed to `agent()`. If the agent should answer only from trusted calculations and never write its own SQL or R, pass `mode = "trusted only"`.

   A commons chat app **must** list `tidyverse` in `DESCRIPTION` under `Imports`: the agent writes R code at runtime, so rsconnect can't detect the packages that code uses. List any other packages the app calls directly rather than relying on transitive dependencies or `requireNamespace()` calls in `deploy.R` to make rsconnect discover them.

   Use or adapt this basic structure for `app.R`, adapting the title and agent construction as needed. In this example `build_agent()` (from `agent.R`) constructs and returns the complete commons agent.

   ```r
   source("agent.R", local = TRUE)

   ui <- shinychat::page_chat(
     "commons agent",
     id = "chat",
     theme = commons::commons_theme()
   )

   server <- function(input, output, session) {
     agent <- build_agent() # from agent.R
     commons::commons_server("chat", agent)
   }

   shiny::shinyApp(ui, server)
   ```

   Keep `build_agent()` inside `server()` so that each session gets its own agent.

   If you make suggested questions to go in the greeting, each question should be a real, complete question that the agent can actually answer. Choose questions that represent the confirmed scope and exercise the agent's most important data, calculations, and context.

   commons owns the base system prompt; a system prompt set on the client is ignored. Decide whether the agent needs additional `instructions`. Use them only for concise, durable guidance that every conversation must have before using tools, such as the meaning of an agent-specific name or acronym or an organization-wide convention. Do not restate the commons agent's role or add generic domain framing such as "You answer pharmaceutical questions." Keep data knowledge, calculations, and longer reference material in their appropriate layers. Because instructions consume tokens in every session, omit them when nothing genuinely needs to be ambient. If instructions are needed, place them in a short `instructions.md` file and ask the user to confirm them.

   Connect the selected data sources, dictionaries, semantic layer, remaining context, and any additional instructions.

   To ship a pre-built context index, set its project-relative location in `agent.R` before constructing the agent. Because both local deployment code and the deployed app source this file, they resolve the same cache path:

   ```r
   options(commons.context_cache = "commons-cache")
   ```

   In `deploy.R`, source the agent construction code, construct a temporary deployment-only agent, and prewarm it before enumerating the files to deploy:

   ```r
   source("agent.R", local = TRUE)
   agent <- build_agent()
   agent$prewarm()

   app_files <- c(
     "app.R",
     "agent.R",
     list.files("commons-cache", recursive = TRUE, full.names = TRUE)
   )

   rsconnect::deployApp(
     appDir = ".",
     appFiles = app_files,
     appPrimaryDoc = "app.R",
     envVars = "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"
   )
   ```

   Adapt `build_agent()` and the rest of `app_files` to the project. The cache must be built before `app_files` is collected, and explicit file lists must include `commons-cache/`. Git-ignore the generated directory, but do not use `app_cache/`: rsconnect excludes that directory from bundles. Keep this deployment-only agent separate from the fresh agent constructed for each Shiny session.

   When the agent uses `agent(log = TRUE)`, keep
   `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true` in the local
   deployment environment and include its name in `deployApp(envVars = ...)`,
   as above. This passes the value to the deployed content; setting it locally
   without including it in `envVars` does not.

   `agent$prewarm()` finishes building the context index before it returns. It also starts pin downloads in a background process; do not claim that pins are bundled unless the board cache is project-local and those downloads are known to have finished before deployment.

   Verify that the agent starts, that representative context searches retrieve the intended guidance, and that it can answer a few representative questions. Check that it reaches for each extracted measure, as described at the end of extraction step 9.

   Give the user a working way to try out the agent. Ask them to check that representative answers, business meanings, source choices, and stated limitations match their expectations, and address what they find. Add only unresolved implementation constraints to the agent instruction file; do not record the review itself. Follow the scope the user confirmed, whether incremental or comprehensive. Once the user chooses a comprehensive first version, do not defer confirmed material merely to produce a smaller agent.
