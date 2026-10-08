# commons (development version)

* Agents write reports as Quarto documents. In `commons_server()`, a document
  streams into the chat's drawer as the agent writes it, with each R cell
  knitted in a sandboxed R session as soon as it arrives. Documents get their
  data by calling trusted calculations in their code, whose results are saved
  beside the document, and the agent revises them with a new `edit_artifact`
  tool.

* On Posit Connect, viewers share a read-only copy of a conversation or a
  document as static content they own, from a new `commons_share_button()`
  or the document drawer. `commons_app()` includes the button. Sharing is
  available when the app's deployer associates a Connect "Visitor API Key"
  integration.

* Restored conversations show answers as they were displayed, with their
  documents, citations, and provenance markers.

# commons 0.1.1

* Fixes an issue with the R code sandbox where the generated policy would be
  too long when there were thousands of R packages installed.

* A number of improvements to documentation.

# commons 0.1.0

* Initial release.
