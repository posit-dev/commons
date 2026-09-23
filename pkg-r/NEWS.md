# commons (development version)

* The Linux sandbox now closes the abstract Unix socket channel to the worker. Under the default `network = "none"`, the seccomp filter denies the calls that would aim a local socket at a peer by address (`bind`, `connect`, `sendmsg`, `sendmmsg`, and `sendto` when given an address), and on Linux 6.12 and later the Landlock ruleset scopes abstract sockets even under `network = "full"`. The R filters also screen `socketcall` (i386) and `pidfd_getfd`, matching the Python implementation.

# commons 0.1.0

* Initial release.
