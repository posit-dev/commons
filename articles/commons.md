# Getting started with commons

Not much to see here yet. We’ll be back!

This vignette shows the shape of a small commons project.

``` r

library(commons)
```

## Setting up the project directory

A commons agent is easiest to maintain when the pieces live in separate
files:

``` text
.
|-- app.R
|-- agent.R
|-- DESCRIPTION
|-- AGENTS.md                 # or the active coding agent's equivalent (e.g., CLAUDE.md)
|-- instructions.md
|-- dictionaries/
|   `-- warehouse.yaml
|-- measures/
|   `-- sales-dashboard.R
`-- context/
    `-- sales-dashboard.md
```

## Installing the agent skill

The package includes a `commons` [agent skill](https://agentskills.io/)
that helps coding agents build, evaluate, and improve commons agents.
Installing the R package makes the skill files available, but does not
automatically add them to an assistant’s skill discovery directory.

Locate the bundled skill with:

``` r

skill <- system.file("skills", "commons", package = "commons")
skill
```

### Codex and Posit Assistant

Both [Codex](https://learn.chatgpt.com/docs/build-skills) and [Posit
Assistant](https://assistant.posit.co/docs/reference/config-file#skills)
discover project skills in `.agents/skills`:

``` r

dir.create(".agents/skills", recursive = TRUE, showWarnings = FALSE)
file.copy(skill, ".agents/skills", recursive = TRUE)
```

This creates `.agents/skills/commons/SKILL.md`. Commit that directory
when the skill should be available to everyone working in the project.

For a user-wide installation, copy the directory to `~/.agents/skills`.
Posit Assistant also searches `~/.posit/assistant/skills` and
`.posit/assistant/skills` by default. Its `skills.paths` configuration
controls the complete search path; a project-level value replaces,
rather than extends, the global value.

### Claude Code

[Claude Code](https://code.claude.com/docs/en/skills) uses
`.claude/skills` for project skills:

``` r

dir.create(".claude/skills", recursive = TRUE, showWarnings = FALSE)
file.copy(skill, ".claude/skills", recursive = TRUE)
```

This creates `.claude/skills/commons/SKILL.md`. Use
`~/.claude/skills/commons` instead for a personal installation available
across local projects.
