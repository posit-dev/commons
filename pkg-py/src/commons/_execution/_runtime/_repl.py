"""REPL evaluation semantics for the worker: the ``ast`` split, output capture, ``None`` suppression.

``exec`` discards expression values, so model code ending in a bare ``x``
would return nothing and the model would have to ``print(x)`` instead. R's
``run_r`` returns a block's last value, and this module gives the worker the
same shape, following IPython's ``run_ast_nodes``: parse the submission,
``exec`` every statement but the last, and ``eval`` a trailing bare
expression so its value becomes the result.

Two details come from Jupyter:

- A result of ``None`` is no result, as in Jupyter's displayhook, so code
  ending in a call like ``df.to_csv(...)`` returns nothing.
- stdout and stderr are captured for the duration of the call. The worker's
  protocol with its parent uses the process's stdout, so a ``print()`` from
  model code would corrupt the channel.

Both streams are captured into one ``Transcript``, which keeps their writes
in order, so the reply can show a warning between the two prints it came
between. The worker inserts plots into the same transcript.
"""

from __future__ import annotations
import __future__

import ast
import contextlib
import io
import sys
import traceback
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

__all__ = ["Evaluation", "Transcript", "run"]

# The filename tracebacks show for a frame of model-written code, named for
# the tool the model calls.
_FILENAME = "<run_python>"

# The most output one stream may keep, note included, so a runaway print loop
# cannot exhaust the worker's memory. Both values equal their counterparts in
# `commons._execution._protocol`, so text this capture keeps is not clipped
# again there, and the model sees the same note either way.
_CAPTURE_LIMIT = 1024 * 1024
_TRUNCATION_NOTE = "\n[truncated by commons: the output exceeded the channel limit]"

# The most text segments one call's output may have. A new segment starts
# when the output switches streams or follows a plot, so this is reached
# only by output that alternates thousands of times. `commons._execution._protocol.OUTPUT_LIMIT`
# leaves room past it for plots and the worker's notes.
_SEGMENT_LIMIT = 9_000
_SEGMENT_NOTE = "\n[truncated by commons: the output switched streams too often]"

# The compiler flags a `from __future__ import ...` can set, which persist
# across calls as they do in codeop.CommandCompiler.
_FEATURES = [getattr(__future__, name) for name in __future__.all_feature_names]
_FUTURE_MASK = 0
for _feature in _FEATURES:
    _FUTURE_MASK |= _feature.compiler_flag

# The namespace key for the session's accumulated __future__ flags.
_FLAGS_KEY = "__commons_future_flags__"


class Transcript:
    """A call's output in order: runs of text tagged by stream, and inserted items.

    Consecutive writes to one stream join into one run. Each stream keeps at
    most ``_CAPTURE_LIMIT`` characters, note included, so a runaway print
    loop cannot exhaust the worker's memory; writes past it succeed and are
    discarded, and the stream's text ends with a truncation note. Memory
    that model code allocates directly is bounded by the worker's rlimits.

    ``insert`` places an item (a plot) between the runs, and ``note`` adds
    the worker's own text without applying either bound, so a note is never
    lost.
    """

    def __init__(self) -> None:
        # Each entry is [stream, chunks] for a run of text, or ["item", item].
        self._entries: list[list[Any]] = []
        self._sizes = {"stdout": 0, "stderr": 0}
        self._truncated: set[str] = set()
        self._segments = 0
        self._full = False

    def write(self, stream: str, text: str) -> None:
        """Record ``text`` written to ``stream``, within the stream's bound."""
        if not text or stream in self._truncated or self._full:
            return
        room = _CAPTURE_LIMIT - len(_TRUNCATION_NOTE) - self._sizes[stream]
        if room >= len(text):
            self._append(stream, text)
            self._sizes[stream] += len(text)
            return
        if room > 0:
            self._append(stream, text[:room])
        self._append(stream, _TRUNCATION_NOTE)
        self._sizes[stream] = _CAPTURE_LIMIT
        self._truncated.add(stream)

    def note(self, stream: str, text: str) -> None:
        """Record the worker's own ``text`` on ``stream``, without applying the bounds."""
        self._append(stream, text, bounded=False)

    def insert(self, item: Any) -> None:
        """Place ``item`` after everything recorded so far."""
        self._entries.append(["item", item])

    def entries(self) -> tuple[tuple[str, Any], ...]:
        """The output in order: ``(stream, text)`` runs and ``("item", item)``."""
        return tuple(
            (kind, body if kind == "item" else "".join(body))
            for kind, body in self._entries
        )

    def _append(self, stream: str, text: str, *, bounded: bool = True) -> None:
        last = self._entries[-1] if self._entries else None
        if last is not None and last[0] == stream:
            last[1].append(text)
            return
        if bounded and self._segments >= _SEGMENT_LIMIT:
            if not self._full:
                self._entries.append([stream, [_SEGMENT_NOTE]])
                self._full = True
            return
        self._entries.append([stream, [text]])
        self._segments += 1


class _StreamView:
    """An append-only stand-in for ``sys.stdout`` or ``sys.stderr`` during a call.

    Writes go to the call's ``Transcript``, tagged with this view's stream.
    The class subclasses no stream type, so no base-class method
    (``io.StringIO.write(sys.stdout, ...)``) can write around the
    transcript's bound. It has no ``seek``, as a pipe has none.

    ``close()`` does nothing, because the worker reads the transcript after
    the call. ``fileno()`` raises ``io.UnsupportedOperation``, as
    ``io.StringIO`` and ipykernel's stream do, so libraries that probe for a
    descriptor fall back cleanly.
    """

    encoding = "utf-8"
    errors = "strict"

    def __init__(self, transcript: Transcript, stream: str) -> None:
        self._transcript = transcript
        self._stream = stream

    @property
    def closed(self) -> bool:
        return False

    def close(self) -> None:
        pass

    def flush(self) -> None:
        pass

    def isatty(self) -> bool:
        return False

    def fileno(self) -> int:
        raise io.UnsupportedOperation("fileno")

    def readable(self) -> bool:
        return False

    def seekable(self) -> bool:
        return False

    def writable(self) -> bool:
        return True

    def writelines(self, lines: Any) -> None:
        for line in lines:
            self.write(line)

    def write(self, text: str) -> int:
        if type(text) is not str:
            if not isinstance(text, str):
                raise TypeError(
                    f"write() argument must be str, not {type(text).__name__}"
                )
            # A subclass's __len__ may lie. The base-class getitem copies the
            # true contents into an exact str, where a plain slice would call
            # the subclass's own __getitem__.
            text = str.__getitem__(text, slice(None))
        self._transcript.write(self._stream, text)
        return len(text)


@dataclass(frozen=True, kw_only=True)
class Evaluation:
    """The outcome of one call: what it evaluated to, what it output, and how it failed.

    ``value`` is ``None`` both when the code ended in a statement and when it
    ended in an expression that evaluated to ``None``; the model sees no
    difference between the two.

    ``output`` is the transcript's entries (see ``Transcript.entries``).
    ``error`` and ``traceback`` are empty when the call succeeded. On a
    failure, ``output`` is what was written before the exception.
    """

    value: Any = None
    output: tuple[tuple[str, Any], ...] = ()
    error: str = ""
    traceback: str = ""


def run(
    code: str,
    namespace: dict[str, Any] | None = None,
    transcript: Transcript | None = None,
    after: Callable[[], object] | None = None,
) -> Evaluation:
    """Run ``code`` in ``namespace`` the way a REPL would, and report the outcome.

    The namespace is the session: the worker passes the same mapping on every
    call, and it serves as both globals and locals, so a name bound by one
    call is visible to the next.

    Any exception model code raises, ``SystemExit`` and
    ``asyncio.CancelledError`` included, comes back as ``error`` and
    ``traceback``. Only ``KeyboardInterrupt`` propagates, so that the
    driver's interrupt escalation can stop a long computation.

    The capture replaces ``sys.stdout``, ``sys.stderr``, and their
    ``__stdout__``/``__stderr__`` names with views onto ``transcript``,
    which the caller passes when it will insert items of its own (such as
    plots) into the output. Writes
    to file descriptor 1, or through a stream reference saved before the
    call, still reach the real stream; the worker loop owns that channel and
    guards it.

    ``after`` runs once the code has finished, whether or not it raised,
    while output is still captured. The worker uses it to add the figures
    the code left open, so anything printed while they are drawn is kept.
    Any exception from it other than ``KeyboardInterrupt`` propagates, so
    the caller should pass a function that does not raise.
    """
    if namespace is None:
        namespace = {}
    if transcript is None:
        transcript = Transcript()
    # Bound before model code runs, which can reach the transcript through
    # the views and replace its methods.
    read_back = transcript.entries
    stdout = _StreamView(transcript, "stdout")
    stderr = _StreamView(transcript, "stderr")
    value: Any = None
    error = ""
    tb = ""
    real_dunder = sys.__stdout__, sys.__stderr__
    with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
        try:
            # Inside the try, so an interrupt mid-swap still restores them.
            sys.__stdout__, sys.__stderr__ = stdout, stderr  # type: ignore[bad-assignment]
            try:
                value = _evaluate(code, namespace)
            except KeyboardInterrupt:
                raise
            except BaseException as exc:  # noqa: BLE001 - any failure is the call's answer
                error, tb = _render_error(exc)
            if after is not None:
                after()
        finally:
            sys.__stdout__, sys.__stderr__ = real_dunder
    # Model code had access to the transcript, so the read-back may fail;
    # that loses the output and keeps the answer.
    try:
        output = read_back()
    except KeyboardInterrupt:
        raise
    except BaseException:  # noqa: BLE001 - lost output is not a lost answer
        output = ()
    return Evaluation(value=value, output=output, error=error, traceback=tb)


def _render_error(exc: BaseException) -> tuple[str, str]:
    """The ``(message, traceback)`` pair for a caught exception, rendered safely.

    Model code defines the exception, so its ``__str__`` or even its type's
    ``__name__`` may raise. Each step falls back to a fixed text on any
    failure, ``KeyboardInterrupt`` included: the call has already failed, so
    an interrupt here has no computation to stop.

    The traceback starts at the first frame of model code, which leaves out
    this module's own frames. A ``SyntaxError`` from the parse has no such
    frame and renders as the error alone.
    """
    try:
        name = str(type(exc).__name__)
    except BaseException:  # noqa: BLE001 - the fallback is a fixed name
        name = "Exception"
    try:
        message = f"{name}: {exc}"
    except BaseException:  # noqa: BLE001 - the fallback is the type name alone
        message = f"{name} (its str() raised)"
    try:
        frames = exc.__traceback__
        while frames is not None and frames.tb_frame.f_code.co_filename != _FILENAME:
            frames = frames.tb_next
        tb = "".join(traceback.format_exception(type(exc), exc, frames))
    except BaseException:  # noqa: BLE001 - a missing traceback is not a lost answer
        tb = ""
    return message, tb


def _evaluate(code: str, namespace: dict[str, Any]) -> Any:
    """The value ``code`` evaluates to in ``namespace``, or ``None`` for no result.

    A ``SyntaxError`` from the parse propagates to ``run``, which reports it
    like any runtime exception.
    """
    # Every compile passes dont_inherit=True, so this module's own
    # `from __future__ import annotations` does not apply to model code.
    flags = namespace.get(_FLAGS_KEY, 0)
    if type(flags) is not int:
        # Model code can overwrite the key. An exact int is required because
        # an int subclass could override `&` to pass a non-future bit.
        flags = 0
    # A non-future flag such as PyCF_ONLY_AST would break every later compile.
    flags &= _FUTURE_MASK
    # The parse gets the flags too, because a future feature can change the
    # grammar (`barry_as_FLUFL` restores `<>`).
    tree = compile(
        code, _FILENAME, "exec", flags=flags | ast.PyCF_ONLY_AST, dont_inherit=True
    )
    body = tree.body
    if not body:
        return None
    last = body[-1]
    if not isinstance(last, ast.Expr):
        # Compiling the whole tree keeps its type_ignores.
        module = compile(tree, _FILENAME, "exec", flags=flags, dont_inherit=True)
        # Recorded before the exec, so a submission that fails at runtime
        # still applies its future import to later ones, as in a REPL.
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
    """Add a compiled module's ``__future__`` flags to the session's, and return them.

    ``co_flags`` has a bit for every future statement the compiler honored,
    so it gives exactly the features in effect.
    """
    for feature in _FEATURES:
        if module.co_flags & feature.compiler_flag:
            flags |= feature.compiler_flag
    namespace[_FLAGS_KEY] = flags
    return flags
