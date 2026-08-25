# Code execution prior art: Inspect and Monty

Date: 2026-08-20. Status: research complete.

This note records what the reading settled for the execution tool in M6 (kata `40jg`), and what it left open.

The decision labels below (D3, M6) belong to `docs/superpowers/plans/2026-08-18-commons-python-port.md`. That document is not tracked in this repository, so this note carries the parts of it that outlive the plan.

## The question

commons for R runs model-written code in a persistent `callr` worker (`pkg-r/R/run-r.R`). Python needs a `run_python` tool with the same behavior. D3 of the planning document already chose a plain subprocess over a Jupyter kernel for v1. The 2026-08-19 meeting asked for a look at prior art before M6 commits to a design, and named two projects: Inspect (`inspect_ai`) and Pydantic's Monty. It also asked whether sandboxed code execution is a problem larger than commons, and needs its own package.

## What "closest to callr" means

`callr::r_session` is an R6 class that extends `processx::process`. It starts a new R process from the same R installation, with the same binary and the same `.libPaths()`. That process stays alive across calls and evaluates one call at a time. Arguments and results move by serialization, so they are copies and never shared memory. A pollable file descriptor supports non-blocking waits. commons adds lazy spawn, promise-chain serialization, timeouts, kill-and-respawn, and an environment-variable allowlist on top of that.

Two properties do the work here, and they pull in opposite directions:

- The **environment must match** the host. The model expects pandas, polars, matplotlib and duckdb to behave in the worker as they do in the parent. That needs the same interpreter version and the same installed packages.
- The **process state must not carry over**. Globals, loaded objects and open connections belong to the parent. A fresh `R --no-save` guarantees this, and `callr` never forks.

In Python, a fresh subprocess of `sys.executable` gives both. Inside a virtual environment, `sys.executable` fixes the interpreter and its site-packages for free. The fresh `exec` is what leaves the parent's in-memory state behind.

Credentials are a third thing, and the fresh process does nothing about them. A subprocess inherits the parent environment by default. API keys, session tokens and database URLs therefore reach the worker, unless the launcher passes an explicit `env`. The R side treats this as separate for the same reason: `worker_scrubbed_env()` in `pkg-r/R/run-r.R` builds an allowlist, because an OS sandbox cannot hide these values either. The Python worker needs the same allowlist, and it is not optional.

The allowlist is necessary, and on its own it is not always sufficient. What settles it is whether the child runtime runs startup code that puts the values back after the parent excluded them. Both R and Python have such a path, so neither worker can treat the allowlist as the whole answer. The Python one is measured below.

Python has a smaller version of the same hazard, and the worker must close it explicitly. A plain `python -c` imports `site`, which imports `usercustomize` from the user site directory. That module runs arbitrary code before the worker starts, so it can set `os.environ` back. This was measured: a planted `usercustomize.py` restored a variable that `env=` had excluded.

Isolated mode (`-I`) blocks it, and so does `-s` alone. So `env=` is not sufficient on its own, and `env=` with `-I` is what the M6 worker needs. What still runs under `-I` is `sitecustomize` and any `.pth` import hooks in the site-packages directories that stay on the path. Isolated mode drops the user site directory. It does not drop the global one.

So the remaining surface is only the managed environment when two conditions hold: `sys.executable` is a virtual environment, and that environment sets `include-system-site-packages = false`. Under a system interpreter, or a virtual environment built with system site-packages included, global `sitecustomize` and `.pth` hooks run as well. M6 needs to state which of these it assumes rather than inherit whichever interpreter the host provides.

## Options considered

| Option | Verdict |
|---|---|
| `asyncio.create_subprocess_exec(sys.executable, "-I", "-u", worker.py)` with line-delimited JSON | **Chosen.** A fresh process on the same binary and virtual environment. A persistent worker loop gives the persistent session. `env=` is an explicit allowlist, and we own the serialization format. `asyncio` replaces both the `later_fd` polling and the promise chain, where an `asyncio.Lock` plays the part of R's `worker$tail`. |
| `multiprocessing`, any start method | Rejected. Transfers are pickle in both directions, so the untrusted worker sends pickles that the parent then executes. That is the boundary violation the design bans. The `fork` start method also copies parent memory, including in-memory secrets and open connections, into the child. |
| `concurrent.futures.ProcessPoolExecutor` | Rejected. Pool-of-workers semantics, a pickle transport, and no persistent namespace per agent. The wrong shape. |
| A stateless `python3 -` per call (the Inspect model) | Not equivalent. It gives up the session persistence that the tool description promises the model, and with it the `r1`, `r2` handle model. Keep it as the fallback if session state is ever judged not worth the cost. That is a product decision, not an implementation one. |
| A Jupyter kernel | Settled by D3. Right for the longer term, not for v1. |
| rpyc, execnet | Rejected. The live object proxies of rpyc cross the boundary, which is an anti-feature here, and execnet is legacy. |

## What Inspect gives us

Inspect's `python()` tool (`src/inspect_ai/tool/_tools/_execute.py`) is deliberately stateless. Every call runs `bash --login -c "python3 -"` with the code on stdin inside a `SandboxEnvironment`, and returns stderr and stdout as one string. Its model-facing docstring says the consequences plainly: no state is preserved, and the model must call `print()` explicitly.

So Inspect is not prior art for a persistent session. It is good prior art for the plumbing, and four things carry over:

- **The shape of the `SandboxEnvironment.exec(cmd, input, cwd, env, user, timeout)` interface.** The `local` backend is a thin subprocess wrapper with a temporary working directory per sample and no isolation. The `docker` backend implements the same interface with real isolation. A launcher written against an interface of this shape turns a future Connect-container backend into an implementation, not an edit above it.
- **Code over stdin, never over argv.** No escaping limits and no length limits.
- **An output cap as a ring buffer.** Past the cap it keeps the most recent bytes. The process still runs to completion, rather than being killed or blocked.
- **The timeout and kill edge cases** in `util/_subprocess.py`. Three of them are worth copying:
  - A timeout through `anyio.fail_after`.
  - A graceful terminate followed by SIGKILL on cancellation.
  - An explicit bounded wait after SIGKILL, for the race where the child watcher misses the exit.

One more for later. Inspect's stateful tools (`bash_session`, the editor, the browser) run a long-lived service inside the sandbox and speak RPC to it through repeated `exec` calls. That is how a persistent commons session survives a move to a container boundary that only offers `exec`. The v1 worker loop is already that service, launched directly instead of inside a container.

## What Monty gives us

Monty is a minimal Python interpreter written in Rust. It has microsecond startup, resource limits, snapshottable interpreter state, and a standard library of about a dozen modules. The host controls its filesystem, environment and network access.

Monty cannot be the engine. Its README states that support for external Python libraries is not a goal, so there is no pandas, no polars, no matplotlib and no duckdb. Monty's own `run_python` exists for exactly that work. It is also explicitly experimental.

Three things carry over anyway:

- **POSIX rlimits at the boundary.** Monty treats these as table stakes. A `resource.setrlimit` call for address space and CPU in the worker's startup is cheap, and is independent of whatever sandbox lands later.
- **The driver and worker packaging split.** Monty ships `pydantic-monty-client` next to a separate runtime binary, which validates the same split here.
- **Codemode as a post-v1 direction.** Model-written orchestration calls host-registered functions, and measures never leave the host. That is a governed alternative to a raw `run_python` tool, and Monty suits it. It is filed as a direction, not as work.

## REPL semantics need an `ast` split

`run_r` tells the model that it can return results implicitly, and the R tool behaves that way. Python needs an explicit step to match: parse the submitted code, pop a trailing `ast.Expr`, `exec` the rest, then `eval` that last expression. Without it, `x` on the final line returns nothing and the model has to write `print(x)`.

The redirect of stdout and stderr around the call belongs with this. User prints then become typed output segments instead of corrupting the protocol channel.

## The open question, answered

The meeting asked whether sandboxed execution deserves its own package rather than a commons subsystem. The Inspect reading supports keeping it inside commons for now. The boundary is a single `exec`-shaped interface with five or six arguments, so a later extraction is a small piece of work. Nothing about the v1 design forecloses it, and there is no Python user base yet to justify the extra package.

## What M6 takes from this

The design in the planning document under M6 is the outcome of this note:

- An `asyncio` subprocess worker on `sys.executable`, speaking line-delimited JSON.
- Values by copy: Arrow IPC for frames, JSON for scalars, never pickle.
- An explicit `env=` allowlist from day one, with `-I`, because inheritance is the default and `usercustomize` can undo the allowlist. Lazy spawn.
- An `asyncio.Lock` for one call at a time, and kill-and-respawn on timeout.
- rlimits in the worker startup, under an `exec`-shaped seam.
