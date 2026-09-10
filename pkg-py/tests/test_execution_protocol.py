"""The wire between the execution driver and its worker."""

from __future__ import annotations

import asyncio
import base64
import json
import os
import subprocess
import tempfile
from pathlib import Path

import pytest

from commons._execution import _protocol
from commons._execution._env import worker_command, worker_env
from commons._execution._protocol import (
    STREAM_LIMIT,
    Call,
    Error,
    OpaqueValue,
    ProtocolError,
    Ready,
    Result,
    decode_message,
    decode_value,
    encode_message,
    encode_value,
    read_message,
    write_message,
)


def round_trip(message):
    return decode_message(encode_message(message))


def test_a_call_carries_its_code_and_id():
    call = Call(id="c1", code="x = 1")
    assert round_trip(call) == call


def test_a_message_occupies_exactly_one_line():
    # The framing is the line, so code that itself contains newlines has to
    # survive as one: a stray newline would be read as a second message.
    encoded = encode_message(Call(id="c1", code="x = 1\ny = 2\n"))
    assert encoded.endswith(b"\n")
    assert b"\n" not in encoded[:-1]


def test_a_ready_announcement_round_trips():
    assert round_trip(Ready()) == Ready()


def test_a_result_carries_what_the_call_printed():
    result = Result(id="c1", value=42, stdout="hello\n", stderr="oops\n")
    assert round_trip(result) == result


def test_a_result_with_no_value_round_trips():
    assert round_trip(Result(id="c1")) == Result(id="c1")


def test_an_error_carries_its_traceback():
    error = Error(
        id="c1", message="NameError: name 'x' is not defined", traceback="..."
    )
    assert round_trip(error) == error


def test_an_unknown_message_type_is_refused():
    with pytest.raises(ProtocolError, match="unknown message type"):
        decode_message(b'{"type": "exec", "id": "c1"}\n')


def test_a_line_that_is_not_json_is_refused():
    # The worker shares stdout with model code until it redirects, so junk on
    # this channel is a real possibility and has to name itself as such.
    with pytest.raises(ProtocolError, match="not a protocol message"):
        decode_message(b"Traceback (most recent call last):\n")


def test_a_line_that_is_not_an_object_is_refused():
    with pytest.raises(ProtocolError, match="not a protocol message"):
        decode_message(b"[1, 2, 3]\n")


# --- values -----------------------------------------------------------------


@pytest.mark.parametrize(
    "value",
    [None, True, 0, -1, 3.5, "text", "", ["a", 1, None], {"k": [1, 2]}],
)
def test_a_json_shaped_value_crosses_unchanged(value):
    assert decode_value(encode_value(value)) == value


def test_a_pandas_frame_arrives_as_a_pandas_frame():
    pd = pytest.importorskip("pandas")
    frame = pd.DataFrame({"n": [1, 2, 3], "s": ["a", "b", "c"]})
    crossed = decode_value(encode_value(frame))
    assert isinstance(crossed, pd.DataFrame)
    pd.testing.assert_frame_equal(crossed, frame)


def test_a_polars_frame_arrives_as_a_polars_frame():
    pl = pytest.importorskip("polars")
    frame = pl.DataFrame({"n": [1, 2, 3], "s": ["a", "b", "c"]})
    crossed = decode_value(encode_value(frame))
    assert isinstance(crossed, pl.DataFrame)
    assert crossed.equals(frame)


def test_a_frame_keeps_its_column_types():
    pd = pytest.importorskip("pandas")
    frame = pd.DataFrame(
        {
            "when": pd.to_datetime(["2026-01-01", "2026-06-30"]),
            "how_many": [1, 2],
            "how_much": [1.5, 2.5],
            "whether": [True, False],
        }
    )
    crossed = decode_value(encode_value(frame))
    assert list(crossed.dtypes) == list(frame.dtypes)


def test_a_value_that_cannot_cross_arrives_as_its_repr():
    # A REPL shows you the repr of a thing it cannot hand you, and that is
    # what is useful to the model too. Crossing it by reference is what the
    # design forbids; refusing it outright would fail a whole call over a
    # value the model may not even care about.
    crossed = decode_value(encode_value(object()))
    assert isinstance(crossed, OpaqueValue)
    assert crossed.type_name == "object"
    assert crossed.text.startswith("<object object at")


def test_encoding_a_value_never_asks_it_how_to_pickle_itself():
    # The security property the whole transport exists for: no pickle, in
    # either direction. `pickle.loads` runs the opcodes it is given, so a
    # pickle channel would let model-written code in the worker run code in
    # the parent.
    asked = []

    class Reducible:
        def __reduce__(self):
            asked.append("__reduce__")
            return (object, ())

        def __reduce_ex__(self, protocol):
            asked.append("__reduce_ex__")
            return (object, ())

    encode_value(Reducible())
    assert asked == []


def test_a_payload_with_an_unrecognized_encoding_is_refused():
    with pytest.raises(ProtocolError, match="unknown value encoding"):
        decode_value({"encoding": "pickle", "data": "gASVAA=="})


def test_a_frame_from_a_library_this_process_lacks_is_refused():
    payload = encode_value(pytest.importorskip("pandas").DataFrame({"n": [1]}))
    with pytest.raises(ProtocolError, match="nosuchframelib"):
        decode_value({**payload, "library": "nosuchframelib"})


def test_handles_ride_across_on_the_call_that_needs_them():
    pd = pytest.importorskip("pandas")
    call = Call(id="c1", code="r1.head()", handles={"r1": pd.DataFrame({"n": [1, 2]})})
    crossed = decode_message(encode_message(call))
    assert isinstance(crossed, Call)
    pd.testing.assert_frame_equal(crossed.handles["r1"], call.handles["r1"])


def test_a_frame_comes_back_as_the_result_of_a_call():
    pd = pytest.importorskip("pandas")
    result = Result(id="c1", value=pd.DataFrame({"n": [1, 2]}))
    crossed = decode_message(encode_message(result))
    assert isinstance(crossed, Result)
    pd.testing.assert_frame_equal(crossed.value, result.value)


# --- the channel ------------------------------------------------------------


def reader_for(*messages, limit=STREAM_LIMIT, eof=True):
    reader = asyncio.StreamReader(limit=limit)
    for message in messages:
        reader.feed_data(encode_message(message))
    if eof:
        reader.feed_eof()
    return reader


async def test_messages_are_read_back_one_at_a_time():
    reader = reader_for(Ready(), Result(id="c1", value=1))
    assert await read_message(reader) == Ready()
    assert await read_message(reader) == Result(id="c1", value=1)


async def test_the_end_of_the_channel_reads_as_no_message():
    # The worker dying is the ordinary way this happens, so it is an answer
    # rather than an exception.
    assert await read_message(reader_for()) is None


async def test_a_frame_larger_than_a_default_stream_buffer_still_crosses():
    pd = pytest.importorskip("pandas")
    frame = pd.DataFrame({"n": range(50_000)})
    message = Result(id="c1", value=frame)
    assert len(encode_message(message)) > 64 * 1024
    crossed = await read_message(reader_for(message))
    assert isinstance(crossed, Result)
    pd.testing.assert_frame_equal(crossed.value, frame)


async def test_a_message_past_the_channel_limit_says_so():
    reader = reader_for(Call(id="c1", code="x" * 4096), limit=1024)
    with pytest.raises(ProtocolError, match="longer than the channel allows"):
        await read_message(reader)


async def open_channel(limit=STREAM_LIMIT):
    """A real pipe, the shape the driver will hold onto the worker."""
    read_fd, write_fd = os.pipe()
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader(limit=limit)
    await loop.connect_read_pipe(
        lambda: asyncio.StreamReaderProtocol(reader), os.fdopen(read_fd, "rb")
    )
    transport, protocol = await loop.connect_write_pipe(
        asyncio.streams.FlowControlMixin, os.fdopen(write_fd, "wb")
    )
    return reader, asyncio.StreamWriter(transport, protocol, None, loop)


async def test_a_message_written_to_a_pipe_is_read_back_from_it():
    reader, writer = await open_channel()
    await write_message(writer, Call(id="c1", code="x = 1"))
    await write_message(writer, Ready())
    assert await read_message(reader) == Call(id="c1", code="x = 1")
    assert await read_message(reader) == Ready()
    writer.close()


def test_the_protocol_module_speaks_for_itself_without_commons():
    # The worker imports this module directly, under `-I`, with only its own
    # directory on the path: importing `commons` there would pull the agent's
    # dependencies into a process whose whole point is to hold nothing.
    directory = str(Path(_protocol.__file__).parent)
    probe = (
        "import sys, json;"
        f"sys.path.insert(0, {directory!r});"
        "import _protocol;"
        "print(json.dumps(sorted(m for m in sys.modules if m.startswith('commons'))))"
    )
    completed = subprocess.run(
        [*worker_command("-c"), probe],
        env=worker_env(tempfile.gettempdir()),
        check=False,
        capture_output=True,
        text=True,
    )
    assert completed.returncode == 0, completed.stderr
    assert json.loads(completed.stdout) == []


# --- malformed input --------------------------------------------------------

# Everything the driver reads was written by a process running model-written
# code, so a line that is the wrong shape has to name itself rather than
# surface as a `KeyError` from somewhere inside the codec.


def test_a_message_whose_type_is_not_a_name_is_refused():
    with pytest.raises(ProtocolError, match="unknown message type"):
        decode_message(b'{"type": [], "id": "c1"}\n')


def test_a_message_missing_a_field_its_type_needs_is_refused():
    with pytest.raises(ProtocolError, match="malformed call message"):
        decode_message(b'{"type": "call", "id": "c1"}\n')


def test_a_message_with_a_field_its_type_does_not_have_is_refused():
    with pytest.raises(ProtocolError, match="malformed ready message"):
        decode_message(b'{"type": "ready", "pid": 1}\n')


def test_a_value_payload_missing_its_contents_is_refused():
    with pytest.raises(ProtocolError, match="malformed value payload"):
        decode_value({"encoding": "json"})


def test_a_value_payload_that_is_not_a_payload_is_refused():
    with pytest.raises(ProtocolError, match="unknown value encoding"):
        decode_value("just a string")


def test_handles_that_are_not_a_mapping_are_refused():
    with pytest.raises(ProtocolError, match="malformed call message"):
        decode_message(b'{"type": "call", "id": "c1", "code": "x", "handles": "no"}\n')


def test_a_message_field_of_the_wrong_type_is_refused():
    # A driver keys its in-flight call on the id, so an id that is not a
    # string fails later, somewhere with no idea where the value came from.
    with pytest.raises(ProtocolError, match="malformed result message"):
        decode_message(b'{"type": "result", "id": {}}\n')


def test_a_line_that_is_not_utf_8_is_refused():
    with pytest.raises(ProtocolError, match="not a protocol message"):
        decode_message(b'{"type": "ready\xff"}\n')


def test_a_frame_arrow_cannot_hold_crosses_as_its_repr():
    # The fallback is the whole codec's contract, and a frame is not exempt:
    # one unconvertible column should cost the value, not the call.
    pd = pytest.importorskip("pandas")

    class Unconvertible:
        def __repr__(self):
            return "<unconvertible>"

    frame = pd.DataFrame({"o": [Unconvertible(), Unconvertible()]})
    crossed = decode_value(encode_value(frame))
    assert isinstance(crossed, OpaqueValue)
    assert crossed.type_name == "DataFrame"


def test_a_frame_of_a_type_arrow_has_no_mapping_for_crosses_as_its_repr():
    # Arrow says "invalid" for a value it cannot infer a type for and "not
    # implemented" for a type it knows and does not carry. Complex numbers
    # are the second kind, and the fallback owes them the same treatment.
    pd = pytest.importorskip("pandas")
    frame = pd.DataFrame({"z": [1 + 2j, 3 + 4j]})
    crossed = decode_value(encode_value(frame))
    assert isinstance(crossed, OpaqueValue)
    assert crossed.type_name == "DataFrame"


@pytest.mark.parametrize(
    "data",
    ["!!!!", base64.b64encode(b"not an arrow stream").decode()],
    ids=["not base64", "not arrow"],
)
def test_a_malformed_arrow_payload_is_refused(data):
    with pytest.raises(ProtocolError, match="malformed value payload"):
        decode_value({"encoding": "arrow", "library": "pandas", "data": data})
