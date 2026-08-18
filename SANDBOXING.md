# Sandboxing `run_r`

`commons` runs model-authored R code through the `run_r` tool. That code does
not execute in the R process that created the agent. It executes in a separate
`callr::r_session` worker, which must engage an operating-system sandbox before
it evaluates code.

This document describes the controls implemented in this repository. It is a
description of the implementation, not a claim that the worker is safe to run
against arbitrary host or kernel vulnerabilities.

## Scope and guarantees

The sandbox applies to the `run_r` worker only. The parent R process, its
database connections, and the agent process are not sandboxed. The worker is
created lazily and reused for calls to the same agent, so variables and loaded
packages persist until the worker is closed or replaced.

The worker runs only on Linux and macOS. `commons()` refuses to create an agent
on a Linux host without seccomp and without either Landlock or an unprivileged
user-namespace sandbox. Other operating systems are rejected when the worker
initializes.

The controls are intended to:

- prevent the worker from reading or writing files outside a narrow allowlist;
- deny network access by default;
- prevent common in-process sandbox-escape setup operations;
- avoid passing ambient credentials and function environments to the worker;
- limit the lifetime of stuck worker code.

They do not prevent the worker from computing arbitrarily, loading code from
its readable library paths, or starting ordinary subprocesses. On Linux, the
seccomp policy deliberately permits ordinary `exec` and non-namespace
`clone`; those processes remain subject to the worker's sandbox restrictions.

## Worker startup controls

### Separate process

`run_r` uses a `callr::r_session` rather than evaluating model code in the
agent's R process. The worker's entry points are transferred into the child's
global environment and do not reference the parent process's `commons`
internals.

Source: [`R/run-r.R`](R/run-r.R#L239-L272)

### Environment allowlist

The child is launched with nearly all inherited environment variables removed.
Only execution and locale variables required to start R are retained:

- `PATH`, `LANG`, and `LC_*`;
- dynamic-library and R installation/library variables;
- R environment and profile variables.

The worker receives a fresh working directory as both `HOME` and `TMPDIR`.
This specifically prevents ambient API keys, session tokens, database URLs,
and similar environment-based credentials from crossing into the worker.

Source: [`R/run-r.R`](R/run-r.R#L305-L333)

### Explicit input boundary

Results from the agent's trusted tools are copied into the worker as handles.
Measure and helper functions are supplied as source text only. Their original
environments, including connections and credentials captured by those
environments, are not supplied.

Source: [`R/run-r.R`](R/run-r.R#L543-L554) and
[`R/measures.R`](R/measures.R#L30-L34)

### Controlled working directory and filesystem roots

The worker starts in its own temporary directory. Before the OS sandbox is
engaged, `commons` computes these filesystem roots:

- Read roots: R's home, installed R libraries, resolved library directories,
  and a small OS-specific set of system directories required to run R.
- Write roots: the worker directory and the parent `callr` temporary directory
  used to return results.

Both literal and resolved paths are included so that symlinked R libraries and
macOS's `/tmp` and `/var` aliases work correctly.

This is an allowlist, not a claim that the permitted system directories contain
only safe content. In particular, a worker can read the system and R package
files needed to execute.

Source: [`R/run-r.R`](R/run-r.R#L459-L537)

## Linux controls

Linux applies one filesystem backend, then always applies an escape-prevention
seccomp policy. The default backend selection is Landlock first and user/mount
namespaces as a fallback. An optional nsjail backend is selected with:

```r
options(commons.run_r_sandbox = "nsjail")
```

This mode requires an executable `nsjail` on `PATH` (or at
`options(commons.nsjail_path = ...)`) and a host that permits unprivileged user
namespaces. It is a launch-time backend: nsjail starts the `callr` worker inside
its namespaces before R begins evaluating worker initialization.

### Linux control map

This table maps each Linux isolation control to the kernel interface that
facilitates it. A control can use more than one interface. Entries marked "Not
directly invoked by `commons`" are implemented by R or `callr`, rather than the
native sandbox layer.

| Isolation | Mechanism | Linux system call or kernel interface |
| --- | --- | --- |
| Separate execution process | `callr::r_session` starts the worker outside the agent's R process. | Not directly invoked by `commons`; `callr`/`processx` creates the child process. |
| Ambient credential isolation | The worker starts with an environment allowlist and a fresh `HOME` and `TMPDIR`. | No kernel isolation syscall; environment construction occurs before process launch. |
| Filesystem allowlist | Landlock grants read-only or read-write access only below declared roots. | `landlock_create_ruleset`, `landlock_add_rule`, `landlock_restrict_self` |
| Landlock ABI coverage | The ruleset handles all filesystem rights known to the detected Landlock ABI. | `landlock_create_ruleset` with `LANDLOCK_CREATE_RULESET_VERSION` |
| Filesystem fallback | A user namespace and mount namespace isolate the worker's mount view. | `unshare(CLONE_NEWUSER | CLONE_NEWNS)` |
| nsjail filesystem backend | nsjail starts the worker in a user/mount namespace and `pivot_root`s into a mount tree containing only declared bind mounts. | nsjail invokes `unshare`, `mount`, `pivot_root`, and `umount2` before it `execve`s R |
| nsjail control-descriptor preservation | The generated policy preserves callr's protocol and redirected-output descriptors while nsjail closes other inherited descriptors before R executes. | `fcntl(FD_CLOEXEC)` through nsjail; policy `pass_fd: 3`, `pass_fd: 5`, and `pass_fd: 6` |
| User and group mapping | The fallback maps the caller's UID/GID and disables supplementary-group changes. | `open`, `write`, and `close` on `/proc/self/setgroups`, `/proc/self/uid_map`, and `/proc/self/gid_map` |
| Host mount protection | The fallback makes mount propagation private before changing mounts. | `mount(..., MS_PRIVATE | MS_REC, ...)` |
| New filesystem root | The fallback mounts a tmpfs root, pivots into it, then detaches the host root. | `mount("tmpfs", ...)`, `pivot_root`, `umount2` |
| Read-only filesystem roots | The fallback recursively bind-mounts declared roots and remounts read roots read-only. | `mount(..., MS_BIND | MS_REC, ...)`, `mount(..., MS_REMOUNT | MS_BIND | MS_RDONLY, ...)` |
| Inherited-descriptor isolation | The fallback closes inherited sockets and file/device descriptors outside allowed roots, preserving only callr's required descriptors. | `open`/`readdir` on `/proc/self/fd`, `fstat`, `readlink`, `fcntl`, `close` |
| Capability isolation | The fallback removes all capabilities from both the bounding set and current capability sets. | `prctl(PR_CAPBSET_DROP, ...)`, `capset` |
| No privilege gain on exec | The worker forbids gaining privileges after sandbox setup. | `prctl(PR_SET_NO_NEW_PRIVS, 1, ...)` |
| Sandbox-escape syscall denial | Seccomp denies cross-process memory access, mount/chroot operations, namespace operations, and namespace-creating clones. | `prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, ...)` with a BPF filter |
| Network denial by default | A second seccomp filter denies `socket` and `io_uring_setup`. | `prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, ...)` with a BPF filter |
| Worker address-space limit | The native API can limit virtual address space, but the normal `run_r` path passes no limit. | `setrlimit(RLIMIT_AS, ...)` when configured; not currently enabled by `worker_init()` |
| Time limit and worker replacement | The parent interrupts and, if needed, closes an unresponsive worker. | Not a sandbox syscall; implemented through `callr`/`processx` process control. |

### `no_new_privs`

Before applying Landlock or seccomp, the worker sets `PR_SET_NO_NEW_PRIVS`.
This prevents later execution from gaining privileges through set-user-ID,
set-group-ID, or file-capability mechanisms.

Source: [`src/sandbox.c`](src/sandbox.c#L677-L680)

### Landlock filesystem confinement

Landlock is the preferred filesystem backend. `commons` invokes the Landlock
syscalls directly because the implementation does not depend on a libc wrapper.
It follows the Landlock userspace API documented in the
[Linux kernel documentation](https://docs.kernel.org/userspace-api/landlock.html):

1. Query the supported Landlock ABI using `LANDLOCK_CREATE_RULESET_VERSION`.
2. Create a ruleset that handles every supported filesystem access right.
3. Add a `LANDLOCK_RULE_PATH_BENEATH` rule for every read and read-write root.
4. Apply the ruleset permanently to the worker with
   `landlock_restrict_self`.

Read roots receive execute, file-read, and directory-read access. Write roots
receive every filesystem right handled by the detected ABI. Access to handled
rights outside those roots is denied.

Landlock leaves rights that are not declared in the ruleset unrestricted.
Accordingly, `commons` declares the base ABI 1 filesystem rights and adds:

- `REFER` on ABI 2 and later;
- `TRUNCATE` on ABI 3 and later;
- device `IOCTL` on ABI 5 and later.

Source: [`src/sandbox.c`](src/sandbox.c#L100-L178)

### User and mount namespace fallback

If Landlock is unavailable because the kernel does not implement or permit it,
the worker attempts a namespace-based filesystem sandbox. This backend:

1. Requires a single-threaded process, then creates a user namespace and a
   mount namespace.
2. Maps only the calling UID and GID, after writing `deny` to `setgroups`.
3. Makes mount propagation private, preventing its mount changes from
   propagating to the host mount namespace.
4. Closes inherited sockets and closes file/device descriptors that do not
   point to declared read or write roots. The descriptors necessary for `callr`
   status and output are preserved.
5. Mounts a 16 MiB tmpfs as a new root and uses `pivot_root`.
6. Recursively bind-mounts only the declared roots into that new root.
7. Remounts all read roots read-only, including nested mounts.
8. Detaches the original host root and remounts the sandbox root read-only.
9. Drops every capability from both the capability bounding set and the current
   capability sets.

The namespace fallback does not create a PID namespace or a network namespace.
Network isolation comes from seccomp, and ordinary subprocesses are permitted.

Source: [`src/sandbox.c`](src/sandbox.c#L216-L540)

### nsjail backend

The optional `nsjail` backend applies the same path allowlist at process
creation rather than by calling the package's native sandbox API from
`worker_init()`. `commons` generates a per-worker nsjail Protobuf configuration
and a Kafel seccomp policy, then uses a short executable wrapper as the
`callr` worker binary.

The generated configuration:

1. creates user and mount namespaces, plus a network namespace for
   `network = "none"`;
2. maps the current user and group into the user namespace;
3. lets nsjail build a new mount tree and `pivot_root` into it, with only the
   same read-only and read/write roots used by the native namespace backend;
4. clears the inherited environment and supplies the existing execution and
   locale allowlist;
5. preserves only standard I/O and callr's required control/output
   descriptors (`3`, `5`, and `6`);
6. keeps nsjail's default `no_new_privs` and capability-drop behavior;
7. installs a generated Kafel policy that denies the same escape setup
   operations as the native filter, including namespace-creating `clone`
   calls, and additionally denies `socket` and `io_uring_setup` in offline
   mode.

The parent still builds the environment and transfers trusted inputs as
described above. Those are application-level controls, not nsjail policy
features.

Source: [`R/run-r.R`](R/run-r.R#L303-L554)

### Seccomp escape-prevention policy

After the filesystem backend has engaged, the worker installs a seccomp BPF
filter. It verifies that syscalls use the expected native architecture and, on
x86_64, rejects the x32 syscall ABI. The filter returns `EPERM` for:

- `ptrace`;
- `process_vm_readv` and `process_vm_writev`;
- mount, unmount, `pivot_root`, and `chroot`;
- `unshare` and `setns`;
- the newer mount APIs (`open_tree`, `move_mount`, `fsopen`, `fsconfig`,
  `fsmount`, `fspick`, and `mount_setattr`);
- `clone3`;
- `clone` requests carrying any namespace-creation flag.

The `clone3` denial causes glibc to use `clone`, whose flags the BPF program
can inspect. Ordinary threads and subprocesses that do not create a namespace
remain allowed.

Source: [`src/sandbox.c`](src/sandbox.c#L543-L604)

### Network policy

`network = "none"` is the default. In that mode, `commons` installs a second
seccomp filter that returns `EPERM` for `socket` and `io_uring_setup`, blocking
ordinary socket creation and an alternate asynchronous-I/O path. The worker
can be configured with `network = "full"`; that omits this network filter but
does not relax filesystem confinement or the escape-prevention seccomp filter.

Source: [`src/sandbox.c`](src/sandbox.c#L606-L630) and
[`R/commons.R`](R/commons.R#L104-L145)

## macOS controls

On macOS, `commons` uses the Seatbelt `sandbox_init()` API from `libSystem`.
It dynamically builds an SBPL profile with these rules:

- start from `(allow default)`;
- deny `network*` unless `network = "full"`;
- deny `file-write*`, then allow writes to `/dev/null` and the explicit
  read-write roots;
- deny `file-read*`, then allow reads from the explicit read-only and
  read-write roots;
- allow `file-read-metadata` globally so that the worker can traverse paths.

The last rule means the worker can learn file metadata or existence outside its
read roots, but cannot read file contents through the policy. Root paths
containing a quote or backslash are rejected before they are interpolated into
the SBPL profile.

The macOS backend does not apply Linux's Landlock, namespace, seccomp, or
inherited-file-descriptor controls.

Source: [`src/sandbox.c`](src/sandbox.c#L717-L828)

## Execution and lifecycle safeguards

These mechanisms complement the OS sandbox but are not filesystem or privilege
isolation controls.

### Time limit and worker replacement

Each `run_r` call has a configurable 60-second default wall-clock timeout. The
parent first interrupts the worker. If it remains unresponsive for another five
seconds, the parent closes it and the next call starts a fresh worker.

Source: [`R/run-r.R`](R/run-r.R#L353-L436)

### Worker cleanup

The worker is closed when its agent is garbage-collected and after a
configurable idle period (default 600 seconds). This limits stray worker
processes and clears persisted worker state after inactivity.

Source: [`R/run-r.R`](R/run-r.R#L221-L232) and
[`R/run-r.R`](R/run-r.R#L335-L350)

### Memory-limit support is not currently enabled

The native API accepts an optional address-space limit and uses `RLIMIT_AS` on
Linux when a limit is supplied. `worker_init()` currently passes `NULL`, so
normal `run_r` execution does not receive a memory limit. macOS accepts the
same argument for interface parity, but the implementation notes that the
kernel does not enforce it reliably.

Source: [`src/sandbox.c`](src/sandbox.c#L669-L675),
[`src/sandbox.c`](src/sandbox.c#L774-L782), and
[`R/run-r.R`](R/run-r.R#L528-L537)

## Verification

The sandbox tests start a real worker, create a canary file outside its allowed
roots, and assert that the worker cannot read or write it. They also assert
that socket creation and an attempted `curl` subprocess are denied by default.
The user-namespace test separately verifies that an inherited file descriptor
to the canary cannot be used. The nsjail test exercises the same read, write,
socket, subprocess, and ordinary-exec probes when nsjail and user namespaces
are available. A full-network test verifies that enabling network access does
not relax filesystem confinement.

Source: [`tests/testthat/test-sandbox.R`](tests/testthat/test-sandbox.R#L73-L232)

[`tools/nsjail.Dockerfile`](tools/nsjail.Dockerfile) builds a Linux smoke-test
image from nsjail's source and runs the nsjail worker chain against an external
canary. Docker's default seccomp profile blocks the nested
`unshare(CLONE_NEWUSER | CLONE_NEWNS | CLONE_NEWNET)` call required by nsjail,
so this smoke test must run on a Linux container runtime configured to permit
unprivileged user and mount namespaces. It must not be treated as a reason to
weaken the production container profile broadly.

## Limitations and non-goals

- The sandbox does not protect against kernel, R, package, or permitted-system
  binary vulnerabilities.
- The worker can read every file below its configured read roots, which include
  R and system directories needed for execution.
- The worker can execute programs available in those roots. The sandbox relies
  on the filesystem and syscall restrictions to constrain those programs.
- `network = "full"` intentionally permits network access.
- The namespace fallback's explicit inherited-FD pruning is not performed by
  the Landlock or Seatbelt backends.
- The nsjail backend requires an executable nsjail and a runtime that permits
  creating user and mount namespaces. Standard Docker profiles commonly block
  this nested namespace creation.
- Seatbelt intentionally allows global file-read metadata, which leaks file
  existence and some metadata outside the allowlist.
- The worker has no active memory limit in the current `run_r` call path.
- A sandboxed worker can still consume CPU until the parent timeout interrupts
  or replaces it.
