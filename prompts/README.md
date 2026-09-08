# commons' system prompt

`system-prompt.md` is the readable source of the default agent behavior. Its
construction balances a few goals:

- The prompt should be human-readable as-is; prose that could land in the 
  system prompt should live in the prompt itself. Keep prompt prose in Markdown. 
  Each package supplies runtime facts and content, not headings or
  behavioral instructions.
- Keep the workflow general across agent compositions. Instructions specific
  to an optional tool belong in that tool's description. Notably, `search_pool`,
  `call_measure`, and `call_metrics` are described as relating to
  'trusted calculations' so that the workflow section doesn't need to name
  specific tools. The citation section is the exception: which outputs are
  citable depends on which tools exist, so it names them behind conditionals.
- Keep ambient context useful but bounded. Detailed table and definition
  context arrives through tools when needed.

This directory is the single source for both packages. `scripts/sync-shared.sh`
copies it into `pkg-r/inst/prompts/` and `pkg-py/src/commons/prompts/`, and CI
fails when either copy is stale. Edit the files here, never a copy.

The template is Jinja2, rendered by `jinja2` in Python and by a small renderer
in R that implements the same subset: `{{ name }}` substitution,
`{% if name %}` / `{% if not name %}` / `{% else %}` / `{% endif %}` on plain
names, and `{% raw %}` for literal braces such as governed-definition tokens.
Conditions are names rather than expressions, so anything compound is computed
alongside the other prompt data. Substituted values are inserted without
recursive rendering, which is what preserves governed-definition tokens and
app-authored instructions. HTML comments are removed from the rendered prompt.
App-authored instructions occupy the final `## Additional instructions`
section.

`tests/shared/prompt-render.json` pins what both renderers produce for the same
data. A rendering difference between the two languages is a defect in whichever
one disagrees with the fixture.
