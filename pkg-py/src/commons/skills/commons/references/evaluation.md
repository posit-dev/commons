# Evaluate a commons agent

## Contents

- [Purpose](#purpose)
- [Work with the user](#work-with-the-user)
- [Build the question set](#build-the-question-set)
- [Define targets and grading](#define-targets-and-grading)
- [Implement the evaluation](#implement-the-evaluation)
- [Pilot and inspect](#pilot-and-inspect)
- [Run and interpret](#run-and-interpret)

## Purpose

Use an evaluation to determine whether a commons agent answers the questions its intended users will actually ask, follows the appropriate trusted or untrusted path, handles ambiguity, and states when the available data cannot answer a question.

Treat evaluation development as empirical work. Run the agent, inspect its tool use and answers, and revise the questions and grading guidance based on observed failure modes. Do not judge the evaluation only by its aggregate score.

Use the [devrel-agent evaluation](https://github.com/posit-dev/devrel-agent/tree/main/evals) as the current worked example of a full commons evaluation. Adapt its question, target, scorer, runner, baseline, and transcript-review patterns to the agent being evaluated; do not copy its domain-specific rubric.

## Work with the user

Evaluation requires the user's judgment about realistic questions, business meaning, acceptable interpretations, and useful answers. Do routine implementation without interrupting them, but pause for their review before treating the question set, grading guidance, pilot, or full-run results as authoritative.

Before launching any model-backed pilot, full run, or rerun, estimate its cost from the number of samples (questions × epochs), expected model calls and token usage per sample, and the models used by the solver and model-based scorer. Account for agent solvers that may make multiple model calls for one sample. When pilot or prior-run results exist, scale the observed costs: the solver's from the cost each sample recorded (see [Implement the evaluation](#implement-the-evaluation)), and the scorer's from the model usage in the Inspect log; otherwise state the provider pricing and usage assumptions. Present the estimate and its assumptions, ask whether the user wants to proceed, and do not launch the run until they explicitly approve it.

Make each review concrete. Give the user direct links to the question and target files, summarize the choices that need attention, and tell them where the Inspect logs are stored (`./logs` unless `log_dir` says otherwise). Open them in the Inspect log viewer with:

```bash
inspect view --log-dir logs
```

In the viewer, ask the user to select a sample and inspect the question, grading target, complete solver messages and tool calls, final answer, score, and grader messages and explanation. When custom scorer details are not visible enough in the viewer, reconstruct the sample with `inspect_ai.log.read_eval_log(log_path)` or render the relevant JSON fields into a readable Markdown transcript.

Ask the user to flag unrealistic questions, missing valid interpretations, incorrect business meaning, unavailable evidence, solver behavior they would not accept, and grades they disagree with. Resolve those issues and rerun the affected samples before proceeding.

## Build the question set

Start with a handful of representative questions collected during onboarding or supplied by intended users. Choose questions that cover as many important categories, ambiguities, and data gotchas as practical, then review them with the user before implementing the evaluation. Ask whether they are realistic, useful, and representative of the agent's intended production traffic.

Expand the set of questions iteratively. Take the initial questions through target definition, implementation, pilot runs, trajectory and grader inspection, user review, and correction before adding more. Once that full cycle works, add questions in small batches and repeat the cycle for the new coverage. Aim for around 30 questions eventually, not in the initial draft. Across the growing set, include:

- Easy questions with direct, verifiable answers.
- Questions that require custom analysis from available data.
- Nuanced or ambiguous questions where several interpretations may be reasonable or clarification may be necessary.
- Questions that are only partly answerable.
- Questions the agent should identify as unanswerable from its available data.

Write questions from the perspective of actual users. They usually do not know which tables, columns, or trusted calculations the agent has, and their questions may be shorter and more ambiguous than questions written by the agent's developer. Do not make every question conveniently name the exact measure or data source needed to answer it.

Keep some questions held out while developing the agent. Do not add eval-specific hints, calculations, or answers to the data dictionary, semantic layer, context layer, or instructions merely to make the evaluation pass. Agent changes should represent generally useful knowledge or trusted calculations that would be appropriate without knowing the evaluation.

## Define targets and grading

For each question, describe the expected answer and behavior, including:

- The calculation or source of truth.
- Required qualifications, units, time period, or scope.
- Valid alternative interpretations and the answer under each one.
- Whether the agent should ask for clarification.
- What a correct partial or unanswerable response looks like.
- When relevant, whether the answer should use a trusted calculation or be marked untrusted.

Keep the colloquial question and hand-authored grading guidance separate from machine-derived target facts. Give each question a stable ID and classify it before choosing a scorer. Useful initial categories are numeric or tabular, nuanced but answerable, and not answerable.

Prefer executable code that computes the expected answer from the source data over a hard-coded numeric target. Evaluate that code when constructing or running the task and interpolate its result into the grading guidance passed to the scorer. Compute targets against the same data snapshot the solver will query. Make time-dependent targets reproducible by setting an explicit as-of date or recording the source snapshot used for the run.

Keep target-generating code separate from the agent's measures. It may use the same governed business definition, but it should independently calculate the answer when practical so that the evaluation can catch implementation errors. Verify the target code directly and preserve the source and reasoning behind it. For stored target facts, provide an audit mode that recomputes them and fails visibly when they drift from the selected snapshot.

Match scoring to the question category:

- For numeric and tabular answers, let a model identify the submitted values and interpretation when necessary, but use deterministic code for arithmetic such as percent error and aggregation across table cells.
- For nuanced answerable questions, use a small itemized rubric covering the calculation or evidence, filters and scope, interpretation and limitations, and fabrication.
- For unanswerable questions, grade whether the agent identifies the correct limitation, labels any proxy honestly, and does not fabricate an answer.

Require a separate reason for each rubric item and score each item on its own criterion. One flaw should affect multiple items only when it independently violates each criterion.

Give the grader all information it needs; do not assume it knows the data, business definitions, or valid interpretations. For example, if "last month" could reasonably mean either the most recent calendar month or the last 30 days, include the expected result for both interpretations and grade either well-supported answer correctly.

If the score depends on tool use, the trusted/untrusted path, or another part of the trajectory rather than only the final answer, implement a custom scorer that inspects that evidence. Do not ask a final-answer-only grader to infer behavior it cannot observe.

For provenance-sensitive grading, give the scorer the solver's relevant tool calls and full results. Use the trajectory to verify what data was queried, which filters were applied, and where reported values came from. Continue to judge user-visible qualifications and limitations from the final answer itself. Treat the grading facts as verified anchors, not a complete inventory of the database: a value absent from those facts but supported by the trajectory is not automatically fabricated.

Ask the user to review the complete question set and grading guidance, especially consequential business definitions, accepted interpretations, and the expected behavior for partly answerable or unanswerable questions.

## Implement the evaluation

Use an [Inspect](https://inspect.aisi.org.uk/) `Task` with:

- A dataset of `Sample`s with at least `input` and `target`.
- The commons agent as the solver, through a custom solver.
- A deterministic, model-graded, or custom scorer appropriate to each criterion.
- More than one epoch when estimating run-to-run variation.

A commons agent has no `to_solver()`, so wrap it in a solver of your own. The agent makes its own model calls through chatlas, so Inspect does not see its tool calls or token usage; the solver records them instead. A basic task has this shape:

```python
import sys
import tempfile
from pathlib import Path

from chatlas import ContentToolResult
from inspect_ai import Task, task
from inspect_ai.dataset import Sample
from inspect_ai.log import transcript
from inspect_ai.model import ModelOutput
from inspect_ai.scorer import model_graded_qa
from inspect_ai.solver import Generate, TaskState, solver

# Inspect runs this file from evals/, so make the project root importable.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from agent import build_agent  # noqa: E402


@solver
def commons_agent():
    async def solve(state: TaskState, generate: Generate) -> TaskState:
        agent = build_agent()
        response = await agent.stream_async(state.input_text)
        answer = "".join([chunk async for chunk in response])
        state.output = ModelOutput.from_content(model="commons", content=answer)
        state.store.set("cost", agent.get_cost())
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "trajectory.md"
            agent.export(path, content="all", include_system_prompt=False)
            trajectory = path.read_text()
        state.store.set("trajectory", trajectory)
        state.store.set("displays", displayed_html(agent))
        transcript().info(trajectory, source="commons agent")
        return state

    return solve


def displayed_html(agent) -> list[str]:
    # What the chat showed for each tool result, as shinychat reads it.
    shown = []
    for turn in agent.get_turns():
        for content in turn.contents:
            if not isinstance(content, ContentToolResult):
                continue
            display = (content.extra or {}).get("display")
            html = display.get("html") if isinstance(display, dict) else getattr(display, "html", None)
            if html is not None:
                shown.append(str(html))
    return shown


@task
def my_agent():
    samples = [Sample(input=q, target=t) for q, t in zip(questions, generate_targets())]
    return Task(
        dataset=samples,
        solver=commons_agent(),
        scorer=model_graded_qa(),
        epochs=2,
    )
```

Run it with `inspect eval evals/task.py --model <grader model>`. The agent calls the model its chatlas client names, so `--model` selects only the model `model_graded_qa()` grades with. Inspect loads the task file with `evals/` as the working directory, so build every path in `agent.py` and the target code from `Path(__file__).parent` rather than the working directory, and pass a path to `instructions` as a `str`. Use this only as a starting point. Adapt it rather than forcing every criterion into `model_graded_qa()`. Build a fresh agent for each sample, as above, so conversation history, temporary handles, and tool state cannot leak between questions. `get_cost()` raises when chatlas does not know the model's price; pass `token_price` or record `agent.get_tokens()` instead. The answer text includes the provenance marker and citation markup the agent appends; tell a model grader to disregard that markup, or strip it before grading. When a measure displays a table or plot, the agent is told not to repeat it in its reply, so a grader that sees only the answer text can mark a correct answer wrong. The exported trajectory does not show what the user saw either: it has each tool's value as the model received it, which can differ from the display, have fewer rows, or lack a plot image. The solver therefore also keeps the HTML the chat displayed for each tool result. Give the scorer the displayed tables, labeled as displayed results rather than intermediate tool output. A plot in that HTML is an image a text grader cannot read, so mark questions that depend on reading a plot for human review, and have the reviewer open that sample's saved HTML. A scorer that checks tool use reads the same trajectory.

Keep question data, target-generating code and stored facts, task construction, custom scorers, metrics, and run scripts organized so another person can reproduce and audit a run. Provide the agent and target code with the credentials and data access they need, verify that access by running code, and never write credentials into evaluation data or logs.

## Pilot and inspect

Before a full run:

1. Agree with the user on a small representative pilot set that includes the major question categories and known ambiguities or data gotchas.
2. Estimate the pilot's cost using the method above and obtain the user's explicit approval to launch it.
3. Use the Inspect task to run each pilot question through the commons agent at least twice.
4. Where useful, run the same questions through a controlled general coding-agent solver in the evaluation harness.
5. Compare the answers and trajectories, enumerate plausible misinterpretations, and refine the target and grading guidance.
6. Check that the scorer receives enough evidence and grades representative correct, partially correct, and incorrect answers as intended.

Use the pilot set, not the complete evaluation, when iterating on the agent and scorer. Keep the remaining questions as held-out questions for the full run, and do not use their expected answers or grading facts as reasons to change the agent. When a pilot failure motivates an agent change, make that change only when approved sources support it and it would be useful beyond the evaluation.

For a direct comparison, constrain the general coding agent to the same data snapshot and approved source boundary, and disable outside knowledge, web access, or other tools that the commons agent cannot use. If the two solvers have materially different access, treat the coding agent only as a diagnostic baseline and label those differences rather than treating every advantage as a commons failure.

Run the pilot against a strong model with Thinking enabled. Inspect writes the log automatically. Use the trajectories the solver recorded and `read_eval_log()` to reconstruct the samples and their solver and scorer chats. Inspect complete trajectories for every sample, not only the final answers. Preserve and inspect item-level scorer output and reasons as well. In particular, look for:

- Missing information in the scorer prompt.
- A scorer that is too strict or too permissive.
- Valid interpretations that the target omitted.
- Premature solver stopping.
- Incorrect table, time period, grain, join, or calculation choices.
- Failure to prefer a trusted calculation when one applies.
- Fabricated answers where the data is insufficient.

When independent coding agents are available, have multiple agents review the pilot solver and grader transcripts. Give them the raw question, grading target, complete transcripts, and only the context needed to understand those artifacts. Do not give them suspected defects or prior conclusions. Ask them to identify missing scorer evidence, inappropriate grading, omitted valid interpretations, premature solver stopping, and other evaluation problems.

Consolidate the findings in `evals/review.md`, identifying the affected sample, evidence, proposed correction, and whether it was addressed. This report supplements rather than replaces direct log review.

Give the user access to the pilot log and ask them to inspect every pilot sample in the viewer and review `evals/review.md`. Add the user's findings, correct the evaluation, and rerun affected samples. Run the full question set only after the user agrees that the pilot questions, targets, and grades are working as intended.

## Run and interpret

Before the full run, estimate its cost using the method above and the final question count and epochs. Present the resulting estimate and obtain the user's explicit approval to launch it.

Report accuracy by question category. Also record latency, input and output tokens, cached input tokens where available, and cost so improvements can be evaluated against the agent's accuracy, speed, and expense goals.

Interpret results with three distinct sources of variation in mind:

- **Solver variation:** the same model may answer the same question differently across runs. Use multiple epochs.
- **Question variation:** performance on one finite question set may not generalize to other production questions. Preserve held-out questions.
- **Grader variation:** a model grader may score the same trajectory differently. Regrade the same stored trajectory when estimating this variation, and manually review borderline and high-impact samples.

With only a few epochs, describe run-to-run summaries as empirical sensitivity estimates, not calibrated confidence intervals.

Report per-question failures and recurring themes alongside aggregate metrics. Use failures to identify general improvements to the agent or evaluation, then confirm those changes against held-out questions rather than tuning only to the visible set.

Open the full run's logs in the Inspect log viewer with `inspect view`.

Give the user access to the viewer and ask them to review the results and trajectories, including every failure and borderline grade and a representative set of successful samples. Record disagreements with the grader and unresolved questions alongside the evaluation findings; do not present the aggregate score as trustworthy until this review is complete.
