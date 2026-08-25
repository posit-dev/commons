# Code execution prior art: Inspect and Monty

Date: 2026-08-20.

This note records some notes for the Python execution tool (`run_python`) in the context of what is done in the R implementation of `commons` vs. what approaches some other popular libraries take around the concept of code execution.

## The question

commons for R runs model-written code in a persistent `callr` worker (`pkg-r/R/run-r.R`). Python needs a `run_python` tool with the same behavior. A plain subprocess was chosen over a Jupyter kernel for v1. Before committing to a design, we surveyed prior art in two projects: [Inspect](https://github.com/UKGovernmentBEIS/inspect_ai) (`inspect_ai`) and Pydantic's [Monty](https://github.com/pydantic/monty). We also asked whether sandboxed code execution is a problem larger than commons, and needs its own package.

## What "closest to callr" means

`callr::r_session` is an R6 class that extends `processx::process`. It starts a new R process from the same R installation, with the same binary and the same `.libPaths()`. That process stays alive across calls and evaluates one call at a time. Arguments and results move by serialization, so they are copies and never shared memory. A pollable file descriptor supports non-blocking waits. `commons` adds lazy spawn, promise-chain serialization, timeouts, kill-and-respawn, and an environment-variable allowlist on top of that.

Two properties are key to being consistent with the R implementation:

- The **environment must match** the host. The model expects pandas, polars, matplotlib and duckdb to behave in the worker as they do in the parent. That needs the same interpreter version and the same installed packages.
- The **process state must not carry over**. Globals, loaded objects and open connections belong to the parent. A fresh `R --no-save` guarantees this, and `callr` never forks.

In Python, a fresh subprocess of `sys.executable` gives both. Inside a virtual environment, `sys.executable` fixes the interpreter and its site-packages for free. The fresh `exec` is what leaves the parent's in-memory state behind.

Careful handling of credentials is very important. A subprocess inherits the parent environment by default. API keys, session tokens and database URLs therefore reach the worker, unless the launcher explicitly overrides the `env`. The R side does this via `worker_scrubbed_env()` in `pkg-r/R/run-r.R` by building an explicity whitelist of environment variables the worker should have access to. The Python worker should follow this design.

An explicit whitelist is necessary but not sufficient to guarantee private information does not end up in the worker process. For example, the child runtime could run startup code that puts values back by sourcing common files like `.Renviron`, `.env`, etc. Both R and Python implementations need to take care so the worker is not able to access values in this way.

<details>
<summary>An example of this in python via the `usercustomize` mechanism</summary>

> A plain `python -c` imports `site`, which imports `usercustomize` from the user site directory. That module runs arbitrary code before the worker starts, so it can set `os.environ` back. This was measured: a planted `usercustomize.py` restored a variable that `env=` had excluded.
> 
> Isolated mode (`-I`) blocks it, and so does `-s` alone. So `env=` is not sufficient on its own, and `env=` with `-I` is what the worker needs. What still runs under `-I` is `sitecustomize` and any `.pth` import hooks in the site-packages directories that stay on the path. Isolated mode drops the user site directory. It does not drop the global one.

</details>

What still gets through depends on which Python the worker runs. If it is a virtual environment that excludes the system-wide packages (the default for `python -m venv` and `uv venv`), then only startup hooks inside that environment can run. If it is a system Python, or a virtual environment that includes the system packages, hooks installed system-wide run too.

The recommendation follows from this: run the worker on a Python whose startup hooks are known. In practice that means either a virtual environment that excludes system packages, or a system Python inside a container image, where the image author controls what is installed. The case to avoid is a shared system Python on a multi-user machine, where anyone with write access to site-packages can drop in a `.pth` file. If the worker finds itself on such an interpreter, it should warn rather than silently accept whatever the host happens to provide.

## Options considered for Python code execution v1

| Option | Verdict |
|---|---|
| `asyncio.create_subprocess_exec(sys.executable, "-I", "-u", worker.py)` with line-delimited JSON | ✅ A fresh process on the same binary and virtual environment. A persistent worker loop gives the persistent session. `env=` is an explicit allowlist, and we own the serialization format. `asyncio` replaces both the `later_fd` polling and the promise chain, where an `asyncio.Lock` plays the part of R's `worker$tail`. |
| `multiprocessing`, any start method | ❌ Transfers are pickled in both directions, so the parent unpickles bytes the untrusted worker sends. `pickle.loads` runs whatever opcodes the stream contains, so model-written code in the worker could execute arbitrary code in the parent process (unsafe). The `fork` start method also copies parent memory, including in-memory secrets and open connections, into the child. |
| `concurrent.futures.ProcessPoolExecutor` | ❌ Pool-of-workers semantics, a pickle transport, and no persistent namespace per agent. The wrong shape. |
| A stateless `python3 -` per call (this is what Inspect does) | ❌ Not equivalent to our needs. It gives up the session persistence that the tool description promises the model, and with it the `r1`, `r2` handle model used on the R side, where tool results are preloaded into the session as variables for follow-up code. |
| A Jupyter kernel | ⚠️ Worth investigating for the longer term, but too ambitious for the v1 timeline. |
| rpyc, execnet | ❌ The live object proxies of rpyc cross the boundary, which is an anti-feature here, and execnet is legacy. |

## What we can learn from Inspect

Inspect's `python()` tool (`src/inspect_ai/tool/_tools/_execute.py`) is deliberately stateless. Every call runs `bash --login -c "python3 -"` with the code on stdin inside a `SandboxEnvironment`, and returns stderr and stdout as one string. Its model-facing docstring declares the expectation that *no state is preserved*, and *the model must call `print()` explicitly*.

So Inspect is not exactly prior art for a persistent session like `commons` needs. It is good prior art for the plumbing, and four things carry over:

- **The shape of the `SandboxEnvironment.exec(cmd, input, cwd, env, user, timeout)` interface.** Inspect has two backends behind this one interface: `local`, a thin subprocess wrapper with a temporary working directory per sample and no isolation, and `docker`, which implements the same interface with real isolation. If our launcher is written against an interface of this shape, a future Connect-container backend slots in as another implementation rather than requiring changes to the code above it.
- **Passing code on stdin, never as a command-line argument.** No escaping problems and no length limits.
- **Capping output by keeping the tail, not killing the process.** Once output passes the cap, Inspect keeps only the most recent bytes and lets the process run to completion, rather than killing it or letting it stall on a full pipe.
- **The timeout and kill edge cases** in `util/_subprocess.py`. Three of them are worth copying:
  - A timeout through `anyio.fail_after`.
  - A graceful terminate followed by SIGKILL on cancellation.
  - An explicit bounded wait after SIGKILL, for the race where the child watcher misses the exit.

One further pattern is worth keeping for later, though v1 does not need it: Inspect's stateful tools (`bash_session`, the editor, the browser) run a long-lived service inside the sandbox and speak RPC to it through repeated `exec` calls. That is how a persistent commons session survives a move to a container boundary that only offers `exec`. The v1 worker loop is already that service, launched directly instead of inside a container.

## What we can learn from Monty

Monty is a minimal Python interpreter written in Rust. It has microsecond startup, resource limits, snapshottable interpreter state, and a standard library of about a dozen modules. The host controls its filesystem, environment and network access.

At the current moment, Monty cannot be the engine for `commons` python code execution. Its README states that support for external Python libraries is not a goal, so there is no `pandas`, no `polars`, no `matplotlib` and no `duckdb`. Monty is also still experimental.

A couple things we can learn from that project though:

- **POSIX rlimits at the boundary.** Monty treats these as table stakes. A `resource.setrlimit` call for address space and CPU in the worker's startup is cheap, and is independent of whatever sandbox lands later.
- **The driver and worker packaging split.** Monty ships as two pieces: a small client library (`pydantic-monty-client`) that the host application embeds, and a separate runtime binary that the client launches and talks to. The host never links the interpreter itself. That is the same shape as the design here: a thin driver inside commons, and a worker process it spawns and speaks JSON to. Monty's similar architecture is verification that this split is a workable way to package an execution tool.

## REPL semantics need an `ast` split

In R, the value of the last expression in a block is returned automatically, so `run_r` can tell the model to end its code with the result it wants back. Python has no equivalent: `exec` runs statements and discards expression values, so code ending in a bare `x` returns nothing and the model would have to write `print(x)` instead.

To match the R behavior, the worker will need to split the submitted code before running it. This is something Jupyter already does, and the worker should follow its pattern. IPython's `run_ast_nodes` (`IPython/core/interactiveshell.py`) parses the cell with the `ast` module, compiles every statement except the last in `exec` mode, and, when the final statement is a bare expression, compiles it in `single` mode so its value is captured (and shown in cell output) rather than discarded. The Python `commons` worker should follow the same approach, with `eval` in place of `single` mode: `exec` all but the last statement, then `eval` the trailing expression and return its value as the result.

One detail to carry over: when that value is `None`, the worker returns no result. Jupyter's displayhook suppresses `None` the same way, and without the check, code ending in a call like `df.to_csv(...)` would return a meaningless `None` on every call.

Capturing stdout and stderr during the call belongs with this. The worker and its parent communicate over stdout as line-delimited JSON, so a stray `print()` from model code would corrupt that channel. The worker therefore redirects stdout and stderr for the duration of the call and returns whatever was printed as separate output fields alongside the result.

## The open question, answered

Should sandboxed execution be its own package rather than a commons subsystem? The Inspect reading supports keeping it inside commons for now. The boundary is a single `exec`-shaped interface with five or six arguments, so a later extraction is a small piece of work. Nothing about the v1 design forecloses it, and there is no Python user base yet to justify the extra package.

## What the design takes from this

The `run_python` design is the outcome of this note:

- An `asyncio` subprocess worker on `sys.executable`, speaking line-delimited JSON, on an interpreter whose startup hooks are known: a virtual environment without system packages, or a container-managed system Python.
- REPL semantics by an `ast` split (the IPython pattern): `exec` all but the last statement, `eval` a trailing bare expression, return no result when it is `None`, and redirect stdout/stderr during the call.
- Values by copy: Arrow IPC for frames, JSON for scalars, never pickle.
- An explicit `env=` allowlist from day one, with `-I`, because inheritance is the default and `usercustomize` can undo the allowlist. Lazy spawn.
- An `asyncio.Lock` for one call at a time, and kill-and-respawn on timeout.
- rlimits in the worker startup, behind an `exec`-shaped interface.
