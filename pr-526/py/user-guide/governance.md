# Security and governance for commons agents

`commons` allows users to build and deploy agents that can run SQL queries against live databases and execute Python code that the model writes. This raises several security and governance questions: How do you make sure that an agent cannot delete production data? Can model-generated Python code interfere with a [Posit Connect](https://posit.co/products/enterprise/connect) deployment? Can an agent show users tables, rows, or business context that they shouldn't be able to see?

This page explains the boundaries that `commons` provides and the responsibilities that remain with the application author and server administrator.


# The `commons` harness

A `commons` agent is a `chatlas.Chat` object with a system prompt and a set of tools. The system prompt lists the available data sources and business context. Tools let the model retrieve more context, call a trusted calculation, run a SQL query, or run Python code.

We assume that a model might make any request allowed by its tools. Application security should therefore not depend on the model following an instruction like "never reveal sensitive data." Instead, only give an agent access to data that the current user of the application is allowed to see. The system prompt, tool arguments, and tool results are also sent to the model provider. The agent must therefore not have access to data that you [do not trust that provider to process](https://posit.co/blog/trust-llm-tools).


# SQL code execution


## Destructive actions

The agent can run one read-only statement at a time. `commons` parses each statement with [sqlglot](https://github.com/tobymao/sqlglot) and checks its structure against an allowlist of statement forms that only read, such as `SELECT` and the set operations. `commons` refuses every other form, stacked statements, and statements that `sqlglot` cannot parse, so it fails safe/closed.

For data frames and pins, which `commons` loads into its own DuckDB database, it also hardens the connection. It disables community and unsigned extensions, automatic extension install and load, external access, and the local filesystem. Then it sets `lock_configuration`, so a query cannot turn those settings back on.

These checks provide defense in depth, but they are not a database sandbox. When you supply a database connection, `commons` queries it as-is, and a statement that the parser accepts runs with all the permissions of that connection. The primary safeguard against destructive SQL is therefore database-enforced read-only access, and you should open the connection as a read-only user or role.


## Data access

The `tables` argument to [data_source()](../reference/data_source.md#commons.data_source) controls which tables `commons` describes to the model, but it is not an authorization boundary. SQL written by the agent can query any object that the connection can reach.

On Posit Connect, [viewer OAuth integrations](https://docs.posit.co/connect/admin/access-controls/) can give an interactive application the current viewer's Snowflake or Databricks credentials. If the application creates its engine from those credentials, the warehouse continues to enforce that viewer's existing access policies, including row-level and column-level security.

For a Snowflake or Databricks source, `commons` snapshots the connection's principal and namespace when it creates a Snowflake or Databricks data source, and its active and secondary roles as well on Snowflake, and rejects subsequent operations if that identity changes.

Viewer credentials are not automatic. `commons` uses the engine that the application supplies. When using viewer credentials, you should create the engine and the `commons` agent inside the Shiny server function so that each session has the correct database identity.

When viewer credentials are not available, it is recommended to use a service account with access only to the data that the application needs. Every viewer then has the same database permissions, so share the application only with users who are allowed that access.


# Python code execution

Python code written by the agent does not run in the main application process. Each `commons` agent instead gets a persistent Python subprocess, created on first use. Its state remains available to later Python analysis by the same agent until the subprocess is closed or restarted.


## OS-level sandboxing

On Linux (which underlies [Posit Connect](https://posit.co/products/enterprise/connect)), `commons` combines a filesystem sandbox with seccomp system-call filters. It uses Landlock when the kernel supports it and otherwise falls back to unprivileged user and mount namespaces. If neither filesystem mechanism is available, or if seccomp is unavailable, `commons` refuses to create an agent.

The filesystem sandbox gives the subprocess read access to Python, installed packages, and required operating-system directories. It can write only to a temporary directory used by the subprocess. The seccomp filters prevent it from inspecting another process's memory or changing mount and namespace configuration. The Linux sandbox also caps the subprocess's virtual address space at 8 GiB; a lower limit inherited from Connect still applies.

By default, the subprocess cannot create network sockets. An application author can opt in to network access with `Commons(network="full")`; the filesystem sandbox remains in place, but Python code can then contact services reachable from the deployment, send out the data that earlier queries and measures returned, and install packages with pip into its temporary directory. Only enable network access when that egress is required and acceptable.

For local development on macOS, `commons` applies a similar filesystem and network policy using Seatbelt. Windows has no OS-level sandbox for the agent's Python session. Deployed Connect applications run on Linux and use the Linux mechanisms described above.

By default, `commons` refuses to create an agent when an OS-level sandbox is not available. An application author can enable a local-development fallback explicitly by setting an environment variable:

``` bash
export COMMONS_ALLOW_UNSAFE_FALLBACK=1
```

`commons` always uses OS-level sandboxing when it is available. This variable cannot disable or bypass it; it only permits `commons` to fall back to best-effort Python guardrails when no OS-level sandbox is available.

The fallback checks file, process, and network operations while code evaluates in the agent's Python session. It limits filesystem reads to the directories the sandbox allows, limits writes to the temporary directory, denies starting other processes, and follows the requested network policy. These checks reduce accidental access and damage, but native code and other Python mechanisms can bypass them. They are not a sandbox or security boundary and should not be enabled in a deployment.


## Communication with the main app process

The subprocess starts with a small allowlist of environment variables rather than inheriting the application's complete environment. In particular, API keys, session tokens, and database URLs are not inherited. The subprocess also runs in Python's isolated mode, which ignores `PYTHON*` environment variables and the user's site directory to further isolate the subprocess from the host environment.

Communication happens through pipes between the two processes. `commons` copies the results of earlier queries and measures, and the source code of each measure, into the subprocess, then receives captured output and plots in return. Function objects and database connections are not transferred. A measure whose source cannot be defined in the subprocess is skipped.


# Permissioning facts

The rows returned by SQL are not the only sensitive information available to an agent. The description and details of each data dictionary, and its glossary entries up to a size cap, go into the system prompt. The full dictionary entry for a table goes to the model when a table is first described or queried. Context documents and the rest of the dictionary prose are available to the model through search.

Because of this, you should only include facts that you can share with both the application's viewers and its model provider. If one audience must not see a fact, use separate applications with separate context, or put the facts behind viewer credentials. Asking the model to hide the fact from that audience is not a reliable means of preventing unauthorized access to the information.


# Logging conversations

Conversation logging is off by default. With `Commons(log=True)`, `commons` turns on message content capture in the OpenTelemetry spans that chatlas records. These spans can contain user messages, model responses, tool requests, and tool results, including query results and plots. Treat them as another copy of the data available to the agent. An agent built with `log=True` in a process that is tracing, with content capture not turned off at that time, also records the signed-in user's name on each turn, when the Shiny session has one. It also gives the conversation an id when the application sets none, so that the turns of one conversation can be grouped. An id the application sets is recorded whenever the process is tracing, whether or not the agent logs.

Capture is controlled for the whole process by the `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT` environment variable, and the agent's `log` argument only sets it when nothing else has. Once the variable is on, whether `log=True` or the environment turned it on, chatlas records the conversations of every agent in a traced process, including agents built with `log=False`. The variable is on when it is `true` or `1`, in any case. Any other non-empty value turns capture off, and `log=True` leaves that value alone. An empty value counts as unset.

On Posit Connect, both the server administrator and the application author must opt in before any conversation is recorded. The administrator must enable OpenTelemetry and allow content instrumentation. The author opts in by passing `log=True`, or by setting the capture variable. With `log=True`, `commons` also turns on [Content Observability](https://docs.posit.co/connect/user/content-settings/#content-observability) for the content item when the process started without tracing. Recording then begins after the content process restarts. A process that already has tracing records from the first conversation, unless content capture is turned off. Off Connect, nothing is recorded unless the application installs a tracer provider, and the spans then go wherever that provider exports them. See [Logging conversations](get-started.md#logging-conversations) for the setup.

Content owners and collaborators can read the traces on Connect, for example with the R package's `trajectory_read()`. `share_with` adds the named users as collaborators, which gives them more than access to the traces. Store any exported transcripts and review notes only in an appropriately protected location, and review traces only in an environment trusted to handle internal user data, such as [Posit Workbench](https://posit.co/products/enterprise/workbench). Connect or the configured exporter decides retention and access for the OpenTelemetry data, not `commons`.
