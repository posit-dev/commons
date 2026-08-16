# Onboarding

## Contents

- [When to use this reference](#when-to-use-this-reference)
- [Purpose](#purpose)
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

## Purpose

Onboarding should:

* Give the coding agent the commons knowledge needed to do the work.
* Develop an evidence-based understanding of the user's data, code, and
  existing artifacts.
* Give the user the mental models needed to make informed design decisions.
* Produce a functional commons agent from that shared understanding.

Consider both what you need to implement the agent and what the user needs to
understand and decide. Do not optimize for implementation alone.

## Work with the user

Do routine investigation and implementation without interrupting the user.
Pause when a decision affects scope, trust, business meaning, data-source
selection, or the user's understanding of the data.

At each decision point:

1. Summarize the evidence, uncertainties, and conflicting information.
2. Explain the available options and make a recommendation.
3. End with one clearly scoped prompt labeled `**Your decision:**`.
4. End the response and wait for the user.
5. Record the answer in the project's `onboarding.md`.

Maintain `onboarding.md` as a concise record of the agent's intended scope,
selected sources and artifacts, data flow, design decisions, confirmed
assumptions, and unresolved questions.

Reconcile new evidence with earlier assumptions and decisions as it appears.
Surface contradictions, unsupported claims, and unresolved uncertainty when
discovered; do not defer them to the final review or silently resolve them.

## Workflow

1. **Orient to commons.**
   Read the relevant commons documentation and skill references before working
   on the agent.

2. **Scaffold the project.**
   Create the project layout in `SKILL.md`, including `DESCRIPTION`,
   `agent.R`, and `onboarding.md`. Add only boilerplate at this stage: create
   the directories and required fields, but do not invent domain content or
   calculations.

3. **Discovery: Collect the source material.**
   Ask the user:
   * Who should use the agent, and what should they be able to ask?
   * What representative questions should the completed agent answer?
   * Where does the data live?
   * Where does its documentation live?
   * Where does trusted code that works with the data live?

   Collect example questions early and retain them for scoping and later
   testing. If an existing Shiny app, report, or question set defines all or
   most of the intended scope, ask the user to identify it explicitly.

   Ask for links or file paths to relevant data, documentation, trusted code,
   and scope-defining artifacts. Tell the user to be selective: exclude
   material they are unsure about trusting and material unrelated to the
   intended agent.

   If the supplied materials are extensive, span several domains, or lack clear
   organization, recommend a narrower initial scope that can produce a useful
   working agent. Treat the scope as a decision point; do not exclude materials
   without the user's confirmation.

4. **Investigate the data environment.**
   Inspect the supplied data, documentation, schemas, source code, and data
   pipelines. Run scratch code to understand table grain, joins,
   transformations, update processes, and surprising behavior that may need to
   appear in a data dictionary.

   When the environment has several data layers or sources, create a legible
   data-flow HTML diagram showing the relevant end-to-end flow and where the commons
   agent would operate. Ask the user to correct or confirm the resulting
   understanding.

5. **Confirm the initial scope and data boundary.**
   Identify which layer or layers the agent could access, such as warehouse
   tables, views, pins, or pipeline outputs. Present the tradeoffs and recommend
   the cleanest ready-to-analyze source that fits the user's environment.

   Prefer data whose preparation and quality controls are managed outside
   commons. A commons agent is not a data preparation pipeline: measures should
   implement analysis, not routine cleaning or substantial reshaping. For
   example, prefer a maintained table or view that already applies the required
   preparation over reimplementing that preparation inside a measure, unless
   ownership or control requirements point elsewhere.

   Map each selected artifact's data inputs to the proposed data sources.
   Summarize the intended users and questions, selected sources and artifacts,
   data flow, and source mapping. Recommend a coherent initial scope, then
   pause for the user to confirm it. Record the confirmed scope, example
   questions, selections, and mapping in `onboarding.md`.

6. **Build the data dictionaries.**
   Create one `data-dict.yaml` for each selected data source. Follow the
   [data dictionary reference](data-dictionaries.md) for commons-specific
   behavior and the upstream data-dict documentation for the general format.
   Use existing dictionaries, schemas, notes, verified exploration, and trusted
   code. Use joins demonstrated by trusted code to document relationships.
   Preserve existing governed definitions, but defer adding or redesigning them
   until step 7, when trusted artifacts can establish their meaning and
   computation.

7. **Extract from selected trusted artifacts.**
   For each artifact selected during discovery and mapped to a confirmed data
   source, follow the [extraction reference](extracting-from-artifacts.md). Use
   it to draft and reconcile measures, governed definitions, dictionary edits,
   and free-text context. Apply only the proposals the user confirms, then
   record the resulting semantic-layer decisions and unresolved gaps in
   `onboarding.md`.

   If the selected artifacts do not contain trusted computation for a needed
   calculation, leave that part of the semantic layer incomplete. Record the
   gap rather than authoring new calculation or data-processing logic.

8. **Add remaining context.**
   Review approved source material gathered during discovery that was not
   already incorporated during extraction. Add residual knowledge needed for
   the intended questions that does not belong in the dictionaries or semantic
   layer to `context/*.md`. Preserve provenance and avoid duplicating
   information stored elsewhere.

   Construct the `context_layer()` to confirm that every configured context
   file exists and can be read. Identify representative searches that should
   retrieve its most important guidance, and verify them after connecting the
   context layer to the agent in step 10.

9. **Revisit the assembled design.**
   Review the dictionaries, measures, governed definitions, and free-text
   context together against the confirmed scope, intended questions, source
   mapping, and data flow. Check for contradictions, duplication, unsupported
   claims, missing provenance, and information stored in the wrong layer.
   Reconsider the dictionary, semantic-layer, and context-layer design now that
   the extracted artifacts are visible. Treat consequential changes as
   decision points and record their resolution in `onboarding.md`.

10. **Complete the minimal agent.**
   Fill in `DESCRIPTION` and `agent.R`. Ask the user which model provider the
   agent should use, and recommend a model with Thinking enabled. Connect the
   selected data sources, dictionaries, semantic layer, and remaining context.

   Verify that the agent starts, that representative context searches retrieve
   the intended guidance, and that it can answer a few representative
   questions.

   Give the user a working way to try out the agent. Ask them to verify that
   representative answers, business meanings, source choices, and stated
   limitations match their expectations. Treat their acceptance and any issues
   they identify as a decision point, and record the outcome in `onboarding.md`.
   Expand sources and trusted calculations only after this small agent works
   and the user confirms that they understand and accept its current behavior.
