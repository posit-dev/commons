# Onboarding

## Contents

- [When to use this reference](#when-to-use-this-reference)
- [Work with the user](#work-with-the-user)
- [Workflow](#workflow)

## When to use this reference

Use this reference to create a new commons agent from existing data,
documentation, and trusted code. Start with a small working agent, use it to
understand the pieces, and then expand it.

Use the [extraction reference](extracting-from-artifacts.md) after the project
scaffold exists and the user has confirmed the agent's scope and data-source
mapping. Use the
[trajectory reference](iterating-from-trajectories.md) to improve an agent from
logged conversations.

## Work with the user

Do routine investigation and implementation without interrupting the user.
Pause when a decision affects scope, trust, business meaning, data-source
selection, or the user's understanding of the data.

At each decision point:

1. Summarize the evidence, uncertainties, and conflicting information.
2. Explain the available options and make a recommendation.
3. Ask one specific question labeled `**Your decision:**`.
4. End the response and wait for the user.
5. Record the answer in the project's `onboarding.md`.

Maintain `onboarding.md` as a concise record of the agent's intended scope,
selected sources and artifacts, data flow, design decisions, confirmed
assumptions, and unresolved questions.

Surface uncertainties and contradictions throughout the workflow. Do not
silently resolve them.

## Workflow

1. **Orient to commons.**
   Read the relevant commons documentation and skill references before working
   on the agent. Perform the onboarding work with a model that has Thinking
   enabled.

2. **Scaffold the project.**
   Create the project layout in `SKILL.md`, including `DESCRIPTION`,
   `agent.R`, and `onboarding.md`. Add only boilerplate at this stage: create
   the directories and required fields, but do not invent domain content or
   calculations.

3. **Collect the source material.**
   Ask the user:
   * Where does the data live?
   * Where does its documentation live?
   * Where does trusted code that works with the data live?

   Ask for links or file paths to relevant data, documentation, and trusted
   code. Tell the user to be selective: exclude material they are unsure about
   trusting and material unrelated to the intended agent.

4. **Investigate the data environment.**
   Inspect the supplied data, documentation, schemas, source code, and data
   pipelines. Run scratch code to understand table grain, joins,
   transformations, update processes, and surprising behavior that may need to
   appear in a data dictionary.

   When the environment has several data layers or sources, create a legible
   data-flow diagram showing the relevant end-to-end flow and where the commons
   agent would operate. Ask the user to correct or confirm the resulting
   understanding.

5. **Choose the data boundary.**
   Identify which layer or layers the agent could access, such as warehouse
   tables, views, pins, or pipeline outputs. Present the tradeoffs and recommend
   the cleanest ready-to-analyze source that fits the user's environment.

   Prefer data whose creation and cleaning are controlled outside commons. A
   commons agent is not an ETL pipeline: measures should focus on analysis, not
   data cleaning or substantial transformation. For example, prefer a suitable
   maintained view over recreating that view's processing in a measure unless
   the user's ownership or control requirements point elsewhere.

   Pause for the user to confirm the selected boundary.

6. **Build the data dictionaries.**
   Create one data dictionary for each selected data source. Use existing data
   dictionaries, schemas, notes, verified exploration, and trusted code. Use
   joins demonstrated by trusted code to document relationships.

   Prefer the data dictionary over `context_layer()` for loose context. Do not
   add unsupported claims. Leave detailed guidance for governed definitions to
   a later pass.

7. **Extract from trusted artifacts.**
   Identify the trusted Shiny apps, Quarto documents, R scripts, and SQL files
   that are in scope. After the project exists and the user confirms the source
   mapping, follow the
   [extraction reference](extracting-from-artifacts.md) for each selected
   artifact. Put its proposed measures, dictionary edits, and context into the
   existing scaffold.

   Trusted calculations ideally come from maintained, tested R packages or
   well-structured repositories known to be correct and current. Do not create
   new calculation or data-processing logic during onboarding. Only carry
   trusted calculations from existing sources into measures, with mechanical
   adaptation to the commons interface where necessary. If no trusted code
   exists, leave the semantic layer empty or incomplete and tell the user that
   authoring and validating those calculations is a separate process.

8. **Review the assembled context.**
   Review continuously, then pause for a dedicated human-and-agent review.
   Check for conflicting information, duplication, unsupported claims, and
   facts that have not yet been verified. Revisit the semantic-layer design
   after the dictionaries and extracted artifacts are visible.

9. **Complete the minimal agent.**
   Fill in `DESCRIPTION` and `agent.R`. Ask the user which model provider the
   agent should use, and recommend a model with Thinking enabled. Connect the
   selected data sources, dictionaries, semantic layer, and remaining context.

   Verify that the agent starts and can answer a few representative questions.
   Expand its sources and trusted calculations only after this small agent
   works and the user understands its pieces.
