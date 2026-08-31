#' @keywords internal
"_PACKAGE"

# Registers the contents_shinychat() method for ContentTurnReminder (and any
# future methods on generics from other packages) when the namespace loads.
.onLoad <- function(libname, pkgname) {
  S7::methods_register()
}

## usethis namespace: start
#' @importFrom R6 R6Class
#' @useDynLib commons, .registration = TRUE
#' @importFrom coro async_generator await_each
#' @importFrom rlang %||%
## usethis namespace: end
NULL
