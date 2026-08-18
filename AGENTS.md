# NA

Read README.Rmd to understand the goal of the project.

This package has not been widely adopted or publicly released; changes
can be made without a deprecation cycle (or even reference to the way
that it used to work).

When writing tests for this package, refrain from excessive mocking.
Instead, prefer testing the real, live path, skipping the test when the
needed package or API key isn’t available. Broadly, refrain from
`expect_match()` for text that is unconditionally included in a prompt
or tool description, and `expect_no_match()` for text that has no
feasible path to end up in the prompt or tool descriptions.
