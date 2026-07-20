test_that("sandbox_capabilities reports both mechanisms", {
  caps <- sandbox_capabilities()
  expect_named(caps, c("landlock_abi", "seccomp"))
  expect_type(caps$landlock_abi, "integer")
  expect_type(caps$seccomp, "logical")
})

test_that("sandbox_engage is a silent no-op off Linux", {
  skip_on_os("linux")
  expect_silent(res <- sandbox_engage(tempdir(), tempdir()))
  expect_false(res)
})

test_that("an engaged worker is denied reads, writes, and sockets", {
  skip_on_os(c("mac", "windows", "solaris"))
  skip_if_not(sandbox_capabilities()$landlock_abi >= 1, "kernel lacks Landlock")

  outside <- file.path(dirname(tempdir()), paste0("canary-", Sys.getpid()))
  dir.create(outside)
  on.exit(unlink(outside, recursive = TRUE), add = TRUE)
  writeLines("secret", file.path(outside, "secret.txt"))

  probes <- callr::r(
    function(read_roots, parent_tmp, outside) {
      commons:::sandbox_engage(read_roots, c(parent_tmp, tempdir()))
      denied <- function(expr) {
        tryCatch(
          {
            expr
            "allowed"
          },
          error = function(e) "denied",
          warning = function(w) "denied"
        )
      }
      list(
        read = denied(readLines(file.path(outside, "secret.txt"), n = 1)),
        write = if (
          isTRUE(suppressWarnings(file.create(file.path(outside, "w"))))
        ) {
          "allowed"
        } else {
          "denied"
        },
        socket = denied({
          con <- socketConnection(
            "127.0.0.1",
            port = 9,
            blocking = TRUE,
            timeout = 1
          )
          close(con)
        }),
        compute = sum(1:10)
      )
    },
    args = list(
      read_roots = sandbox_read_roots(),
      parent_tmp = tempdir(),
      outside = outside
    )
  )

  expect_equal(probes$read, "denied")
  expect_equal(probes$write, "denied")
  expect_equal(probes$socket, "denied")
  expect_equal(probes$compute, 55)
})
