# Evaluate a commons agent

## Contents

- [Purpose](#purpose)
- [Build the question set](#build-the-question-set)
- [Define targets and grading](#define-targets-and-grading)
- [Implement the evaluation](#implement-the-evaluation)
- [Pilot and inspect](#pilot-and-inspect)
- [Run and interpret](#run-and-interpret)

## Purpose

Use an evaluation to determine whether a commons agent answers the questions
its intended users will actually ask, follows the appropriate trusted or
untrusted path, handles ambiguity, and states when the available data cannot
answer a question.

Treat evaluation development as empirical work. Run the agent, inspect its
tool use and answers, and revise the questions and grading guidance based on
observed failure modes. Do not judge the evaluation only by its aggregate
score.

Use the
[devrel-agent evaluation](https://github.com/posit-dev/devrel-agent/tree/main/evals)
as the current worked example of a full commons evaluation. Adapt its
question, target, scorer, runner, baseline, and transcript-review patterns to
the agent being evaluated; do not copy its domain-specific rubric.

## Build the question set

Start with the representative questions collected during onboarding and any
real questions supplied by intended users. Draft a small set in Markdown and
review it with the user before implementing the evaluation. Ask whether the
questions are realistic, useful, and representative of the agent's intended
production traffic.

Expand the set iteratively, aiming for enough coverage to expose repeated
patterns rather than many paraphrases of the same question. Roughly 30
questions is a useful initial target for a scoped agent, but coverage matters
more than the exact count. Include:

* Easy questions with direct, verifiable answers.
* Questions that require custom analysis from available data.
* Nuanced or ambiguous questions where several interpretations may be
  reasonable or clarification may be necessary.
* Questions that are only partly answerable.
* Questions the agent should identify as unanswerable from its available data.

Write questions from the perspective of actual users. They usually do not know
which tables, columns, or trusted calculations the agent has, and their
questions may be shorter and more ambiguous than questions written by the
agent's developer. Do not make every question conveniently name the exact
measure or data source needed to answer it.

Keep some questions held out while developing the agent. Do not add
eval-specific hints, calculations, or answers to the data dictionary, semantic
layer, context layer, or instructions merely to make the evaluation pass.
Agent changes should represent generally useful knowledge or trusted
calculations that would be appropriate without knowing the evaluation.

## Define targets and grading

For each question, describe the expected answer and behavior, including:

* The calculation or source of truth.
* Required qualifications, units, time period, or scope.
* Valid alternative interpretations and the answer under each one.
* Whether the agent should ask for clarification.
* What a correct partial or unanswerable response looks like.
* When relevant, whether the answer should use a trusted calculation or be
  marked untrusted.

Keep the colloquial question and hand-authored grading guidance separate from
machine-derived target facts. Give each question a stable ID and classify it
before choosing a scorer. Useful initial categories are numeric or tabular,
nuanced but answerable, and not answerable.

Prefer executable code that computes the expected answer from the source data
over a hard-coded numeric target. Evaluate that code when constructing or
running the task and interpolate its result into the grading guidance passed
to the scorer. Compute targets against the same data snapshot the solver will
query. Make time-dependent targets reproducible by setting an explicit as-of
date or recording the source snapshot used for the run.

Keep target-generating code separate from the agent's measures. It may use the
same governed business definition, but it should independently calculate the
answer when practical so that the evaluation can catch implementation errors.
Verify the target code directly and preserve the source and reasoning behind
it. For stored target facts, provide an audit mode that recomputes them and
fails visibly when they drift from the selected snapshot.

Match scoring to the question category:

* For numeric and tabular answers, let a model identify the submitted values
  and interpretation when necessary, but use deterministic code for arithmetic
  such as percent error and aggregation across table cells.
* For nuanced answerable questions, use a small itemized rubric covering the
  calculation or evidence, filters and scope, interpretation and limitations,
  and fabrication.
* For unanswerable questions, grade whether the agent identifies the correct
  limitation, labels any proxy honestly, and does not fabricate an answer.

Require a separate reason for each rubric item and score each item on its own
criterion. One flaw should affect multiple items only when it independently
violates each criterion.

Give the grader all information it needs; do not assume it knows the data,
business definitions, or valid interpretations. For example, if "last month"
could reasonably mean either the most recent calendar month or the last 30
days, include the expected result for both interpretations and grade either
well-supported answer correctly.

If the score depends on tool use, the trusted/untrusted path, or another part
of the trajectory rather than only the final answer, implement a custom scorer
that inspects that evidence. Do not ask a final-answer-only grader to infer
behavior it cannot observe.

For provenance-sensitive grading, give the scorer the solver's relevant tool
calls and full results. Use the trajectory to verify what data was queried,
which filters were applied, and where reported values came from. Continue to
judge user-visible qualifications and limitations from the final answer
itself. Treat the grading facts as verified anchors, not a complete inventory
of the database: a value absent from those facts but supported by the
trajectory is not automatically fabricated.

Ask the user to review consequential business definitions, accepted
interpretations, and the expected behavior for partly answerable or
unanswerable questions before treating the targets as authoritative.

## Implement the evaluation

Use `vitals::Task` with:

* A dataset containing at least `input` and `target`.
* The commons agent as the solver through `vitals::generate()`.
* A deterministic, model-graded, or custom scorer appropriate to each
  criterion.
* More than one epoch when estimating run-to-run variation.

A basic task has this shape:

```r
dataset <- tibble::tibble(
  input = questions,
  target = generate_targets()
)

task <- vitals::Task$new(
  dataset = dataset,
  solver = vitals::generate(),
  scorer = vitals::model_graded_qa(),
  epochs = 2,
  name = "my-agent"
)

task$eval(solver_chat = agent, view = FALSE)
```

Use this only as a starting point. Adapt it rather than forcing every criterion
into `model_graded_qa()`. Ensure each sample starts with a fresh agent session
so conversation history, temporary handles, and tool state cannot leak between
questions.

Keep question data, target-generating code and stored facts, task construction,
custom scorers, metrics, and run scripts organized so another person can
reproduce and audit a run. Provide the agent and target code with the
credentials and data access they need, verify that access by running code, and
never write credentials into evaluation data or logs.

## Pilot and inspect

Before a full run:

1. Run each draft question through the commons agent at least twice.
2. Where useful, run the same question through a general coding agent with
   access to the relevant project and data.
3. Compare the answers and trajectories, enumerate plausible
   misinterpretations, and refine the target and grading guidance.
4. Check that the scorer receives enough evidence and grades representative
   correct, partially correct, and incorrect answers as intended.

For a direct comparison, constrain the general coding agent to the same data
snapshot and approved source boundary, and disable outside knowledge, web
access, or other tools that the commons agent cannot use. If the two solvers
have materially different access, treat the coding agent only as a diagnostic
baseline and label those differences rather than treating every advantage as a
commons failure.

Run a complete pilot against a strong model with Thinking enabled and save the
JSON log. Use `vitals::vitals_log_read()` to reconstruct the samples and their
solver and scorer chats. Inspect complete trajectories for every sample, not
only the final answers. Preserve and inspect item-level scorer output and
reasons as well. In particular, look for:

* Missing information in the scorer prompt.
* A scorer that is too strict or too permissive.
* Valid interpretations that the target omitted.
* Premature solver stopping.
* Incorrect table, time period, grain, join, or calculation choices.
* Failure to prefer a trusted calculation when one applies.
* Fabricated answers where the data is insufficient.

Write down the findings, correct the evaluation, and rerun affected samples
before relying on the full score.

## Run and interpret

Save timestamped JSON logs and record the agent version, model and thinking
configuration, data snapshot or as-of date, target-code version, scorer model,
and evaluation version for each run.

Report accuracy by question category. Also record latency, input and output
tokens, cached input tokens where available, and cost so improvements can be
evaluated against the agent's accuracy, speed, and expense goals.

Interpret results with three distinct sources of variation in mind:

* **Solver variation:** the same model may answer the same question
  differently across runs. Use multiple epochs.
* **Question variation:** performance on one finite question set may not
  generalize to other production questions. Preserve held-out questions and
  add real traffic over time.
* **Grader variation:** a model grader may score the same trajectory
  differently. Regrade or manually review borderline and high-impact samples.

With only a few epochs, describe run-to-run summaries as empirical sensitivity
estimates, not calibrated confidence intervals.

Report per-question failures and recurring themes alongside aggregate metrics.
Use failures to identify general improvements to the agent or evaluation, then
confirm those changes against held-out questions rather than tuning only to
the visible set.
