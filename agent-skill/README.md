# The coding-agent skill's shared references

Both packages ship a skill for coding agents that build and maintain commons agents: `pkg-r/inst/skills/commons/` and `pkg-py/src/commons/skills/commons/`. Most of each skill is written for its own language. A reference that reads the same in both has its single source here, and `scripts/sync-shared.sh` copies it into both skills. CI fails when a copy is stale. Edit the file here and re-run the script, never a copy.

This is a different kind of skill from those in `prompts/skills/`. Those are loaded by the data agent at runtime; this one is copied by users into their coding agent's skills directory.
