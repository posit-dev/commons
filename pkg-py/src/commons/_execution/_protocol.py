"""The wire between the execution driver and its worker.

One JSON object per line, in both directions. The worker imports this module
directly rather than as part of ``commons``: it runs under ``-I`` with only
its own directory on the path, and pulling the package in would drag the
agent's dependencies into a process whose whole point is to hold nothing.
Nothing here may import from ``commons``.
"""

from __future__ import annotations

import asyncio
import base64
import importlib
import json
import sys
from dataclasses import dataclass, field, fields
from typing import Any

__all__ = [
    "STREAM_LIMIT",
    "Call",
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

# How long a single message line may be. A frame crossing as base64 Arrow is
# nothing like the 64 KiB `asyncio` allows a stream by default, and a driver
# that leaves the default in place will fail on the first real result rather
# than on an unusual one. Whoever opens the channel passes this as `limit=`.
STREAM_LIMIT = 64 * 1024 * 1024

# Frames cross as Arrow IPC and arrive as whatever library sent them. The
# driver and the worker run the same interpreter over the same site-packages,
# so the sending library is always available at the far end.
_FRAME_TYPES = {"pandas": "DataFrame", "polars": "DataFrame", "pyarrow": "Table"}


class ProtocolError(Exception):
    """A line on the channel was not a message this protocol defines."""


@dataclass(frozen=True, kw_only=True)
class OpaqueValue:
    """Stands in for a value that could not be copied across the channel.

    An open file, a database connection, a fitted model: things whose worth
    is in the process holding them. Crossing by reference is what this
    transport exists to prevent, so what crosses is what a REPL would have
    shown of it instead.
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

_TYPES: dict[str, type] = {
    "ready": Ready,
    "call": Call,
    "result": Result,
    "error": Error,
}
_NAMES = {cls: name for name, cls in _TYPES.items()}


# Fields holding arbitrary Python values rather than JSON-shaped ones, and so
# needing the value codec on the way past.
_VALUE_FIELDS: dict[type, tuple[str, ...]] = {Result: ("value",)}
_VALUE_MAPS: dict[type, tuple[str, ...]] = {Call: ("handles",)}

# The rest are declared `str` and have to actually be one. JSON's types do not
# line up with the dataclass's, so nothing else checks this: an id that
# arrives as an object constructs a message that fails much later, in a
# driver that keys its in-flight call on it.
_TEXT_FIELDS: dict[type, tuple[str, ...]] = {
    cls: tuple(f.name for f in fields(cls) if f.type == "str") for cls in _NAMES
}


def encode_value(value: Any) -> dict[str, Any]:
    """Render ``value`` as the JSON-shaped payload that carries it.

    Frames cross as Arrow IPC, keeping their column types. Everything else
    crosses as JSON when JSON can hold it, and as its ``repr`` when it
    cannot. Copies are the only thing that crosses, so containers arrive in
    their JSON shape: a tuple comes back a list, and a dictionary's keys come
    back as strings.
    """
    library = _frame_library(value)
    if library is not None:
        try:
            data = _to_arrow_ipc(value, library)
        except (TypeError, ValueError):
            # A column Arrow cannot hold — objects in a pandas `object`
            # column, say. Being a frame is no reason to be exempt from the
            # fallback: one bad column should cost the value, not the call.
            return _repr_payload(value)
        return {
            "encoding": "arrow",
            "library": library,
            "data": base64.b64encode(data).decode("ascii"),
        }
    try:
        json.dumps(value)
    except (TypeError, ValueError):
        # `repr`, never `pickle`: a pickle stream is a program, and this one
        # would have been written by whatever the worker just ran.
        return _repr_payload(value)
    return {"encoding": "json", "data": value}


def _repr_payload(value: Any) -> dict[str, Any]:
    return {"encoding": "repr", "type": type(value).__name__, "text": repr(value)}


# Annotated `Any` rather than `dict`, because the argument arrives off the
# channel: distrusting its shape is the function's job, not its caller's.
def decode_value(payload: Any) -> Any:
    """Read back a payload written by ``encode_value``."""
    encoding = payload.get("encoding") if isinstance(payload, dict) else None
    try:
        if encoding == "json":
            return payload["data"]
        if encoding == "repr":
            return OpaqueValue(type_name=payload["type"], text=payload["text"])
        if encoding == "arrow":
            return _from_arrow_ipc(
                base64.b64decode(payload["data"]), payload.get("library", "")
            )
    except (KeyError, TypeError, ValueError) as error:
        raise ProtocolError(f"malformed value payload: {error}") from error
    raise ProtocolError(f"unknown value encoding: {encoding!r}")


# Recognized without importing anything: a value can only be a pandas frame
# if pandas is already imported, and forcing the import here would make the
# worker pay for a library the code it ran never asked for.
def _frame_library(value: Any) -> str | None:
    for library, name in _FRAME_TYPES.items():
        module = sys.modules.get(library)
        frame_type = getattr(module, name, None)
        if frame_type is not None and isinstance(value, frame_type):
            return library
    return None


def _to_arrow_ipc(frame: Any, library: str) -> bytes:
    pyarrow = importlib.import_module("pyarrow")
    if library == "pandas":
        table = pyarrow.Table.from_pandas(frame)
    elif library == "polars":
        table = frame.to_arrow()
    else:
        table = frame
    sink = pyarrow.BufferOutputStream()
    with pyarrow.ipc.new_stream(sink, table.schema) as writer:
        writer.write_table(table)
    return sink.getvalue().to_pybytes()


def _from_arrow_ipc(data: bytes, library: str) -> Any:
    if library not in _FRAME_TYPES:
        raise ProtocolError(f"unknown frame library: {library!r}")
    pyarrow = importlib.import_module("pyarrow")
    table = pyarrow.ipc.open_stream(pyarrow.py_buffer(data)).read_all()
    if library == "pandas":
        return table.to_pandas()
    if library == "polars":
        return importlib.import_module("polars").from_arrow(table)
    return table


def encode_message(message: Message) -> bytes:
    """Render ``message`` as the single line that carries it."""
    body: dict[str, Any] = {"type": _NAMES[type(message)], **vars(message)}
    for name in _VALUE_FIELDS.get(type(message), ()):
        body[name] = encode_value(body[name])
    for name in _VALUE_MAPS.get(type(message), ()):
        body[name] = {key: encode_value(item) for key, item in body[name].items()}
    # `ensure_ascii` is what keeps the line a line: it escapes every newline
    # inside a string, so only the terminator below is a real one.
    return json.dumps(body, ensure_ascii=True).encode() + b"\n"


def decode_message(line: bytes | str) -> Message:
    """Read back a line written by ``encode_message``."""
    try:
        body = json.loads(line)
    except ValueError as error:  # bad JSON, and bad UTF-8 under it
        raise ProtocolError(f"not a protocol message: {line!r}") from error
    if not isinstance(body, dict):
        raise ProtocolError(f"not a protocol message: {line!r}")
    kind = body.pop("type", None)
    cls = _TYPES.get(kind) if isinstance(kind, str) else None
    if cls is None:
        raise ProtocolError(f"unknown message type: {kind!r}")
    # Every field below came off the channel, so none of its shape is
    # guaranteed: a wrong type has to arrive as a protocol error rather than
    # as whatever the codec happens to raise first.
    try:
        for name in _TEXT_FIELDS.get(cls, ()):
            if name in body and not isinstance(body[name], str):
                raise TypeError(f"{name} must be a string")
        for name in _VALUE_FIELDS.get(cls, ()):
            if name in body:
                body[name] = decode_value(body[name])
        for name in _VALUE_MAPS.get(cls, ()):
            if name in body:
                body[name] = {
                    key: decode_value(item) for key, item in body[name].items()
                }
        return cls(**body)
    except (AttributeError, TypeError) as error:
        raise ProtocolError(f"malformed {kind} message: {error}") from error


async def read_message(reader: asyncio.StreamReader) -> Message | None:
    """Read the next message, or ``None`` once the channel is done.

    A worker that has exited is the ordinary way a channel ends, so that is
    an answer rather than an exception. A line past ``STREAM_LIMIT`` leaves
    the stream part-way through a message with no way to find the next
    boundary, so the channel cannot be used again after that error.
    """
    try:
        line = await reader.readline()
    except ValueError as error:
        raise ProtocolError(
            f"a message was longer than the channel allows ({STREAM_LIMIT} bytes)"
        ) from error
    if not line:
        return None
    return decode_message(line)


async def write_message(writer: asyncio.StreamWriter, message: Message) -> None:
    """Send ``message``, waiting for the far end to keep up."""
    writer.write(encode_message(message))
    await writer.drain()
