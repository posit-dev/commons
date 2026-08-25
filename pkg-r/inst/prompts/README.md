# commons' system prompt

`system-prompt.md` is the readable source of the default agent behavior. Its
construction balances a few goals:

- The prompt should be human-readable as-is; prose that could land in the 
  system prompt should live in the prompt itself. Keep prompt prose in Markdown. 
  R supplies runtime facts and content, not headings or behavioral instructions.
- Keep the workflow general across agent compositions. Instructions specific
  to an optional tool belong in that tool's description. Notably, `search_pool()`,
  `call_measures()`, and `call_metrics()` are described as relating to
  'trusted calculations' so that the system prompt doesn't need to conditionally
  include specific tool names.
- Keep ambient context useful but bounded. Detailed table and definition
  context arrives through tools when needed.

commons template expressions use glue's standard `{` and `}` delimiters.
Literal braces in template prose are doubled. Expression results are inserted
without recursive interpolation, preserving governed-definition tokens and
app-authored instructions. HTML comments are removed from the rendered prompt.
App-authored instructions occupy the final `## Additional instructions`
section.
