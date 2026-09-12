"""The wire between the execution driver and its worker.

One JSON object per line, in both directions. The worker imports this module
directly rather than as part of ``commons``: it runs under ``-I`` with only
its own directory on the path, and pulling the package in would drag the
agent's dependencies into a process whose whole point is to hold nothing.
Nothing here may import from ``commons``.

The far end runs model-written code, so the decode side treats every byte
as hostile: a line of the wrong shape is a ``ProtocolError``, an
unrecoverable channel a ``ChannelError``, and nothing the wire names is
imported or constructed beyond the three frame libraries below.
"""

from __future__ import annotations

import asyncio
import base64
import importlib
import json
import numbers
import sys
from collections.abc import Iterator
from dataclasses import dataclass, field, replace
from typing import Any

__all__ = [
    "FRAME_BYTES_LIMIT",
    "STREAM_LIMIT",
    "Call",
    "ChannelError",
    "Error",
    "Message",
    "OpaqueValue",
    "ProtocolError",
    "Ready",
    "Result",
    "decode_message",
    "decode_value",
    "encode_message",
    "encode_value",
    "read_message",
    "write_message",
]

# The longest allowed message line. Whoever opens the channel must pass this
# as `limit=`: `asyncio` defaults a stream to 64 KiB, which any real frame
# exceeds. A message past the limit is a `ChannelError` from `read_message`.
STREAM_LIMIT = 64 * 1024 * 1024

# The largest a frame may be after Arrow decompression. IPC bodies can be
# compressed, so a line well under STREAM_LIMIT can decode to far more.
# 1 GiB covers any real frame while bounding what a hostile worker can make
# the driver allocate.
FRAME_BYTES_LIMIT = 1024**3

# The deepest a JSON-shaped value may nest and still cross as JSON. `json`
# itself used to bound this by raising `RecursionError`; as of 3.14 its
# parser and encoder are iterative and never will, while everything a value
# meets after the codec — `repr`, re-serialization, display — still
# recurses. A value past the limit crosses as its repr, and a line past it
# is refused: the codec stays the one chokepoint for pathological nesting.
_JSON_DEPTH_LIMIT = 100

# The message envelope wraps a value in a few container levels of its own
# (`value`, the payload object, `data`), so a line is allowed slightly more
# depth than the value it carries.
_ENVELOPE_DEPTH = 8

# Frames cross as Arrow IPC and arrive as whatever library sent them; driver
# and worker share an interpreter, so the sending library is always
# importable at the far end.
_FRAME_TYPES = {"pandas": "DataFrame", "polars": "DataFrame", "pyarrow": "Table"}

# The repr fallback exists to be smaller than the value, so the repr itself
# is capped.
_REPR_TEXT_LIMIT = 10_000

# Printed output and tracebacks are clipped to this many characters when a
# message would otherwise exceed STREAM_LIMIT.
_TEXT_CLIP_LIMIT = 1024 * 1024

_TRUNCATION_NOTE = "\n[truncated by commons: the output exceeded the channel limit]"

# `_coerce_scalar` returns this when a value has no JSON-carryable rendering.
_FALL_BACK = object()


class ProtocolError(Exception):
    """A line on the channel was not a message this protocol defines.

    Recoverable: only the offending message is lost. For the failure that
    is not, see ``ChannelError``.
    """


class ChannelError(Exception):
    """The channel can no longer produce trustworthy message boundaries.

    Raised when a message overran the stream's limit: the reader has
    discarded bytes up to an offset the far end chose, so no later line can
    be trusted and the channel must be abandoned. Not a ``ProtocolError``,
    so that drivers which tolerate junk lines cannot swallow it.
    """


@dataclass(frozen=True, kw_only=True)
class OpaqueValue:
    """Stands in for a value that could not be copied across the channel.

    An open file, a database connection, a fitted model: values that only
    make sense in the process holding them. Crossing by reference is what
    this transport exists to prevent, so what crosses is what a REPL would
    have shown instead.

    Both fields are written by the far end, which runs model-written code:
    treat them as hostile text. Escape them wherever they are rendered, and
    never use ``type_name`` as proof of the value's type — the sender chose
    it.
    """

    type_name: str
    text: str


@dataclass(frozen=True, kw_only=True)
class Ready:
    """Worker to driver, once the sandbox is up and the loop is running."""


@dataclass(frozen=True, kw_only=True)
class Call:
    """Driver to worker: code to run, and the handles it may reach for."""

    id: str
    code: str
    handles: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True, kw_only=True)
class Result:
    """Worker to driver: what the code evaluated to, and what it printed.

    ``value`` is ``None`` both when the code ended in a statement and when it
    ended in an expression evaluating to ``None``. The two are the same thing
    to the model, which is why the REPL suppresses a ``None`` result.
    """

    id: str
    value: Any = None
    stdout: str = ""
    stderr: str = ""


@dataclass(frozen=True, kw_only=True)
class Error:
    """Worker to driver: the code raised, and this is what it said."""

    id: str
    message: str
    traceback: str = ""


Message = Ready | Call | Result | Error


def encode_value(value: Any) -> dict[str, Any]:
    """Render ``value`` as the JSON-shaped payload that carries it.

    Frames cross as Arrow IPC; a ``Series`` crosses as a one-column frame.
    Everything else crosses as JSON when JSON can hold it — numpy scalars
    and arrays count, so ``df["a"].sum()`` arrives as a number — and as its
    ``repr`` when it cannot, which covers datetimes, ``Decimal``, and
    anything process-local. Containers arrive in their JSON shape: a tuple
    comes back a list, dict keys come back as strings, and a container
    holding a frame crosses as its repr as a whole.

    Never raises: a value that cannot cross, or is too large for the
    channel, arrives as its repr, so a bad value costs the value, never
    the call.
    """
    try:
        if isinstance(value, OpaqueValue):
            # Already crossed once: pass it through rather than wrapping
            # its repr in a second OpaqueValue.
            return {
                "encoding": "repr",
                "type": _clip(value.type_name),
                "text": _clip(value.text),
            }
        frame = _as_frame(value)
    except Exception:  # noqa: BLE001 - a spoofed __class__ must not escape
        # `isinstance` is model-controlled input (`__class__` is
        # assignable), so classification itself sits inside the fallback.
        return _repr_payload(value)
    if frame is not None:
        library, frame_value = frame
        data = _to_arrow_ipc(frame_value, library)
        # A column Arrow cannot hold (objects in a pandas `object` column,
        # complex numbers) or a frame too large for the channel falls back
        # to repr: one bad column costs the value, not the call.
        if data is not None and len(data) <= STREAM_LIMIT:
            return {
                "encoding": "arrow",
                "library": library,
                "data": base64.b64encode(data).decode("ascii"),
            }
        return _repr_payload(value)
    try:
        too_deep = _exceeds_json_depth(value)
    except Exception:  # noqa: BLE001 - a spoofed __class__ must not escape
        return _repr_payload(value)
    if too_deep:
        return _repr_payload(value)
    try:
        json.dumps(value)
    except Exception:  # noqa: BLE001 - any failure means the repr fallback
        coerced = _coerce_scalar(value)
        if coerced is not _FALL_BACK:
            return {"encoding": "json", "data": coerced}
        return _repr_payload(value)
    return {"encoding": "json", "data": value}


def _repr_payload(value: Any) -> dict[str, Any]:
    # `repr`, never `pickle`: a pickle stream is a program, and this one
    # would have been written by whatever the worker just ran.
    return {
        "encoding": "repr",
        "type": type(value).__name__,
        "text": _safe_repr(value),
    }


def _safe_repr(value: Any) -> str:
    """``repr(value)``, guaranteed to return bounded text and never raise."""
    try:
        text = repr(value)
    except Exception:  # noqa: BLE001 - the last resort may not itself raise
        return f"<{type(value).__name__} whose repr raised>"
    if len(text) > _REPR_TEXT_LIMIT:
        return f"{text[:_REPR_TEXT_LIMIT]}… [{len(text):,} characters in full]"
    return text


def _exceeds_json_depth(value: Any, limit: int = _JSON_DEPTH_LIMIT) -> bool:
    """Whether ``value`` nests JSON containers deeper than ``limit``.

    A stack of iterators, one per level: the inputs this exists for are
    exactly the ones a recursive walk could not survive, and auxiliary
    memory stays proportional to nesting depth — a wide hostile value pays
    one ``isinstance`` per element, never a stack entry per child.
    """
    stack = [(_container_children(value), 1)]
    while stack:
        children, depth = stack[-1]
        # Only containers are ever yielded, so None is a safe sentinel.
        child = next(children, None)
        if child is None:
            stack.pop()
            continue
        if depth >= limit:
            return True
        stack.append((_container_children(child), depth + 1))
    return False


def _container_children(node: Any) -> Iterator[Any]:
    """The JSON-container children of ``node``, as a lazy iterator."""
    if isinstance(node, dict):
        children: Any = node.values()
    elif isinstance(node, (list, tuple)):
        children = node
    else:
        return iter(())
    return (child for child in children if isinstance(child, (dict, list, tuple)))


def _coerce_scalar(value: Any) -> Any:
    """A JSON-carryable rendering of a value JSON doesn't know, or ``_FALL_BACK``.

    numpy scalars are the everyday case (``df["a"].sum()`` is an ``int64``):
    JSON numbers in every respect but their class, and a repr would
    silently downgrade them. numpy arrays cross as their ``tolist``.
    ``np.bool_``, datetimes, and ``Decimal`` stay reprs on purpose: theirs
    are readable, and a guessed type would change what the model sees.
    """
    if isinstance(value, numbers.Integral):
        candidate: Any = int(value)
    elif isinstance(value, numbers.Real):
        candidate = float(value)
    else:
        numpy = sys.modules.get("numpy")
        if numpy is None or not isinstance(value, numpy.ndarray):
            return _FALL_BACK
        try:
            candidate = value.tolist()
        except Exception:  # noqa: BLE001 - any failure means the repr fallback
            return _FALL_BACK
    try:
        # An object array's tolist can hide arbitrarily deep nesting; the
        # depth limit applies to what crosses, not to what was asked for.
        if _exceeds_json_depth(candidate):
            return _FALL_BACK
        json.dumps(candidate)
    except Exception:  # noqa: BLE001 - any failure means the repr fallback
        # An int past the interpreter's digit limit, a complex array's
        # tolist: nothing JSON carries after all.
        return _FALL_BACK
    return candidate


# Recognized without importing anything: a value can only be a pandas frame
# if pandas is already imported, and forcing the import here would make the
# worker pay for a library the code it ran never asked for.
def _as_frame(value: Any) -> tuple[str, Any] | None:
    """The ``(library, frame)`` ``value`` can cross as, or ``None``.

    A ``Series`` crosses as a one-column frame, arriving as a ``DataFrame``
    with its name as the column name.
    """
    for library, name in _FRAME_TYPES.items():
        module = sys.modules.get(library)
        frame_type = getattr(module, name, None)
        if frame_type is not None and isinstance(value, frame_type):
            return library, value
    for library in ("pandas", "polars"):
        module = sys.modules.get(library)
        series_type = getattr(module, "Series", None)
        if series_type is not None and isinstance(value, series_type):
            return library, value.to_frame()
    return None


# `None`, not an exception, for a frame Arrow will not carry: the caller
# falls back to repr. Arrow's refusals span exception types beyond
# `ValueError`/`TypeError`, and a fake frame (`__class__` is assignable)
# raises `AttributeError`, so the catch is all of `Exception`.
def _to_arrow_ipc(frame: Any, library: str) -> bytes | None:
    try:
        pyarrow = importlib.import_module("pyarrow")
        if library == "pandas":
            table = pyarrow.Table.from_pandas(_deduplicated_columns(frame))
        elif library == "polars":
            table = frame.to_arrow()
        else:
            table = frame
        sink = pyarrow.BufferOutputStream()
        with pyarrow.ipc.new_stream(sink, table.schema) as writer:
            writer.write_table(table)
    except Exception:  # noqa: BLE001 - any refusal means the repr fallback
        return None
    return sink.getvalue().to_pybytes()


def _deduplicated_columns(frame: Any) -> Any:
    """Rename duplicated pandas columns the way pandas itself would.

    Arrow holds duplicate field names happily; only ``Table.from_pandas``
    refuses them, and ``pd.concat(axis=1)`` output is too common to lose
    over it.
    """
    columns = list(frame.columns)
    if len(set(columns)) == len(columns):
        return frame
    seen: dict[Any, int] = {}
    deduplicated = []
    for name in columns:
        count = seen.get(name, 0)
        seen[name] = count + 1
        deduplicated.append(name if count == 0 else f"{name}.{count}")
    frame = frame.copy()
    frame.columns = deduplicated
    return frame


# Annotated `Any` rather than `dict`, because the argument arrives off the
# channel: distrusting its shape is the function's job, not its caller's.
def decode_value(payload: Any, *, max_frame_bytes: int = FRAME_BYTES_LIMIT) -> Any:
    """Read back a payload written by ``encode_value``.

    Raises ``ProtocolError`` for anything that is not such a payload — the
    far end runs model-written code, so a malformed or hostile payload is
    ordinary and must not surface as whatever a codec raises first. A frame
    decoding past ``max_frame_bytes`` is refused the same way, before the
    memory is allocated.
    """
    encoding = payload.get("encoding") if isinstance(payload, dict) else None
    try:
        if encoding == "json":
            return payload["data"]
        if encoding == "repr":
            type_name, text = payload["type"], payload["text"]
            if not isinstance(type_name, str) or not isinstance(text, str):
                raise TypeError("repr payload fields must be strings")
            return OpaqueValue(type_name=type_name, text=text)
        if encoding == "arrow":
            return _from_arrow_ipc(
                base64.b64decode(payload["data"]),
                payload.get("library", ""),
                max_frame_bytes,
            )
    except (KeyError, TypeError, ValueError, RecursionError) as error:
        raise ProtocolError(f"malformed value payload: {error}") from error
    raise ProtocolError(f"unknown value encoding: {encoding!r}")


def _from_arrow_ipc(data: bytes, library: str, max_frame_bytes: int) -> Any:
    # `library` names the module the frame is reconstructed with, so it is
    # checked against the known set before anything is imported: the wire
    # gets to pick among three names and nothing else.
    if library not in _FRAME_TYPES:
        raise ProtocolError(f"unknown frame library: {library!r}")
    try:
        pyarrow = importlib.import_module("pyarrow")
    except ImportError as error:
        raise ProtocolError(f"cannot decode a frame without pyarrow: {error}") from error
    try:
        _check_ipc_size(data, max_frame_bytes)
        reader = pyarrow.ipc.open_stream(pyarrow.py_buffer(data))
        table = _read_capped(reader, pyarrow, max_frame_bytes)
        if library == "pandas":
            return table.to_pandas()
        if library == "polars":
            return importlib.import_module("polars").from_arrow(table)
        return table
    except (ImportError, RecursionError, *_arrow_refusals(pyarrow)) as error:
        raise ProtocolError(f"malformed value payload: {error}") from error


# --- the size cap, enforced before decompression ----------------------------


def _check_ipc_size(data: bytes, max_frame_bytes: int) -> None:
    """Refuse a stream that declares more than ``max_frame_bytes`` decoded.

    Reads only the IPC framing and flatbuffer metadata: nothing is
    decompressed and no Arrow structure is built. Each record batch or
    dictionary delta is charged the sum of its buffers — the uncompressed
    length prefix for a compressed buffer, the declared length otherwise —
    and a batch declaring no buffers is rows of nothing but null columns,
    which pandas conversion prices at a pointer per row. Anything that does
    not parse as the layout pyarrow's writer emits is refused, which honest
    traffic never trips because every stream on this channel came from
    ``_to_arrow_ipc``.
    """
    pos = 0
    decoded = 0
    while pos < len(data):
        marker = _u32(data, pos)
        pos += 4
        if marker == 0xFFFFFFFF:  # the continuation token
            metadata_length = _u32(data, pos)
            pos += 4
        else:  # streams from before IPC format 0.15 go straight to the length
            metadata_length = marker
        if metadata_length == 0:
            return
        if pos + metadata_length > len(data):
            raise ProtocolError("malformed value payload: truncated Arrow IPC metadata")
        metadata = data[pos : pos + metadata_length]
        pos += metadata_length
        body_length, batch = _ipc_message(metadata)
        if body_length < 0 or pos + body_length > len(data):
            raise ProtocolError("malformed value payload: truncated Arrow IPC body")
        body = data[pos : pos + body_length]
        pos += body_length
        if batch is not None:
            decoded += _ipc_batch_size(metadata, batch, body)
            if decoded > max_frame_bytes:
                raise ProtocolError(
                    "a frame decodes to more than the channel allows "
                    f"({decoded:,} bytes declared, limit {max_frame_bytes:,})"
                )


def _ipc_message(metadata: bytes) -> tuple[int, int | None]:
    """The (body length, batch table offset) declared by one message."""
    root = _u32(metadata, 0)
    type_at = _table_field(metadata, root, 1)
    header_type = _u8(metadata, type_at) if type_at is not None else 0
    length_at = _table_field(metadata, root, 3)
    body_length = _i64(metadata, length_at) if length_at is not None else 0
    if header_type not in (2, 3):  # not a DictionaryBatch or RecordBatch
        return body_length, None
    header_at = _table_field(metadata, root, 2)
    if header_at is None:
        raise ProtocolError("malformed value payload: IPC message with no header")
    header = header_at + _u32(metadata, header_at)
    if header_type == 2:  # a DictionaryBatch wraps the RecordBatch it carries
        data_at = _table_field(metadata, header, 1)
        if data_at is None:
            raise ProtocolError("malformed value payload: dictionary batch with no data")
        header = data_at + _u32(metadata, data_at)
    return body_length, header


def _ipc_batch_size(metadata: bytes, batch: int, body: bytes) -> int:
    """The decoded size one record batch declares, in bytes."""
    rows_at = _table_field(metadata, batch, 0)
    rows = _i64(metadata, rows_at) if rows_at is not None else 0
    buffers_at = _table_field(metadata, batch, 2)
    compressed = _table_field(metadata, batch, 3) is not None
    size = 0
    count = 0
    if buffers_at is not None:
        start, count = _vector(metadata, buffers_at)
        # A lying count would churn allocations until the reads ran out of
        # message; the entries are 16 bytes each and must fit inside it.
        if count > (len(metadata) - start) // 16:
            raise ProtocolError(
                "malformed value payload: IPC buffer count overruns its message"
            )
        for i in range(count):
            offset = _i64(metadata, start + 16 * i)
            length = _i64(metadata, start + 16 * i + 8)
            if offset < 0 or length < 0 or offset + length > len(body):
                raise ProtocolError("malformed value payload: IPC buffer outside its body")
            if length == 0:
                continue
            if not compressed:
                size += length
                continue
            prefix = _i64(body, offset)
            if prefix < -1:
                raise ProtocolError("malformed value payload: bad IPC buffer prefix")
            # A compressed buffer starts with its uncompressed length; -1
            # marks a buffer stored uncompressed, which cost it the prefix.
            size += length - 8 if prefix == -1 else prefix
    if count == 0 and rows > 0:
        # No buffers at all: rows of nothing but null columns, which pandas
        # conversion prices at a pointer per row.
        size += 8 * rows
    return size


def _table_field(buf: bytes, table: int, index: int) -> int | None:
    """Where field ``index`` lives in the flatbuffer table, or None if absent."""
    vtable = table - _read_int(buf, table, 4, signed=True)
    entry = 4 + 2 * index
    if entry + 2 > _u16(buf, vtable):
        return None
    offset = _u16(buf, vtable + entry)
    return table + offset if offset else None


def _vector(buf: bytes, loc: int) -> tuple[int, int]:
    """(first element, count) of the flatbuffer vector whose offset is at ``loc``."""
    start = loc + _u32(buf, loc)
    return start + 4, _u32(buf, start)


def _read_int(buf: bytes, off: int, size: int, signed: bool = False) -> int:
    if off < 0 or off + size > len(buf):
        raise ProtocolError("malformed value payload: truncated Arrow IPC metadata")
    return int.from_bytes(buf[off : off + size], "little", signed=signed)


def _u8(buf: bytes, off: int) -> int:
    return _read_int(buf, off, 1)


def _u16(buf: bytes, off: int) -> int:
    return _read_int(buf, off, 2)


def _u32(buf: bytes, off: int) -> int:
    return _read_int(buf, off, 4)


def _i64(buf: bytes, off: int) -> int:
    return _read_int(buf, off, 8, signed=True)


def _read_capped(reader: Any, pyarrow: Any, max_frame_bytes: int) -> Any:
    """Read the stream, refusing to decode past ``max_frame_bytes``.

    The runtime backstop to ``_check_ipc_size``, which enforces the cap from
    the stream's declared metadata before anything decompresses. The two
    should agree; if a crafted stream ever divides them, counting batches as
    they materialize bounds the damage to one batch past the cap.
    """
    batches = []
    decoded = 0
    for batch in reader:
        decoded += batch.nbytes
        if decoded > max_frame_bytes:
            raise ProtocolError(
                "a frame decodes to more than the channel allows "
                f"({decoded:,} bytes read, limit {max_frame_bytes:,})"
            )
        batches.append(batch)
    return pyarrow.Table.from_batches(batches, schema=reader.schema)


# `ArrowInvalid` and `ArrowTypeError` are `ValueError` and `TypeError`, but
# `ArrowNotImplementedError` and several others are not, so catching the
# builtin types alone lets a real refusal through. `ArrowIOError` is named
# separately because it does not descend from `ArrowException`.
def _arrow_refusals(pyarrow: Any) -> tuple[type[BaseException], ...]:
    return (TypeError, ValueError, pyarrow.ArrowException, pyarrow.ArrowIOError)


def encode_message(message: Message) -> bytes:
    """Render ``message`` as the single line that carries it.

    A message that would exceed ``STREAM_LIMIT`` is shrunk first: printed
    output is clipped, then values are replaced by their reprs. Raises
    ``ProtocolError`` when nothing is left to shrink — a ``Call`` carrying
    megabytes of code, say — because a line no reader can consume would
    wedge the channel.
    """
    line = _encode_line(message)
    if len(line) <= STREAM_LIMIT:
        return line
    line = _encode_line(_shrink_text(message))
    if len(line) <= STREAM_LIMIT:
        return line
    line = _encode_line(_shrink_values(message))
    if len(line) > STREAM_LIMIT:
        raise ProtocolError(
            f"a {type(message).__name__} message is {len(line):,} bytes, "
            f"longer than the channel allows ({STREAM_LIMIT:,})"
        )
    return line


def _encode_line(message: Message) -> bytes:
    # `ensure_ascii` is what keeps the line a line: it escapes every newline
    # inside a string, so only the terminator below is a real one.
    return json.dumps(_message_body(message), ensure_ascii=True).encode() + b"\n"


def _message_body(message: Message) -> dict[str, Any]:
    match message:
        case Ready():
            return {"type": "ready"}
        case Call():
            return {
                "type": "call",
                "id": message.id,
                "code": message.code,
                "handles": {
                    name: encode_value(value)
                    for name, value in message.handles.items()
                },
            }
        case Result():
            return {
                "type": "result",
                "id": message.id,
                "value": encode_value(message.value),
                "stdout": message.stdout,
                "stderr": message.stderr,
            }
        case Error():
            return {
                "type": "error",
                "id": message.id,
                "message": message.message,
                "traceback": message.traceback,
            }
        case _:
            raise ProtocolError(
                f"not a message this protocol defines: {type(message).__name__}"
            )


def _shrink_text(message: Message) -> Message:
    """The same message with its printed output and traceback clipped."""
    match message:
        case Result():
            return replace(
                message,
                stdout=_clip(message.stdout),
                stderr=_clip(message.stderr),
            )
        case Error():
            return replace(
                message,
                message=_clip(message.message),
                traceback=_clip(message.traceback),
            )
        case _:
            return message


def _shrink_values(message: Message) -> Message:
    """The same message with its values replaced by their reprs.

    The code in a ``Call`` is never touched: a truncated program is worse
    than an unsent one.
    """
    match message:
        case Result():
            return replace(message, value=_as_opaque(message.value))
        case Call():
            return replace(
                message,
                handles={
                    name: _as_opaque(value)
                    for name, value in message.handles.items()
                },
            )
        case _:
            return message


def _as_opaque(value: Any) -> Any:
    if isinstance(value, OpaqueValue):
        return value
    return OpaqueValue(type_name=type(value).__name__, text=_safe_repr(value))


def _clip(text: str) -> str:
    if len(text) <= _TEXT_CLIP_LIMIT:
        return text
    return text[:_TEXT_CLIP_LIMIT] + _TRUNCATION_NOTE


def decode_message(line: bytes | str, *, max_frame_bytes: int = FRAME_BYTES_LIMIT) -> Message:
    """Read back a line written by ``encode_message``.

    Raises ``ProtocolError`` for anything else: not JSON, not an object,
    an unknown message type, or fields missing, extra, or the wrong shape.
    Every field came off the channel, so nothing about its shape is
    guaranteed; a wrong shape must fail here, not much later in a driver
    that keys its in-flight calls on ``id``.
    """
    try:
        body = json.loads(line)
    except (ValueError, RecursionError) as error:  # bad JSON, bad UTF-8
        raise ProtocolError(f"not a protocol message: {_abbrev(line)}") from error
    if not isinstance(body, dict) or _exceeds_json_depth(
        body, _JSON_DEPTH_LIMIT + _ENVELOPE_DEPTH
    ):
        raise ProtocolError(f"not a protocol message: {_abbrev(line)}")
    kind = body.get("type")
    match kind:
        case "ready":
            _refuse_unknown_fields(body, "ready", {"type"})
            return Ready()
        case "call":
            _refuse_unknown_fields(body, "call", {"type", "id", "code", "handles"})
            return Call(
                id=_required_text(body, "id", "call"),
                code=_required_text(body, "code", "call"),
                handles=_decode_handles(body, max_frame_bytes),
            )
        case "result":
            _refuse_unknown_fields(
                body, "result", {"type", "id", "value", "stdout", "stderr"}
            )
            return Result(
                id=_required_text(body, "id", "result"),
                value=_decode_result_value(body, max_frame_bytes),
                stdout=_optional_text(body, "stdout", "result"),
                stderr=_optional_text(body, "stderr", "result"),
            )
        case "error":
            _refuse_unknown_fields(body, "error", {"type", "id", "message", "traceback"})
            return Error(
                id=_required_text(body, "id", "error"),
                message=_required_text(body, "message", "error"),
                traceback=_optional_text(body, "traceback", "error"),
            )
        case _:
            raise ProtocolError(f"unknown message type: {kind!r}")


def _refuse_unknown_fields(body: dict[str, Any], kind: str, known: set[str]) -> None:
    unknown = sorted(set(body) - known)
    if unknown:
        raise ProtocolError(f"malformed {kind} message: unknown field {unknown[0]!r}")


def _required_text(body: dict[str, Any], name: str, kind: str) -> str:
    if name not in body:
        raise ProtocolError(f"malformed {kind} message: missing {name}")
    value = body[name]
    if not isinstance(value, str):
        raise ProtocolError(f"malformed {kind} message: {name} must be a string")
    return value


def _optional_text(body: dict[str, Any], name: str, kind: str) -> str:
    if name not in body:
        return ""
    value = body[name]
    if not isinstance(value, str):
        raise ProtocolError(f"malformed {kind} message: {name} must be a string")
    return value


def _decode_handles(body: dict[str, Any], max_frame_bytes: int) -> dict[str, Any]:
    if "handles" not in body:
        return {}
    raw = body["handles"]
    if not isinstance(raw, dict):
        raise ProtocolError("malformed call message: handles must be a mapping")
    return {
        key: decode_value(item, max_frame_bytes=max_frame_bytes)
        for key, item in raw.items()
    }


def _decode_result_value(body: dict[str, Any], max_frame_bytes: int) -> Any:
    if "value" not in body:
        return None
    return decode_value(body["value"], max_frame_bytes=max_frame_bytes)


def _abbrev(line: bytes | str, limit: int = 200) -> str:
    """A short rendering of a rejected line, for an error message.

    The whole line can be megabytes of far-end-chosen bytes; it does not
    belong whole in a log or a model's context.
    """
    text = repr(line)
    return text if len(text) <= limit else text[:limit] + "…"


async def read_message(
    reader: asyncio.StreamReader, *, max_frame_bytes: int = FRAME_BYTES_LIMIT
) -> Message | None:
    """Read the next message, or ``None`` once the channel is done.

    A worker that has exited is the ordinary end of a channel, so that is
    an answer, not an exception. A line past the stream's limit is a
    ``ChannelError``, on that call and every later one: the reader has
    discarded bytes up to an offset the far end chose, so no later boundary
    can be trusted and the channel must be abandoned.
    """
    latched = getattr(reader, "_commons_channel_error", None)
    if latched is not None:
        raise latched
    try:
        line = await reader.readline()
    except ValueError as error:
        channel_error = ChannelError(
            "a message was longer than the channel allows; the channel "
            "cannot be resynchronised and must be abandoned"
        )
        # Latch onto the reader so a driver that catches and continues
        # cannot get a "recovered" read positioned by the far end.
        # (`setattr`: the latch is ours, not StreamReader's typed surface.)
        setattr(reader, "_commons_channel_error", channel_error)  # noqa: B010
        raise channel_error from error
    if not line:
        return None
    return decode_message(line, max_frame_bytes=max_frame_bytes)


async def write_message(writer: asyncio.StreamWriter, message: Message) -> None:
    """Send ``message``, waiting for the far end to keep up.

    Raises ``ProtocolError`` if the message cannot be made to fit the
    channel, and ``OSError`` — usually ``ConnectionResetError`` — once the
    far end is gone.
    """
    writer.write(encode_message(message))
    await writer.drain()
