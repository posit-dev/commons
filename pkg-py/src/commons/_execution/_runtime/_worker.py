"""The worker process's entry point: sandbox itself, then answer calls.

Launched by the driver as ``python -I -u _worker.py NETWORK PROTECTION`` with
its working directory set to a scratch directory and its environment reduced
to an allowlist. Nothing here may import ``commons``: this process runs
model-written code and is deliberately kept free of the agent's dependencies.
The sibling runtime modules and ``_protocol`` (one directory up) are imported
by path.

The protocol channel is claimed at the file-descriptor level before anything
else happens: duplicates of fds 0 and 1 become the channel, and the
model-visible fds are pointed at sinks. Model code that writes straight to
fd 1 — ``os.write``, a C extension, a thread still printing after its call
returned — goes to the sink rather than mid-message on the channel, and a
thread reading fd 0 gets EOF rather than the next call's bytes. The
sys-level redirection in ``_repl`` cannot close those holes; these are
closed by construction, for the process's whole life.

fd 2 stays attached until the sandbox is engaged and the ready announcement
is sent, so a startup failure can still reach the driver's diagnostics. Model
code never runs before then.
"""

from __future__ import annotations

import os
import sys

# The channel takeover runs before any import that could print, and before
# the sandbox, which needs the protocol fds preserved across its fd sweep.
_PROTOCOL_IN = -1
_PROTOCOL_OUT = -1


def _claim_protocol_channel() -> tuple[int, int]:
    """Dup fds 0 and 1 for the protocol and point the model-visible ones at sinks."""
    protocol_in = os.dup(0)
    protocol_out = os.dup(1)
    source = os.open(os.devnull, os.O_RDONLY)
    os.dup2(source, 0)
    if source > 2:
        os.close(source)
    sink = os.open(os.devnull, os.O_WRONLY)
    os.dup2(sink, 1)
    if sink > 2:
        os.close(sink)
    return protocol_in, protocol_out


def _silence_stderr() -> None:
    """Point fd 2 at fd 1's sink, once startup diagnostics no longer need it.

    A dup rather than a fresh ``/dev/null`` open: on Linux this runs after
    the sandbox engaged, and ``/dev`` is outside its roots.
    """
    os.dup2(1, 2)


# Isolated mode leaves even this script's own directory off the path, so
# both it (for the sibling runtime modules) and its parent (for the
# protocol, which lives next to the driver) are added by hand.
_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(_HERE))
sys.path.insert(0, _HERE)

# Imported by bare name from directories put on sys.path at runtime, which
# static analysis cannot follow.
import _limits  # pyrefly: ignore[missing-import]
import _protocol  # pyrefly: ignore[missing-import]
import _repl  # pyrefly: ignore[missing-import]


def _sandbox_roots() -> tuple[list[str], list[str]]:
    """The read and write roots the sandbox is engaged with.

    The read roots cover the interpreter, its standard library, and every
    directory on the import path, plus the operating-system roots a
    process cannot start up without. The write root is the scratch
    directory alone, which is the working directory the driver launched
    this process into. Sandboxes match symlink-free paths, so each root's
    resolved spelling is granted alongside the original.
    """
    roots = [sys.prefix, sys.base_prefix, sys.exec_prefix]
    roots.extend(path for path in sys.path if path)
    if sys.platform == "darwin":
        roots.extend(
            [
                "/usr",
                "/bin",
                "/sbin",
                "/System",
                "/Library",
                "/private/etc",
                "/private/var/db",
                "/opt",
                "/dev",
            ]
        )
    else:
        roots.extend(["/usr", "/bin", "/sbin", "/lib", "/lib64", "/etc", "/opt"])
    read_roots = []
    for root in roots:
        for spelling in (root, os.path.realpath(root)):
            if os.path.isdir(spelling) and spelling not in read_roots:
                read_roots.append(spelling)
    scratch = os.getcwd()
    write_roots = list(dict.fromkeys((scratch, os.path.realpath(scratch))))
    return read_roots, write_roots


def _engage_sandbox(network: str, protection: str) -> None:
    """Restrict this process, permanently, before any model-written code runs.

    Guardrails mode engages no sandbox: it exists so a host commons cannot
    protect can still run, and it provides no security boundary. The
    address-space cap applies in both modes — it is a plain rlimit guarding
    the host from a runaway allocation, not part of the boundary. The order
    below is fixed by the mechanisms themselves: the user-namespace
    fallback must precede the seccomp filter that would screen its mount
    and unshare calls, and the filter goes last because nothing may widen
    access after it.
    """
    _limits.apply_address_space_limit()
    if protection == "guardrails":
        return
    read_roots, write_roots = _sandbox_roots()
    if sys.platform == "darwin":
        import _seatbelt  # pyrefly: ignore[missing-import]

        _seatbelt.engage_seatbelt(read_roots, write_roots, network=network)
        return
    import _landlock  # pyrefly: ignore[missing-import]
    import _seccomp  # pyrefly: ignore[missing-import]
    import _userns  # pyrefly: ignore[missing-import]

    if _landlock.engage(read_roots, write_roots) is None:
        _userns.engage(
            read_roots,
            write_roots,
            preserve_fds=[0, 1, 2, _PROTOCOL_IN, _PROTOCOL_OUT],
        )
    _seccomp.engage(network=network)


def _send(message: _protocol.Message) -> None:
    """Write ``message`` to the protocol channel, whole.

    A half-written line poisons the channel, so a write interrupted by a
    signal — the driver's SIGINT included — is retried until the line is
    out. The call the interrupt was meant for has already finished by the
    time its reply is being sent.
    """
    view = memoryview(_protocol.encode_message(message))
    while view:
        try:
            written = os.write(_PROTOCOL_OUT, view)
        except (InterruptedError, KeyboardInterrupt):
            continue
        view = view[written:]


# Seeded into the session namespace at startup. Harvested measure sources
# are reference material: they come without their module's imports and
# globals, and a default argument naming one (``def m(region=DEFAULT)``)
# would otherwise fail the define — and with it the spawn — where R's lazy
# defaults define fine. Each default expression is therefore evaluated
# behind a guard, and one that references anything missing becomes a
# placeholder naming the expression's source; only a call that actually
# uses the default meets the placeholder.
_DEFINE_SOURCE = '''
import ast as _ast


class _CommonsMissing:
    """Stand-in for a default whose ingredients the harvest did not include."""

    def __init__(self, what):
        self._what = what

    def __repr__(self):
        return f"<{self._what}: not defined in this session>"

    def __getattr__(self, attr):
        if attr.startswith("__"):
            raise AttributeError(attr)
        return self

    def __call__(self, *args, **kwargs):
        return self

    def __getitem__(self, key):
        return self


def _commons_default(thunk, what):
    try:
        return thunk()
    except Exception:
        return _CommonsMissing(what)


def _commons_define_source(source):
    import __future__

    def guard(default):
        segment = _ast.get_source_segment(source, default) or "default"
        return _ast.Call(
            func=_ast.Name(id="_commons_default", ctx=_ast.Load()),
            args=[
                _ast.Lambda(
                    args=_ast.arguments(
                        posonlyargs=[],
                        args=[],
                        kwonlyargs=[],
                        kw_defaults=[],
                        defaults=[],
                    ),
                    body=default,
                ),
                _ast.Constant(value=segment),
            ],
            keywords=[],
        )

    tree = _ast.parse(source)
    for node in tree.body:
        if not isinstance(node, (_ast.FunctionDef, _ast.AsyncFunctionDef)):
            continue
        # Each default keeps its slot; only its evaluation is guarded.
        node.args.defaults = [guard(d) for d in node.args.defaults]
        node.args.kw_defaults = [
            guard(d) if d is not None else None for d in node.args.kw_defaults
        ]
    _ast.fix_missing_locations(tree)
    code = compile(
        tree,
        "<measure-source>",
        "exec",
        flags=__future__.annotations.compiler_flag,
        dont_inherit=True,
    )
    exec(code, globals())
'''


def _execute(call: _protocol.Call, namespace: dict) -> _protocol.Message:
    """Run one call in the session namespace and render its reply."""
    namespace.update(call.handles)
    try:
        evaluation = _repl.run(call.code, namespace)
    except KeyboardInterrupt:
        # The driver's SIGINT broke the call out of its computation. The
        # session and its variables survive; the driver reports the
        # interrupt in its own words.
        return _protocol.Error(id=call.id, message="KeyboardInterrupt")
    if evaluation.error:
        return _protocol.Error(
            id=call.id, message=evaluation.error, traceback=evaluation.traceback
        )
    return _protocol.Result(
        id=call.id,
        value=evaluation.value,
        stdout=evaluation.stdout,
        stderr=evaluation.stderr,
    )


def main() -> None:
    network, protection = sys.argv[1], sys.argv[2]
    _engage_sandbox(network, protection)
    _send(_protocol.Ready())
    _silence_stderr()

    # The namespace is the session: the same mapping on every call, so a
    # name one call binds is visible to the next.
    namespace: dict = {"__name__": "__main__"}
    exec(compile(_DEFINE_SOURCE, "<worker>", "exec"), namespace)  # noqa: S102
    calls = os.fdopen(_PROTOCOL_IN, "rb")
    while True:
        try:
            line = calls.readline()
        except KeyboardInterrupt:
            # A SIGINT that landed between calls; there is nothing in
            # flight to abort, so go back to listening.
            continue
        if not line:
            return  # The driver is gone, and with it the reason to be here.
        try:
            message = _protocol.decode_message(line)
        except _protocol.ChannelError:
            return  # No later line can be trusted; the driver starts over.
        except _protocol.ProtocolError:
            continue  # One bad line costs the line, not the session.
        if not isinstance(message, _protocol.Call):
            # The driver only ever sends calls; anything else means the two
            # sides disagree about the protocol, and the channel is done.
            return
        _send(_execute(message, namespace))


if __name__ == "__main__":
    _PROTOCOL_IN, _PROTOCOL_OUT = _claim_protocol_channel()
    main()
