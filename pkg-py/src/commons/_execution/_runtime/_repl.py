"""REPL evaluation semantics for the worker: the ``ast`` split, output capture, ``None`` suppression.

``exec`` discards expression values, so running model-written code verbatim
would return nothing for a call ending in a bare ``x`` — the model would have
to learn to write ``print(x)`` instead, and to read its answer out of the
captured output. R's ``run_r`` owes the model no such concession, because a
block there evaluates to its last expression. This module gives the worker
the same shape, following IPython's ``run_ast_nodes``: parse the submission,
``exec`` every statement but the last, and ``eval`` a trailing bare
expression so its value becomes the result.

Two details carry over from Jupyter:

- A result of ``None`` is no result. Jupyter's displayhook suppresses it the
  same way; without the check, code ending in a call like ``df.to_csv(...)``
  would hand the model a meaningless ``None`` on every call.
- stdout and stderr are captured for the duration of the call and returned
  alongside the result. The worker's protocol with its parent shares the
  process's stdout, so a ``print()`` from model code would corrupt the
  channel if it ran against the real one.
"""

from __future__ import annotations
import __future__

import ast
import contextlib
import sys
import traceback
from dataclasses import dataclass
from typing import Any

__all__ = ["Evaluation", "run"]

# The filename tracebacks give a frame of model-written code, named for the
# tool the model knows it is calling.
_FILENAME = "<run_python>"

# The most output a call may hold. An unbounded buffer would let a runaway
# print loop exhaust the worker's memory before the protocol ever gets to
# clip the reply, so the capture stops at the size the protocol clips to
# (``_TEXT_CLIP_LIMIT`` in ``commons._execution._protocol``), note included,
# which keeps the field short enough that the protocol never clips it a
# second time. The note's wording matches the protocol's, so the model sees
# one message whichever layer did the truncating.
_CAPTURE_LIMIT = 1024 * 1024
_TRUNCATION_NOTE = "\n[truncated by commons: the output exceeded the channel limit]"


# The features a `from __future__ import ...` can enable, for carrying their
# compiler flags across calls the way codeop.CommandCompiler does.
_FEATURES = [getattr(__future__, name) for name in __future__.all_feature_names]
_FUTURE_MASK = 0
for _feature in _FEATURES:
    _FUTURE_MASK |= _feature.compiler_flag

# Where the session's accumulated __future__ compiler flags live. A REPL
# applies a future import to every later submission, so the flags are session
# state; the namespace is the session, and a dunder key keeps the flag word
# out of the model's way while staying visible to introspection, as any name
# the model itself bound would be.
_FLAGS_KEY = "__commons_future_flags__"


class _BoundedCapture:
    """An append-only, bounded stand-in for ``sys.stdout`` during a call.

    The buffer is wrapped, not subclassed, so model code cannot reach an
    unbounded method through a base class (``io.StringIO.write(sys.stdout,
    ...)``), and there is no ``seek``: a real pipe is not seekable either,
    and a cursor cannot be used to allocate a gap the next write would fill.

    Writes past the limit are accepted and discarded, so ``print()`` never
    sees a failure; the buffer keeps its truncated contents with a note
    saying what happened. ``close()`` is a no-op — the worker reads the
    buffer back after the call, which a closed stream would forbid — so
    model code asking to close its stdout changes nothing.

    The accounting trusts nothing the caller can influence, so the bound
    applies whether the flood is accidental or deliberate: a runaway print
    loop and a ``write`` that lies about its length end at the same limit.
    What the class does not guard against is model code allocating memory
    directly; the worker's rlimits are the answer to that.
    """

    encoding = "utf-8"

    def __init__(self) -> None:
        # A list of chunks, not a StringIO: nothing reachable from the
        # stream offers an unbounded write method.
        self._chunks: list[str] = []
        self._size = 0
        self._truncated = False

    @property
    def closed(self) -> bool:
        return False

    def close(self) -> None:
        # Not closed: see the class docstring.
        pass

    def flush(self) -> None:
        pass

    def isatty(self) -> bool:
        return False

    def writelines(self, lines: Any) -> None:
        for line in lines:
            self.write(line)

    def write(self, text: str) -> int:
        if type(text) is not str:
            if not isinstance(text, str):
                raise TypeError(
                    f"write() argument must be str, not {type(text).__name__}"
                )
            # The accounting below trusts len(text), and a subclass's
            # __len__ may lie. The base-class getitem copies the true
            # contents into an exact str; a plain slice would dispatch the
            # subclass's own __getitem__, which may return self.
            text = str.__getitem__(text, slice(None))
        if not text:
            # An empty write still appends a chunk; enough of them would
            # grow the chunk list without ever touching _size.
            return 0
        if self._truncated:
            return len(text)
        # The capacity check comes before the write, so an oversized write
        # is sliced rather than buffered whole first; the copy the slice
        # makes is bounded by what still fits.
        room = _CAPTURE_LIMIT - len(_TRUNCATION_NOTE) - self._size
        if room >= len(text):
            self._chunks.append(text)
            self._size += len(text)
            return len(text)
        if room > 0:
            self._chunks.append(text[:room])
        self._chunks.append(_TRUNCATION_NOTE)
        self._size = _CAPTURE_LIMIT
        self._truncated = True
        return len(text)

    def getvalue(self) -> str:
        """The captured output; the worker's read-back after the call."""
        return "".join(self._chunks)


@dataclass(frozen=True, kw_only=True)
class Evaluation:
    """The outcome of one call: what it evaluated to, what it printed, and how it failed.

    ``value`` is ``None`` both when the code ended in a statement and when it
    ended in an expression that evaluated to ``None``. The two are equivalent
    to the model, which is why the REPL suppresses a ``None`` result.

    ``error`` and ``traceback`` are empty when the call succeeded. On a
    failure ``stdout`` and ``stderr`` still carry whatever was printed before
    the exception; whether the protocol relays them is the worker loop's
    decision, not this module's.
    """

    value: Any = None
    stdout: str = ""
    stderr: str = ""
    error: str = ""
    traceback: str = ""


def run(code: str, namespace: dict[str, Any] | None = None) -> Evaluation:
    """Run ``code`` in ``namespace`` the way a REPL would, and report the outcome.

    The namespace is the session: the worker passes the same mapping on every
    call, so a name bound by one call is visible to the next. It serves as
    both globals and locals, which is what makes a name bound at the top
    level of one submission readable by the trailing expression of the next.

    A raised exception is the call's answer, not the worker's: it comes back
    in the returned ``Evaluation`` as ``error`` and ``traceback``. Two
    exceptions escape. ``KeyboardInterrupt`` propagates so the driver's
    interrupt escalation can break a call out of a long computation; catching
    it here would report a cancelled call as an ordinary failure and keep the
    computation's killer waiting. ``GeneratorExit`` and friends go with it.
    ``SystemExit`` is caught, by contrast, because model code calling
    ``sys.exit()`` must not take the worker process with it.

    The capture is at the ``sys`` level, ``__stdout__`` and ``__stderr__``
    included, so the well-known names for the real streams are covered too.
    Code that writes to file descriptor 1 directly, or through a reference
    saved before the call, still reaches the real stream; closing that is
    the worker loop's affair, since only it owns the channel the stream
    carries.
    """
    if namespace is None:
        namespace = {}
    stdout = _BoundedCapture()
    stderr = _BoundedCapture()
    value: Any = None
    error = ""
    tb = ""
    real_dunder = sys.__stdout__, sys.__stderr__
    with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
        try:
            # The dunder streams are typed TextIOWrapper | None, but anything
            # file-like serves; the captures are exactly what redirect_stdout
            # accepts above. The swap sits inside the try so an interrupt
            # landing mid-entry cannot leave the dunders bound to the
            # captures after the call.
            sys.__stdout__, sys.__stderr__ = stdout, stderr  # type: ignore[bad-assignment]
            value = _evaluate(code, namespace)
        except (Exception, SystemExit) as exc:  # noqa: BLE001 - any failure is the call's answer
            error, tb = _render_error(exc)
        finally:
            sys.__stdout__, sys.__stderr__ = real_dunder
    # The model held sys.stdout during the call, capture object included,
    # so the read-back cannot assume the object survived intact. A
    # sabotaged capture costs the call its output, never its answer. Unlike
    # _render_error's catch, this one excludes KeyboardInterrupt and
    # GeneratorExit: an interrupt arriving after a finished call means the
    # same as one arriving mid-call.
    try:
        captured_out = stdout.getvalue()
        captured_err = stderr.getvalue()
    except (Exception, SystemExit):  # noqa: BLE001 - lost output is not a lost answer
        captured_out, captured_err = "", ""
    return Evaluation(
        value=value,
        stdout=captured_out,
        stderr=captured_err,
        error=error,
        traceback=tb,
    )


def _render_error(exc: BaseException) -> tuple[str, str]:
    """The ``(message, traceback)`` pair for a caught exception, rendered safely.

    The exception is model-written code's object: its ``__str__`` may itself
    raise, and formatting the traceback asks it for the same text. A failure
    there degrades the rendering, never the report — the call still gets its
    answer, with the type name standing in for the message.

    The catches span ``BaseException``, ``KeyboardInterrupt`` included,
    unlike ``run`` itself. By the time rendering begins the call has already
    failed and no computation is left in flight, so an interrupt arriving in
    this window has nothing to stop; letting a ``__str__`` that raises
    ``KeyboardInterrupt`` escape would instead masquerade an ordinary
    failure as an interrupt.
    """
    try:
        # A metaclass can turn even __name__ into a raising property, so
        # the type name comes from inside the guard too.
        name = str(type(exc).__name__)
    except BaseException:  # noqa: BLE001 - the fallback is a fixed name
        name = "Exception"
    try:
        message = f"{name}: {exc}"
    except BaseException:  # noqa: BLE001 - the fallback is the type name alone
        message = f"{name} (its str() raised)"
    try:
        tb = "".join(traceback.format_exception(exc))
    except BaseException:  # noqa: BLE001 - a missing traceback is not a lost answer
        tb = ""
    return message, tb


def _evaluate(code: str, namespace: dict[str, Any]) -> Any:
    """The value ``code`` evaluates to in ``namespace``, or ``None`` for no result.

    A ``SyntaxError`` raised by the parse is deliberately not caught here: it
    is the call's answer the same way a runtime exception is, and ``run``
    reports both through the same path.
    """
    # `dont_inherit=True` on every compile below: without it the compiles
    # would inherit this module's own `from __future__ import annotations`,
    # and the session's flags would stop being the model's to choose.
    flags = namespace.get(_FLAGS_KEY, 0)
    if type(flags) is not int:
        # The key is the session's, but the namespace is the model's; a
        # clobbered flag word resets the flags rather than failing the call.
        # An exact int, not isinstance: an int subclass could overload the
        # masking below to smuggle a non-future bit through it.
        flags = 0
    # Only __future__ bits may pass: the model can write the key, and a
    # word carrying another compiler flag (PyCF_ONLY_AST, say) would poison
    # every later compile rather than enable a feature.
    flags &= _FUTURE_MASK
    # The parse takes the session's flags too, because a future feature can
    # change the grammar (`barry_as_FLUFL` restores `<>`), which the parser
    # needs to know before there is a tree at all.
    tree = compile(
        code, _FILENAME, "exec", flags=flags | ast.PyCF_ONLY_AST, dont_inherit=True
    )
    body = tree.body
    if not body:
        return None
    last = body[-1]
    if not isinstance(last, ast.Expr):
        # The code ends in a statement, so there is no value to return;
        # running the tree whole keeps its type_ignores (type: ignore
        # comments) in force for the compile.
        module = compile(tree, _FILENAME, "exec", flags=flags, dont_inherit=True)
        # The flags are folded in before the exec, not after: the compiler
        # has already honored the future import, so a submission that then
        # fails at runtime still changes later submissions, as in a REPL.
        _remember_future_flags(namespace, flags, module)
        exec(module, namespace)  # noqa: S102
        return None
    if len(body) > 1:
        prefix = ast.Module(body=body[:-1], type_ignores=tree.type_ignores)
        module = compile(prefix, _FILENAME, "exec", flags=flags, dont_inherit=True)
        flags = _remember_future_flags(namespace, flags, module)
        exec(module, namespace)  # noqa: S102
    expression = compile(
        ast.Expression(last.value), _FILENAME, "eval", flags=flags, dont_inherit=True
    )
    return eval(expression, namespace)


def _remember_future_flags(namespace: dict[str, Any], flags: int, module: Any) -> int:
    """Fold a compiled module's ``__future__`` flags into the session's, and return them.

    A compiled module's ``co_flags`` carries the bits for every future
    statement the source made, so accumulating from it (rather than scanning
    the tree for imports) picks up exactly what the compiler honored.
    """
    for feature in _FEATURES:
        if module.co_flags & feature.compiler_flag:
            flags |= feature.compiler_flag
    namespace[_FLAGS_KEY] = flags
    return flags
