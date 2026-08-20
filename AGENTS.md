# NA

Read README.Rmd to understand the goal of the project.

This package has not been widely adopted or publicly released; changes
can be made without a deprecation cycle (or even reference to the way
that it used to work).

Use soft wrapping for prose in Markdown files, including skills and
vignettes.

`commons` supports the published table-level `definitions` field in
`data-dict.yaml`. Definitions use data-dict’s expression language and
are compiled to the attached source’s SQL dialect. Commons temporarily
ports the definition-specific export logic until a data-dict R package
is available; see [commons
\#115](https://github.com/posit-dev/commons/issues/115) for the
integration design.

When writing tests for this package, refrain from excessive mocking.
Instead, prefer testing the real, live path, skipping the test when the
needed package or API key isn’t available. Broadly, refrain from
`expect_match()` for text that is unconditionally included in a prompt
or tool description, and `expect_no_match()` for text that has no
feasible path to end up in the prompt or tool descriptions.
