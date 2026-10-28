# Reproducing an analysis from trajectories

You may find yourself wanting to understand how a commons agent arrived
at a particular answer, double-check an answer, or reuse a calculation
from a commons app. Logged trajectories record the trusted calculations
an agent requested and the custom SQL and R code it submitted. A coding
agent can use those trajectories to put the relevant calculations into
an R script that you can review and run.

The commons skill includes a [reference for reproducing analyses from
trajectories](https://github.com/posit-dev/commons/blob/main/pkg-r/inst/skills/commons/references/reproducing-from-trajectories.md)
to help a coding agent assemble the script. See the
[introduction](https://posit-dev.github.io/commons/r/dev/articles/commons.html#working-with-the-agent-skill)
for how to install the skill.

## Prerequisites

There are few prerequisites to reproducing an analysis done by a commons
agent. You will need:

1.  [Trajectory
    logging](https://posit-dev.github.io/commons/r/dev/reference/agent.html#arg-log)
    enabled (needs to have been enabled when the analysis ran).
2.  Access to the commons layers used by the agent.
3.  Working connections to the data sources used in the analysis.
4.  If reading the trajectory from Connect: owner or collaborator access
    to the content and a configured `CONNECT_API_KEY`. See
    [`?trajectory_read`](https://posit-dev.github.io/commons/r/dev/reference/trajectory_read.md)
    for setup.

Also note that the commons layers, data, or packages may have changed
since the agent ran the analysis, and the data source rows and tables
available to the app user might be different than the data available to
you as the author, so re-running the code in this way may not reproduce
results exactly.

## Create the analysis script

With the commons skill installed, give your coding agent the trajectory
location, the conversation or answer you want to reproduce, and the
compatible commons object or its setup code. For example:

> Use the commons skill to reproduce the analysis behind \[the question
> or answer\] in conversation \[conversation ID\] from \[Connect content
> GUID or local trace path\]. The compatible commons object is named
> `commons`. Create and save an R script as `analysis.R` that I can run
> without the original app. Identify any missing inputs, and do not run
> the script yet.[^1]

The coding agent then reads the conversation, extracts the recorded
calculations and matching results, and writes the script. It selects the
calculations needed for the intended answer, leaves out abandoned
attempts, and connects their inputs and outputs. For example, if
recorded R code uses `r1`, it identifies the calculation that supplied
`r1` and adds the assignment. It preserves sources and parameter values,
calls trusted calculations and governed SQL through the commons object,
and orders the code by its dependencies. It does not ask the commons
agent to answer again.

You can inspect the [extraction code in the skill
reference](https://github.com/posit-dev/commons/blob/main/pkg-r/inst/skills/commons/references/reproducing-from-trajectories.md#extraction-code).
If trajectories or extracted calculations are already loaded in your R
session, tell the coding agent to reuse them rather than reading the
logs again.

## Run the analysis script

Run the file created by the agent in an R session with your `commons`
object available. You can ask the coding agent to run it and compare its
outputs with captured results. It should report what was reproduced and
any missing inputs or differences that prevent verification.

[^1]: If you don’t know the conversation ID, you can read in all the
    conversations from the trajectory location first, then identify the
    one you want to reproduce.
