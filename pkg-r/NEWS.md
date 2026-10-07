# commons (development version)

* Agents write reports as Quarto documents. In `commons_server()`, a document
  streams into the chat's drawer as the agent writes it, then renders in a
  sandboxed R session. Documents get their data from trusted calculations
  declared as inputs, the agent revises them with a new `edit_artifact` tool,
  and users can download one as a directory that deploys to Posit Connect as
  it stands.

# commons 0.1.1

* Fixes an issue with the R code sandbox where the generated policy would be
  too long when there were thousands of R packages installed.

* A number of improvements to documentation.

# commons 0.1.0

* Initial release.
