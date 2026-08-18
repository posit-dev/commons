Read README.Rmd to understand the goal of the project.

This package has not been widely adopted or publicly released; changes can be made without a deprecation cycle (or even reference to the way that it used to work).

`commons` supports the published table-level `definitions` field in `data-dict.yaml`. Definitions use data-dict's expression language and are compiled to the attached source's SQL dialect. Commons temporarily ports the definition-specific export logic until a data-dict R package is available; see [commons #115](https://github.com/posit-dev/commons/issues/115) for the integration design.
