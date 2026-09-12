"""The wire between the execution driver and its worker."""

from __future__ import annotations

import asyncio
import base64
import json
import math
import os
import random
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

from commons._execution import _protocol
from commons._execution._env import worker_command, worker_env
from commons._execution._protocol import (
    STREAM_LIMIT,
    Call,
    ChannelError,
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


def test_a_refusal_does_not_carry_the_whole_line():
    # The line is adversary-chosen and can be megabytes long; it has no
    # business landing whole in a log, a trace, or a model's context.
    with pytest.raises(ProtocolError) as excinfo:
        decode_message(b"!" * (2 * 1024 * 1024) + b"\n")
    assert len(str(excinfo.value)) < 1000


def test_something_that_is_not_a_message_is_refused():
    with pytest.raises(ProtocolError, match="not a message this protocol defines"):
        encode_message("hello")  # pyrefly: ignore[bad-argument-type]


# --- values -----------------------------------------------------------------


@pytest.mark.parametrize(
    "value",
    [None, True, 0, -1, 3.5, "text", "", ["a", 1, None], {"k": [1, 2]}],
)
def test_a_json_shaped_value_crosses_unchanged(value):
    assert decode_value(encode_value(value)) == value


def test_containers_arrive_in_their_json_shape():
    # `encode_value` alone stores the live object; the documented coercions
    # only happen once JSON actually carries the value, so this goes over
    # the wire.
    result = Result(id="c1", value={"pair": (1, 2), 1: "one"})
    crossed = decode_message(encode_message(result))
    assert isinstance(crossed, Result)
    assert crossed.value == {"pair": [1, 2], "1": "one"}


def test_a_dict_holding_a_frame_crosses_as_its_repr():
    # Containers cross as JSON only when JSON can hold the whole of them; a
    # frame inside a dict costs the dict, not the call.
    pd = pytest.importorskip("pandas")
    crossed = decode_value(encode_value({"frame": pd.DataFrame({"n": [1]})}))
    assert isinstance(crossed, OpaqueValue)
    assert crossed.type_name == "dict"


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


def test_a_pyarrow_table_arrives_as_a_pyarrow_table():
    pa = pytest.importorskip("pyarrow")
    table = pa.table({"n": [1, 2, 3], "s": ["a", "b", "c"]})
    crossed = decode_value(encode_value(table))
    assert isinstance(crossed, pa.Table)
    assert crossed.equals(table)


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


def test_a_frame_with_duplicate_column_names_keeps_its_data():
    # `pd.concat(axis=1)` output is too ordinary to lose: Arrow can hold
    # duplicate field names, so the columns are renamed the way pandas
    # itself would rename them.
    pd = pytest.importorskip("pandas")
    frame = pd.DataFrame([[1, 2]], columns=["a", "a"])
    crossed = decode_value(encode_value(frame))
    assert isinstance(crossed, pd.DataFrame)
    assert crossed.iloc[0].tolist() == [1, 2]
    assert len(set(crossed.columns)) == 2


def test_a_pandas_series_arrives_as_a_one_column_frame():
    pd = pytest.importorskip("pandas")
    crossed = decode_value(encode_value(pd.Series([1, 2, 3], name="n")))
    assert isinstance(crossed, pd.DataFrame)
    assert list(crossed.columns) == ["n"]
    assert crossed["n"].tolist() == [1, 2, 3]


def test_a_polars_series_arrives_as_a_one_column_frame():
    pl = pytest.importorskip("polars")
    crossed = decode_value(encode_value(pl.Series("n", [1, 2, 3])))
    assert isinstance(crossed, pl.DataFrame)
    assert crossed.columns == ["n"]
    assert crossed["n"].to_list() == [1, 2, 3]


def test_a_numpy_integer_result_crosses_as_a_json_number():
    # `df["a"].sum()` is an int64: a JSON number in every respect but its
    # class, and the commonest scalar result in data work.
    np = pytest.importorskip("numpy")
    crossed = decode_value(encode_value(np.int64(6)))
    assert crossed == 6
    assert type(crossed) is int


def test_a_numpy_float_crosses_as_a_json_number():
    np = pytest.importorskip("numpy")
    crossed = decode_value(encode_value(np.float32(2.5)))
    assert crossed == 2.5
    assert type(crossed) is float


def test_a_numpy_array_crosses_as_a_json_list():
    np = pytest.importorskip("numpy")
    crossed = decode_value(encode_value(np.array([[1, 2], [3, 4]])))
    assert crossed == [[1, 2], [3, 4]]


def test_a_value_that_cannot_cross_arrives_as_its_repr():
    # A REPL shows you the repr of a thing it cannot hand you, and that is
    # what is useful to the model too. Crossing it by reference is what the
    # design forbids; refusing it outright would fail a whole call over a
    # value the model may not even care about.
    crossed = decode_value(encode_value(object()))
    assert isinstance(crossed, OpaqueValue)
    assert crossed.type_name == "object"
    assert crossed.text.startswith("<object object at")


def test_a_value_whose_repr_raises_still_crosses():
    class Hostile:
        def __repr__(self):
            raise RuntimeError("no repr for you")

    crossed = decode_value(encode_value(Hostile()))
    assert isinstance(crossed, OpaqueValue)
    assert crossed.type_name == "Hostile"
    assert "repr raised" in crossed.text


def test_an_impossibly_large_integer_crosses_as_text():
    # `json.dumps` refuses an int past the interpreter's digit limit, and
    # `repr` refuses it too; neither may cost the call.
    crossed = decode_value(encode_value(math.factorial(2000)))
    assert isinstance(crossed, OpaqueValue)
    assert crossed.type_name == "int"


def test_a_deeply_nested_container_crosses_as_text():
    # Built iteratively: `json.dumps` answers deep nesting with
    # `RecursionError`, not `ValueError`, and so does `repr` — neither may
    # cost the call.
    value = []
    for _ in range(60000):
        value = [value]
    crossed = decode_value(encode_value(value))
    assert isinstance(crossed, OpaqueValue)
    assert crossed.type_name == "list"


def test_a_value_pretending_to_be_a_frame_crosses_as_its_repr():
    # `__class__` is assignable, so `isinstance` is model-controlled input,
    # not proof: the failure has to land in the fallback, not escape it.
    pd = pytest.importorskip("pandas")

    class Fake:
        __class__ = pd.DataFrame

    crossed = decode_value(encode_value(Fake()))
    assert isinstance(crossed, OpaqueValue)


def test_a_value_pretending_to_be_a_series_crosses_as_its_repr():
    pd = pytest.importorskip("pandas")

    class Fake:
        __class__ = pd.Series

    crossed = decode_value(encode_value(Fake()))
    assert isinstance(crossed, OpaqueValue)


def test_a_value_pretending_to_be_opaque_crosses_as_its_repr():
    class Fake:
        __class__ = OpaqueValue  # pyrefly: ignore[bad-override]

    crossed = decode_value(encode_value(Fake()))
    assert isinstance(crossed, OpaqueValue)
    assert crossed.type_name == "Fake"


def test_an_opaque_value_sent_again_crosses_unchanged():
    # A driver hands earlier results back as handles; a second pass over an
    # OpaqueValue must not wrap its repr in another OpaqueValue.
    opaque = OpaqueValue(type_name="object", text="<object object at 0x0>")
    assert decode_value(encode_value(opaque)) == opaque


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


def test_a_frame_from_a_library_the_protocol_does_not_know_is_refused():
    payload = encode_value(pytest.importorskip("pandas").DataFrame({"n": [1]}))
    with pytest.raises(ProtocolError, match="nosuchframelib"):
        decode_value({**payload, "library": "nosuchframelib"})


def test_a_frame_naming_a_library_the_process_cannot_import_is_refused():
    # `pandas` and `polars` are not runtime dependencies, so a payload
    # naming one can reach a driver that lacks it; that has to be a
    # protocol error, not a `ModuleNotFoundError` escaping the codec.
    pl = pytest.importorskip("polars")
    payload = encode_value(pl.DataFrame({"n": [1]}))

    class BlockPolars:
        def find_spec(self, fullname, path=None, target=None):
            if fullname == "polars":
                raise ModuleNotFoundError("No module named 'polars'")

    removed = sys.modules.pop("polars")
    sys.meta_path.insert(0, BlockPolars())
    try:
        with pytest.raises(ProtocolError, match="malformed value payload"):
            decode_value(payload)
    finally:
        sys.meta_path.pop(0)
        sys.modules["polars"] = removed


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


# --- the channel's size limits ----------------------------------------------


def test_a_frame_too_large_for_the_channel_crosses_as_its_repr():
    pd = pytest.importorskip("pandas")
    frame = pd.DataFrame({"n": range(10_000_000)})  # ~80 MB as Arrow
    crossed = decode_message(encode_message(Result(id="c1", value=frame, stdout="kept\n")))
    assert isinstance(crossed, Result)
    assert isinstance(crossed.value, OpaqueValue)
    assert crossed.value.type_name == "DataFrame"
    assert crossed.stdout == "kept\n"


def test_output_too_large_for_the_channel_is_clipped():
    # stdout holds unbounded model output, so this is reachable without any
    # adversary. The value survives; the output is clipped, and says so.
    result = Result(id="c1", value=42, stdout="x" * (STREAM_LIMIT + 1000))
    line = encode_message(result)
    assert len(line) <= STREAM_LIMIT
    crossed = decode_message(line)
    assert isinstance(crossed, Result)
    assert crossed.value == 42
    assert crossed.stdout.endswith("channel limit]")


def test_a_handle_too_large_for_the_channel_crosses_as_its_repr():
    call = Call(id="c1", code="r1", handles={"r1": "x" * (STREAM_LIMIT + 1000)})
    crossed = decode_message(encode_message(call))
    assert isinstance(crossed, Call)
    assert isinstance(crossed.handles["r1"], OpaqueValue)
    assert crossed.handles["r1"].type_name == "str"


def test_a_call_carrying_too_much_code_is_refused():
    # Code is never clipped — a truncated program is worse than an unsent
    # one — so a message with nothing left to shrink is an error.
    with pytest.raises(ProtocolError, match="longer than the channel allows"):
        encode_message(Call(id="c1", code="x" * (STREAM_LIMIT + 1000)))


def test_an_error_message_too_large_for_the_channel_is_clipped():
    # `raise RuntimeError("x" * BIG)` in the worker must not cost the error
    # response itself.
    error = Error(id="c1", message="x" * (STREAM_LIMIT + 1000))
    line = encode_message(error)
    assert len(line) <= STREAM_LIMIT
    crossed = decode_message(line)
    assert isinstance(crossed, Error)
    assert crossed.message.endswith("channel limit]")


def _compressed_frame_payload(rows=12_000_000):
    pa = pytest.importorskip("pyarrow")
    table = pa.table({"z": pa.array([0] * rows, type=pa.int64())})
    sink = pa.BufferOutputStream()
    options = pa.ipc.IpcWriteOptions(compression="zstd")
    with pa.ipc.new_stream(sink, table.schema, options=options) as writer:
        writer.write_table(table)
    return {
        "encoding": "arrow",
        "library": "pyarrow",
        "data": base64.b64encode(sink.getvalue().to_pybytes()).decode("ascii"),
    }


def test_a_compressed_frame_decodes_within_the_default_limit():
    payload = _compressed_frame_payload()
    crossed = decode_value(payload)
    assert crossed.num_rows == 12_000_000


def test_a_compressed_frame_cannot_expand_past_the_decode_limit():
    # A line well under STREAM_LIMIT can decode to orders of magnitude
    # more, and the far end chooses the bytes; the cap has to fire before
    # the allocation, not after.
    payload = _compressed_frame_payload()
    assert len(json.dumps(payload)) < 64 * 1024
    with pytest.raises(ProtocolError, match="more than the channel allows"):
        decode_value(payload, max_frame_bytes=1024 * 1024)


def test_a_crafted_uncompressed_length_is_refused_before_decompression():
    # The uncompressed-length prefix is attacker-controlled, and a hostile
    # worker can write a huge one without ever holding the bytes. Rewrite
    # the bomb's prefix to claim a petabyte: the cap must hold anyway, from
    # the stream's own metadata, before pyarrow sees it.
    payload = _compressed_frame_payload()
    data = base64.b64decode(payload["data"])
    needle = (96_000_000).to_bytes(8, "little")
    at = data.index(needle)
    crafted = data[:at] + (1 << 50).to_bytes(8, "little") + data[at + 8 :]
    with pytest.raises(ProtocolError, match="declared"):
        decode_value({**payload, "data": base64.b64encode(crafted).decode("ascii")})


def test_a_lying_buffer_count_is_refused():
    # The buffers vector's count is attacker-controlled; it must be
    # validated against the message it lives in before it is iterated,
    # or a stream-sized payload can force allocations far past itself.
    payload = _compressed_frame_payload()
    data = base64.b64decode(payload["data"])
    pos = 0
    meta = b""
    batch = None
    while batch is None:
        assert _protocol._u32(data, pos) == 0xFFFFFFFF
        mlen = _protocol._u32(data, pos + 4)
        meta = data[pos + 8 : pos + 8 + mlen]
        body_length, batch = _protocol._ipc_message(meta)
        if batch is None:
            pos += 8 + mlen + body_length
    buffers_at = _protocol._table_field(meta, batch, 2)
    assert buffers_at is not None
    count_at = pos + 8 + buffers_at + _protocol._u32(meta, buffers_at)
    patched = data[:count_at] + (2**31).to_bytes(4, "little") + data[count_at + 4 :]
    with pytest.raises(ProtocolError, match="overruns"):
        decode_value({**payload, "data": base64.b64encode(patched).decode("ascii")})


def test_a_compressed_stream_with_incompressible_buffers_crosses():
    # pyarrow keeps a buffer that does not compress as raw blocks inside a
    # valid frame; a stream built that way must still cross.
    pa = pytest.importorskip("pyarrow")
    blob = random.Random(0).randbytes(100_000)
    table = pa.table({"b": pa.array([blob] * 4, type=pa.binary())})
    sink = pa.BufferOutputStream()
    options = pa.ipc.IpcWriteOptions(compression="zstd")
    with pa.ipc.new_stream(sink, table.schema, options=options) as writer:
        writer.write_table(table)
    payload = {
        "encoding": "arrow",
        "library": "pyarrow",
        "data": base64.b64encode(sink.getvalue().to_pybytes()).decode("ascii"),
    }
    crossed = decode_value(payload)
    assert crossed.equals(table)


def test_a_dictionary_encoded_frame_round_trips():
    # Categoricals cross as dictionary batches, which wrap a record batch
    # the pre-flight must still account.
    pd = pytest.importorskip("pandas")
    frame = pd.DataFrame({"c": pd.Categorical(["x", "y", "x", "z"])})
    crossed = decode_value(encode_value(frame))
    pd.testing.assert_frame_equal(crossed, frame)


def test_a_frame_of_nothing_but_none_round_trips():
    # An all-None column crosses as a batch with no buffers at all; the
    # pre-flight prices it at a pointer per row.
    pd = pytest.importorskip("pandas")
    frame = pd.DataFrame({"x": [None] * 1000})
    crossed = decode_value(encode_value(frame))
    pd.testing.assert_frame_equal(crossed, frame)


async def test_the_frame_limit_applies_to_lines_read_from_the_channel():
    pa = pytest.importorskip("pyarrow")
    table = pa.table({"z": pa.array([0] * 12_000_000, type=pa.int64())})
    sink = pa.BufferOutputStream()
    options = pa.ipc.IpcWriteOptions(compression="zstd")
    with pa.ipc.new_stream(sink, table.schema, options=options) as writer:
        writer.write_table(table)
    line = json.dumps(
        {
            "type": "result",
            "id": "c1",
            "value": {
                "encoding": "arrow",
                "library": "pyarrow",
                "data": base64.b64encode(sink.getvalue().to_pybytes()).decode("ascii"),
            },
        }
    ).encode() + b"\n"
    reader = asyncio.StreamReader(limit=STREAM_LIMIT)
    reader.feed_data(line)
    reader.feed_eof()
    with pytest.raises(ProtocolError, match="more than the channel allows"):
        await read_message(reader, max_frame_bytes=1024 * 1024)


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


async def test_a_message_past_the_channel_limit_breaks_the_channel():
    # An overrun is not a junk line: the reader has discarded bytes up to an
    # offset the far end chose, so no later message boundary can be trusted.
    reader = asyncio.StreamReader(limit=1024)
    reader.feed_data(b"x" * 4096 + b"\n")
    reader.feed_data(encode_message(Result(id="attacker-chosen", value="resync")))
    reader.feed_eof()
    with pytest.raises(ChannelError, match="longer than the channel allows"):
        await read_message(reader)
    with pytest.raises(ChannelError, match="must be abandoned"):
        await read_message(reader)


async def test_a_junk_line_does_not_break_the_channel():
    # The recoverable counterpart: only the bad message is lost.
    reader = asyncio.StreamReader(limit=STREAM_LIMIT)
    reader.feed_data(b"print() leaked onto the channel\n")
    reader.feed_data(encode_message(Ready()))
    reader.feed_eof()
    with pytest.raises(ProtocolError, match="not a protocol message"):
        await read_message(reader)
    assert await read_message(reader) == Ready()


async def open_channel(limit=STREAM_LIMIT):
    """A real pipe, the shape the driver will hold onto the worker."""
    read_fd, write_fd = os.pipe()
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader(limit=limit)
    read_transport, _ = await loop.connect_read_pipe(
        lambda: asyncio.StreamReaderProtocol(reader), os.fdopen(read_fd, "rb")
    )
    write_transport, protocol = await loop.connect_write_pipe(
        asyncio.streams.FlowControlMixin, os.fdopen(write_fd, "wb")
    )
    writer = asyncio.StreamWriter(write_transport, protocol, None, loop)
    return reader, writer, read_transport


async def test_a_message_written_to_a_pipe_is_read_back_from_it():
    reader, writer, read_transport = await open_channel()
    await write_message(writer, Call(id="c1", code="x = 1"))
    await write_message(writer, Ready())
    assert await read_message(reader) == Call(id="c1", code="x = 1")
    assert await read_message(reader) == Ready()
    writer.close()
    read_transport.close()


async def test_writing_after_the_far_end_is_gone_fails():
    # The worker dying mid-call is the ordinary way this happens; the write
    # has to say so, not hang or succeed into the void.
    _reader, writer, read_transport = await open_channel()
    read_transport.close()
    with pytest.raises(ConnectionError):
        for _ in range(10):
            await write_message(writer, Ready())
            await asyncio.sleep(0)


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


def test_a_deeply_nested_line_is_refused():
    # `json.loads` answers hostile nesting with `RecursionError`, not
    # `ValueError`; it is still a bad line, not an escape from the codec.
    line = (
        b'{"type": "result", "id": "c1", "value": {"encoding": "json", "data": '
        + b"[" * 120000
        + b"]" * 120000
        + b"}}"
    )
    with pytest.raises(ProtocolError, match="not a protocol message"):
        decode_message(line)


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
