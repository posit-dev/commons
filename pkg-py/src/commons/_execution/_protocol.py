"""The message protocol between the execution driver and its worker process.

Messages are newline-delimited JSON: one object per line, in both
directions.

The worker imports this module directly rather than as part of ``commons``.
It runs under ``python -I`` with only its own directory on the path, and
importing the package would pull the agent's dependencies into a process
that is deliberately kept free of them. For that reason, nothing in this
module may import from ``commons``.

Because the worker runs model-written code, the decode side treats every
incoming byte as untrusted. A line that does not match the protocol raises
``ProtocolError``; a channel that can no longer be trusted raises
``ChannelError``. Nothing named on the wire is imported or constructed
beyond the three supported frame libraries (pandas, polars, and pyarrow).
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
# as `limit=`, because `asyncio` caps a stream at 64 KiB by default and any
# real frame exceeds that. A message past the limit surfaces as a
# `ChannelError` from `read_message`.
STREAM_LIMIT = 64 * 1024 * 1024

# The largest a frame may be after Arrow decompression. IPC bodies can be
# compressed, so a line well under STREAM_LIMIT can decode to far more.
# 1 GiB covers any real frame while bounding how much memory an untrusted
# worker can make the driver allocate.
FRAME_BYTES_LIMIT = 1024**3

# The deepest a JSON-shaped value may nest and still cross as JSON. `json`
# itself used to enforce a bound by raising `RecursionError`, but as of 3.14
# its parser and encoder are iterative and never will — while everything a
# value meets after the codec (`repr`, re-serialization, display) still
# recurses. A value past the limit crosses as its repr, and a line past it
# is refused, so the codec stays the single chokepoint for pathological
# nesting.
_JSON_DEPTH_LIMIT = 100

# The message envelope wraps a value in a few container levels of its own
# (`value`, the payload object, `data`), so a line is allowed slightly more
# depth than the value it carries.
_ENVELOPE_DEPTH = 8

# Frames cross as Arrow IPC and arrive as whatever library sent them; driver
# and worker share an interpreter, so the sending library is always
# importable at the far end.
_FRAME_TYPES = {"pandas": "DataFrame", "polars": "DataFrame", "pyarrow": "Table"}

# The repr fallback exists to be smaller than the value it replaces, so the
# repr itself is capped.
_REPR_TEXT_LIMIT = 10_000

# Printed output and tracebacks are clipped to this many characters when a
# message would otherwise exceed STREAM_LIMIT.
_TEXT_CLIP_LIMIT = 1024 * 1024

# The largest Arrow frame that still fits the line once it is base64, which
# costs four bytes for every three. A frame above this would be encoded and
# then thrown away again by `encode_message`. The frame is not the whole
# line, so the budget also reserves room for what rides beside it: printed
# output and a traceback, each clipped to `_TEXT_CLIP_LIMIT`, plus the
# envelope. Text that escapes long can still overrun the limit;
# `encode_message` remains the final authority.
_FRAME_WIRE_LIMIT = (STREAM_LIMIT - 2 * _TEXT_CLIP_LIMIT - 4096) * 3 // 4

_TRUNCATION_NOTE = "\n[truncated by commons: the output exceeded the channel limit]"

# Arrow IPC message header types, plus the one field type that writes no
# buffer, numbered as the format's flatbuffer schemas number them.
_SCHEMA = 1
_DICTIONARY_BATCH = 2
_RECORD_BATCH = 3
_NULL_TYPE = 1

# How deep a schema may nest its fields; the walk below holds one iterator
# per level. pyarrow refuses to read a stream nested even half this deep,
# so the cap is reachable only by a schema written by hand.
_SCHEMA_DEPTH_LIMIT = 128

# Returned by `_coerce_scalar` when a value has no JSON-carryable rendering.
_FALL_BACK = object()


class ProtocolError(Exception):
    """A line on the channel was not a valid protocol message.

    This error is recoverable: only the offending message is lost. See
    ``ChannelError`` for the unrecoverable case.
    """


class ChannelError(Exception):
    """The channel can no longer produce trustworthy message boundaries.

    Raised when a message overran the stream's limit: the reader has
    discarded bytes up to an offset the far end chose, so no later line can
    be trusted and the channel must be abandoned. This deliberately does not
    subclass ``ProtocolError``, so that drivers which tolerate malformed
    lines cannot accidentally swallow it.
    """


@dataclass(frozen=True, kw_only=True)
class OpaqueValue:
    """A stand-in for a value that could not be copied across the channel.

    Some values — an open file, a database connection, a fitted model —
    only make sense inside the process that holds them. Copying them across
    by reference is exactly what this transport exists to prevent, so what
    crosses instead is the text a REPL would have shown.

    Both fields are written by the far end, which runs model-written code:
    treat them as untrusted text. Escape them wherever they are rendered,
    and never rely on ``type_name`` as proof of the value's type — the
    sender chose it.
    """

    type_name: str
    text: str


@dataclass(frozen=True, kw_only=True)
class Ready:
    """Sent by the worker to the driver once the sandbox is up and running."""


@dataclass(frozen=True, kw_only=True)
class Call:
    """Sent by the driver to the worker: code to run, and the handles it may use."""

    id: str
    code: str
    handles: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True, kw_only=True)
class Result:
    """Sent by the worker to the driver: what the code evaluated to, and what it printed.

    ``value`` is ``None`` both when the code ended in a statement and when it
    ended in an expression that evaluated to ``None``. The two are equivalent
    to the model, which is why the REPL suppresses a ``None`` result.
    """

    id: str
    value: Any = None
    stdout: str = ""
    stderr: str = ""


@dataclass(frozen=True, kw_only=True)
class Error:
    """Sent by the worker to the driver: the code raised, and this is what it said."""

    id: str
    message: str
    traceback: str = ""


Message = Ready | Call | Result | Error


def encode_value(value: Any) -> dict[str, Any]:
    """Render ``value`` as the JSON-shaped payload that carries it across the channel.

    DataFrames cross as Arrow IPC, and a ``Series`` crosses as a one-column
    frame. Everything else crosses as JSON when JSON can represent it —
    numpy scalars and arrays count, so ``df["a"].sum()`` arrives as a plain
    number — and as its ``repr`` when it cannot, which covers datetimes,
    ``Decimal``, and anything process-local. Containers arrive in their JSON
    shape: a tuple comes back as a list, dict keys come back as strings, and
    a container holding a frame crosses as its repr as a whole.

    This function never raises: a value that cannot cross, or that is too
    large for the channel, arrives as its repr. A bad value costs the value,
    never the call.
    """
    try:
        if isinstance(value, OpaqueValue):
            # The value has crossed once already: pass it through rather
            # than wrapping its repr in a second OpaqueValue.
            return {
                "encoding": "repr",
                "type": _clip(value.type_name),
                "text": _clip(value.text),
            }
        frame = _as_frame(value)
    except Exception:  # noqa: BLE001 - a spoofed __class__ must not escape
        # `isinstance` is model-controlled input (`__class__` is
        # assignable), so the classification itself has to sit inside the
        # fallback.
        return _repr_payload(value)
    if frame is not None:
        library, frame_value = frame
        data = _to_arrow_ipc(frame_value, library)
        # A column Arrow cannot hold (objects in a pandas `object` column,
        # complex numbers) or a frame too large for the channel falls back
        # to repr: one bad column costs the value, not the call.
        if data is not None and len(data) <= _FRAME_WIRE_LIMIT:
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
    # Use `repr`, never `pickle`: a pickle stream is a program, and this one
    # would have been written by whatever the worker just ran.
    return {
        "encoding": "repr",
        "type": type(value).__name__,
        "text": _safe_repr(value),
    }


def _safe_repr(value: Any) -> str:
    """``repr(value)``, guaranteed to return bounded text and to never raise."""
    try:
        text = repr(value)
    except Exception:  # noqa: BLE001 - the last resort may not itself raise
        return f"<{type(value).__name__} whose repr raised>"
    if len(text) > _REPR_TEXT_LIMIT:
        return f"{text[:_REPR_TEXT_LIMIT]}… [{len(text):,} characters in full]"
    return text


def _exceeds_json_depth(value: Any, limit: int = _JSON_DEPTH_LIMIT) -> bool:
    """Whether ``value`` nests JSON containers deeper than ``limit``.

    The walk uses an explicit stack of iterators, one per level, because the
    inputs this function exists for are exactly the ones a recursive walk
    could not survive. Auxiliary memory stays proportional to nesting depth,
    so a very wide hostile value pays one ``isinstance`` per element rather
    than a stack entry per child.
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

    numpy scalars are the everyday case: ``df["a"].sum()`` is an ``int64``,
    a JSON number in every respect but its class, and falling back to repr
    would silently downgrade it. numpy arrays cross as their ``tolist``.
    ``np.bool_``, datetimes, and ``Decimal`` deliberately stay as reprs:
    their reprs are readable, and guessing a type would change what the
    model sees.
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
        # depth limit applies to what actually crosses, not to what was
        # asked for.
        if _exceeds_json_depth(candidate):
            return _FALL_BACK
        json.dumps(candidate)
    except Exception:  # noqa: BLE001 - any failure means the repr fallback
        # An int past the interpreter's digit limit, a complex array's
        # tolist: things JSON cannot carry after all.
        return _FALL_BACK
    return candidate


# Frames are recognized without importing anything: a value can only be a
# pandas frame if pandas is already imported, and forcing the import here
# would make the worker pay for a library the code it ran never asked for.
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


# Return `None`, not an exception, for a frame Arrow will not carry; the
# caller falls back to repr. Arrow's refusals span exception types beyond
# `ValueError` and `TypeError`, and a fake frame (`__class__` is assignable)
# raises `AttributeError`, so the catch covers all of `Exception`.
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

    Arrow accepts duplicate field names; only ``Table.from_pandas`` refuses
    them, and the output of ``pd.concat(axis=1)`` is too common to lose over
    it.
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
# channel: distrusting its shape is this function's job, not its caller's.
def decode_value(payload: Any, *, max_frame_bytes: int = FRAME_BYTES_LIMIT) -> Any:
    """Read back a payload written by ``encode_value``.

    Raises ``ProtocolError`` for anything that is not such a payload. The
    far end runs model-written code, so a malformed or hostile payload is an
    ordinary event and must surface as ``ProtocolError``, not as whatever a
    codec happens to raise first. A frame that would decode to more than
    ``max_frame_bytes`` is refused the same way, before that memory is
    allocated.
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
    # gets to choose among three names and nothing else.
    if library not in _FRAME_TYPES:
        raise ProtocolError(f"unknown frame library: {library!r}")
    try:
        pyarrow = importlib.import_module("pyarrow")
    except ImportError as error:
        raise ProtocolError(f"cannot decode a frame without pyarrow: {error}") from error
    # Only pandas spends a pointer on a null value. Arrow holds a null
    # column as a length and polars keeps it that way, so the cells the
    # caps below charge for are free unless the frame becomes a pandas
    # one; charging them anyway would refuse frames this module is willing
    # to encode.
    cells = library == "pandas"
    try:
        _check_ipc_size(data, max_frame_bytes, cells)
        reader = pyarrow.ipc.open_stream(pyarrow.py_buffer(data))
        table = _read_capped(reader, pyarrow, max_frame_bytes, cells)
        return _rebuild_frame(table, library)
    except (ImportError, RecursionError, *_arrow_refusals(pyarrow)) as error:
        raise ProtocolError(f"malformed value payload: {error}") from error


def _rebuild_frame(table: Any, library: str) -> Any:
    # The wire names the library and carries the bytes separately, so a
    # table Arrow accepts can still be one that pandas or polars will not
    # hold. Their refusals are ordinary exceptions of their own making, and
    # the size is already checked, so anything raised here is the payload's
    # fault and must surface to the caller as a `ProtocolError`.
    try:
        if library == "pandas":
            return table.to_pandas()
        if library == "polars":
            return importlib.import_module("polars").from_arrow(table)
        return table
    except Exception as error:  # the boundary owes a ProtocolError, whatever raised
        raise ProtocolError(f"malformed value payload: {error}") from error


# --- the size cap, enforced before decompression ----------------------------


def _check_ipc_size(data: bytes, max_frame_bytes: int, cells: bool) -> None:
    """Refuse a stream that declares more than ``max_frame_bytes`` once decoded.

    Only the IPC framing and flatbuffer metadata are read: nothing is
    decompressed and no Arrow structure is built. Each record batch or
    dictionary delta is charged the sum of its buffers — the uncompressed
    length prefix for a compressed buffer, the declared length otherwise —
    plus one pointer per cell for the null fields named in the schema, which
    write no buffer of their own to be charged for. Anything that does not
    parse as the layout pyarrow's writer emits is refused; honest traffic
    never trips this, because every stream on this channel came from
    ``_to_arrow_ipc``.
    """
    pos = 0
    decoded = 0
    nulls = bytearray()
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
        body_length, kind, header = _ipc_message(metadata)
        if body_length < 0 or pos + body_length > len(data):
            raise ProtocolError("malformed value payload: truncated Arrow IPC body")
        body = data[pos : pos + body_length]
        pos += body_length
        if kind == _SCHEMA and header is not None:
            if cells:
                nulls = _null_fields(metadata, header)
        elif header is not None:
            # A dictionary batch carries one field's values, which the
            # schema's node positions do not describe and pandas does not
            # pay for; only a record batch is charged against them.
            decoded += _ipc_batch_size(
                metadata, header, body,
                nulls if kind == _RECORD_BATCH else bytearray(),
            )
            if decoded > max_frame_bytes:
                raise ProtocolError(
                    "a frame decodes to more than the channel allows "
                    f"({decoded:,} bytes declared, limit {max_frame_bytes:,})"
                )


def _ipc_message(metadata: bytes) -> tuple[int, int, int | None]:
    """The (body length, kind, header table offset) declared by one message."""
    root = _u32(metadata, 0)
    type_at = _table_field(metadata, root, 1)
    header_type = _u8(metadata, type_at) if type_at is not None else 0
    length_at = _table_field(metadata, root, 3)
    body_length = _i64(metadata, length_at) if length_at is not None else 0
    if header_type not in (_SCHEMA, _DICTIONARY_BATCH, _RECORD_BATCH):
        return body_length, header_type, None
    header_at = _table_field(metadata, root, 2)
    if header_at is None:
        raise ProtocolError("malformed value payload: IPC message with no header")
    header = header_at + _u32(metadata, header_at)
    if header_type == _DICTIONARY_BATCH:  # it wraps the RecordBatch it carries
        data_at = _table_field(metadata, header, 1)
        if data_at is None:
            raise ProtocolError("malformed value payload: dictionary batch with no data")
        header = data_at + _u32(metadata, data_at)
    return body_length, header_type, header


def _null_fields(metadata: bytes, schema: int) -> bytearray:
    """Which of the schema's field nodes have the null type, in batch order.

    A null field is the one kind that writes no buffer at all: it is free on
    the wire but costs a pointer per cell in pandas. Which fields those are
    has to come from the schema, because a batch says how many nodes it
    carries, not which of them are free — one string field's three buffers
    are enough to hide two null columns behind it.

    A batch lists its nodes in the order this walk visits the fields,
    parents before children, so a field's position here is what the batch is
    charged by. A dictionary-encoded field is a single node holding indices,
    however deep the type it encodes, and the walk stops there: its values
    arrive in a batch of their own and cost pandas nothing, since pandas
    refuses a null category outright and holds the rest by index.
    """
    fields_at = _table_field(metadata, schema, 1)
    if fields_at is None:
        return bytearray()
    # Store a flag per field rather than the position of each null one: the
    # far end decides how many positions there are, and a schema entitled to
    # name millions of them would be paid for in objects. A flag costs only
    # the byte that the field's own offset already cost.
    flags = bytearray()
    # Nothing guarantees the offsets advance: a hand-built schema can point
    # a field's children back at the field itself, and the walk would never
    # end. No field costs fewer than sixteen bytes of message (pyarrow's
    # writer spends nearer forty), so the message length bounds how many it
    # can hold. Garbage offsets fail their own reads long before this check;
    # it is here to end a cycle, not to catch one.
    budget = len(metadata) // 16
    # Keep one iterator per level rather than a list of every field: the
    # counts are the far end's to choose, and a vector it is entitled to
    # declare is long enough that reading it all in would be the very
    # allocation this function exists to refuse.
    stack = [_tables(metadata, fields_at)]
    while stack:
        field = next(stack[-1], None)
        if field is None:
            stack.pop()
            continue
        if budget <= 0:
            raise ProtocolError(
                "malformed value payload: IPC schema overruns its message"
            )
        budget -= 1
        encoded = _table_field(metadata, field, 4) is not None
        type_at = _table_field(metadata, field, 2)
        is_null = type_at is not None and _u8(metadata, type_at) == _NULL_TYPE
        flags.append(1 if is_null and not encoded else 0)
        children_at = _table_field(metadata, field, 5)
        if encoded or children_at is None:
            continue
        if len(stack) >= _SCHEMA_DEPTH_LIMIT:
            raise ProtocolError("malformed value payload: IPC schema nests too deep")
        stack.append(_tables(metadata, children_at))
    # Most frames have no null field at all and owe the batches nothing.
    return flags if 1 in flags else bytearray()


def _tables(buf: bytes, loc: int) -> Iterator[int]:
    """Where each table in the vector of tables at ``loc`` begins."""
    start, count = _vector(buf, loc)
    # Each entry is a 4-byte offset and must fit inside the message.
    if count > (len(buf) - start) // 4:
        raise ProtocolError(
            "malformed value payload: IPC field count overruns its message"
        )
    return (start + 4 * i + _u32(buf, start + 4 * i) for i in range(count))


def _ipc_batch_size(
    metadata: bytes, batch: int, body: bytes, nulls: bytearray
) -> int:
    """The decoded size one record batch declares, in bytes."""
    buffers_at = _table_field(metadata, batch, 2)
    compressed = _table_field(metadata, batch, 3) is not None
    size = _null_node_size(metadata, batch, nulls)
    if buffers_at is not None:
        start, count = _vector(metadata, buffers_at)
        # A count that lies would churn allocations until the reads ran out
        # of message; each entry is 16 bytes and must fit inside it.
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
            if length < 8:
                # The prefix below is those eight bytes; a shorter buffer
                # would charge the batch a negative number of them.
                raise ProtocolError(
                    "malformed value payload: IPC buffer shorter than its prefix"
                )
            prefix = _i64(body, offset)
            if prefix < -1:
                raise ProtocolError("malformed value payload: bad IPC buffer prefix")
            # A compressed buffer starts with its uncompressed length; -1
            # marks a buffer stored uncompressed, which is what cost it the
            # prefix.
            size += length - 8 if prefix == -1 else prefix
    return size


def _null_node_size(metadata: bytes, batch: int, nulls: bytearray) -> int:
    """What the batch's null fields cost, at one pointer per cell.

    Each null field is charged by its own node's length rather than the
    batch's, so a nested one is charged for the values it holds: a single
    row of ``list<null>`` costs one offsets buffer on the wire, and its
    child node says how many nulls that row unpacks into.
    """
    if not nulls:
        return 0
    nodes_at = _table_field(metadata, batch, 1)
    if nodes_at is None:
        raise ProtocolError("malformed value payload: IPC batch with no field nodes")
    start, count = _vector(metadata, nodes_at)
    # The entries are 16 bytes each and must fit inside the message.
    if count > (len(metadata) - start) // 16:
        raise ProtocolError(
            "malformed value payload: IPC node count overruns its message"
        )
    if count < len(nulls):
        raise ProtocolError("malformed value payload: IPC batch short of its schema")
    size = 0
    for at, is_null in enumerate(nulls):
        if not is_null:
            continue
        length = _i64(metadata, start + 16 * at)
        if length < 0:
            # The length is signed on the wire and charged against the
            # limit below; a negative one would pay the batch back for its
            # buffers.
            raise ProtocolError("malformed value payload: IPC node of negative length")
        size += 8 * length
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


def _read_capped(reader: Any, pyarrow: Any, max_frame_bytes: int, cells: bool) -> Any:
    """Read the stream, refusing to decode past ``max_frame_bytes``.

    This is the runtime backstop to ``_check_ipc_size``, which enforces the
    cap from the stream's declared metadata before anything decompresses.
    The two should agree; if a crafted stream ever divides them, counting
    batches as they materialize bounds the damage to one batch past the cap.
    """
    batches = []
    decoded = 0
    for batch in reader:
        decoded += _batch_cost(batch, pyarrow, cells)
        if decoded > max_frame_bytes:
            raise ProtocolError(
                "a frame decodes to more than the channel allows "
                f"({decoded:,} bytes read, limit {max_frame_bytes:,})"
            )
        batches.append(batch)
    return pyarrow.Table.from_batches(batches, schema=reader.schema)


def _batch_cost(batch: Any, pyarrow: Any, cells: bool) -> int:
    """What one batch costs once it becomes a frame, in bytes.

    ``nbytes`` is what Arrow holds, which is nothing for a null value: a
    wide frame of null columns, or one row of a list of them, is kilobytes
    of Arrow but a pointer per cell of pandas. Charging those cells keeps
    this in step with the pre-flight check instead of sharing its blind
    spot — and only where they actually cost anything.
    """
    if not cells:
        return batch.nbytes
    nulls = sum(_null_cells(column, pyarrow) for column in batch.columns)
    return batch.nbytes + 8 * nulls


def _null_cells(array: Any, pyarrow: Any) -> int:
    """How many values in ``array`` have the null type.

    Dictionary arrays are not walked into, for the reason ``_null_fields``
    gives: their values reach pandas by index, never one pointer each.
    """
    kind = array.type
    if pyarrow.types.is_null(kind):
        return len(array)
    if pyarrow.types.is_struct(kind) or pyarrow.types.is_union(kind):
        children: Any = (array.field(i) for i in range(kind.num_fields))
    elif hasattr(array, "values"):  # every flavour of list, and map
        children = (array.values,)
    else:
        return 0
    return sum(_null_cells(child, pyarrow) for child in children)


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
    # `ensure_ascii` is what keeps the line a single line: it escapes every
    # newline inside a string, so only the terminator below is a real one.
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

    Raises ``ProtocolError`` for anything else: not JSON, not an object, an
    unknown message type, or fields that are missing, extra, or the wrong
    shape. Every field came off the channel, so nothing about its shape is
    guaranteed; a wrong shape must fail here rather than much later, in a
    driver that keys its in-flight calls on ``id``.

    ``line`` is assumed to be bounded already by the reader that produced
    it: ``read_message`` refuses anything past ``STREAM_LIMIT`` before a
    line gets here. Its length is not checked again, so a caller reading
    from somewhere else must enforce that bound itself.
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
    belong whole in a log or in a model's context.
    """
    text = repr(line)
    return text if len(text) <= limit else text[:limit] + "…"


async def read_message(
    reader: asyncio.StreamReader, *, max_frame_bytes: int = FRAME_BYTES_LIMIT
) -> Message | None:
    """Read the next message, or ``None`` once the channel is done.

    A worker that has exited is the ordinary end of a channel, so that is an
    answer rather than an exception. A line past the stream's limit is a
    ``ChannelError``, on that call and on every later one: the reader has
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
        # (`setattr` because the latch is ours, not part of StreamReader's
        # typed surface.)
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
