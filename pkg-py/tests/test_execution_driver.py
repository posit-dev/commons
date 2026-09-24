"""The worker's lifecycle: lazy spawn, serialization, timeouts, respawn, and the reap.

Every test here runs a real worker process through the driver; none of the
machinery is mocked. Hosts that cannot sandbox the worker (and non-POSIX
hosts, whose interrupt escalation differs) skip the module.
"""

from __future__ import annotations

import asyncio
import os
import signal
import sys
import time
from datetime import date
from typing import Annotated

import pandas as pd
import pytest
from pydantic import Field

from commons import measure, semantic_layer
from commons._execution._backend import LocalBackend, LocalSession
from commons._execution._driver import Failure, Worker
from commons._execution._protocol import Error, Result
from commons._execution._sandbox import protection_mode
from commons._handles import HandleStore
from commons._measures import Injected


@measure(description="Total the x column.")
def total_x(df: Injected[pd.DataFrame]) -> float:
    return float(df["x"].sum())


DEFAULT_REGION = "EMEA"


@measure(description="Count orders in a region.")
def region_count(
    region: Annotated[str, Field(description="The region.")] = DEFAULT_REGION,
) -> int:
    return len(region)


@measure(description="Orders placed on or after a date.")
def orders_since(
    when: Annotated[date, Field(description="The cutoff.")] = date(2020, 1, 1),
) -> int:
    return 3


@measure(description="Count with a composed default.")
def composed_default(
    region: Annotated[str, Field(description="The region.")] = DEFAULT_REGION + "-west",
) -> int:
    return len(region)


@measure(description="Double a number.")
def double_n(n: Annotated[int, Field(description="The number.")] = 21) -> int:
    return 2 * n


try:
    _PROTECTION = protection_mode()
except RuntimeError:
    _PROTECTION = None

pytestmark = [
    pytest.mark.skipif(
        _PROTECTION is None, reason="this host cannot sandbox the worker"
    ),
    pytest.mark.skipif(
        os.name != "posix", reason="the interrupt escalation is POSIX-shaped"
    ),
]


def make_worker(**kwargs) -> Worker:
    """A worker with test-sized timeouts; kwargs override them."""
    kwargs.setdefault("call_timeout", 5)
    kwargs.setdefault("idle_timeout", 600)
    kwargs.setdefault("interrupt_grace", 2)
    return Worker(**kwargs)


def process_of(worker: Worker) -> asyncio.subprocess.Process:
    """The running worker's process, which the local backend exposes."""
    session = worker._session
    assert isinstance(session, LocalSession)
    return session.process


async def test_no_process_exists_until_the_first_call():
    async with make_worker() as worker:
        assert worker._session is None
        await worker.run("1")
        assert worker._session is not None


@pytest.mark.parametrize("network", ["none", "full"])
async def test_the_worker_is_started_with_its_network_access(network):
    # The backend passes the access level to the worker's entry point.
    async with make_worker(network=network) as worker:
        reply = await worker.run("import sys; sys.argv[1]")
        assert isinstance(reply, Result)
        assert reply.value == network


async def test_a_trailing_expression_is_the_result():
    async with make_worker() as worker:
        reply = await worker.run("6 * 7")
        assert isinstance(reply, Result)
        assert reply.value == 42


async def test_state_persists_across_calls():
    async with make_worker() as worker:
        await worker.run("x = 41")
        reply = await worker.run("x + 1")
        assert isinstance(reply, Result)
        assert reply.value == 42


async def test_the_codes_own_exception_is_an_error_not_a_failure():
    async with make_worker() as worker:
        reply = await worker.run("1 / 0")
        assert isinstance(reply, Error)
        assert "ZeroDivisionError" in reply.message


async def test_printed_output_comes_back_with_the_result():
    async with make_worker() as worker:
        reply = await worker.run("print('hello')")
        assert isinstance(reply, Result)
        assert reply.stdout == "hello\n"


async def test_calls_are_serialized_one_at_a_time():
    async with make_worker() as worker:
        first, second = await asyncio.gather(
            worker.run("import time; time.sleep(0.5); seen = 1"),
            worker.run("seen + 1"),
        )
        # Had the second call run alongside the first, `seen` would not
        # have been bound yet.
        assert isinstance(first, Result)
        assert isinstance(second, Result)
        assert second.value == 2


async def test_writing_fd_1_directly_cannot_corrupt_the_channel():
    async with make_worker() as worker:
        reply = await worker.run("import os; os.write(1, b'junk\\n'); 6 * 7")
        assert isinstance(reply, Result)
        assert reply.value == 42
        # The channel survived: the next call answers normally.
        reply = await worker.run("'still here'")
        assert isinstance(reply, Result)
        assert reply.value == "still here"


async def test_a_thread_printing_after_the_call_cannot_corrupt_the_channel():
    async with make_worker() as worker:
        code = (
            "import threading, time\n"
            "def late():\n"
            "    time.sleep(0.2)\n"
            "    print('junk from a late thread')\n"
            "threading.Thread(target=late).start()\n"
            "'started'\n"
        )
        reply = await worker.run(code)
        assert isinstance(reply, Result)
        await asyncio.sleep(1)
        reply = await worker.run("40 + 2")
        assert isinstance(reply, Result)
        assert reply.value == 42


async def test_a_thread_reading_stdin_cannot_steal_the_next_call():
    async with make_worker() as worker:
        code = (
            "import threading, os\n"
            "def thief():\n"
            "    while os.read(0, 4096):\n"
            "        pass\n"
            "threading.Thread(target=thief, daemon=True).start()\n"
            "'started'\n"
        )
        reply = await worker.run(code)
        assert isinstance(reply, Result)
        await asyncio.sleep(0.2)
        # The thief is blocked on the sink's EOF, not on the channel: the
        # next call's bytes reach the worker's loop.
        reply = await worker.run("40 + 2")
        assert isinstance(reply, Result)
        assert reply.value == 42


async def test_a_timeout_interrupts_the_call_and_keeps_the_session():
    async with make_worker(call_timeout=0.5) as worker:
        await worker.run("x = 5")
        reply = await worker.run("import time; time.sleep(60)")
        assert isinstance(reply, Failure)
        assert "interrupted" in reply.message
        assert "remain available" in reply.message
        # The interrupt left the session and its variables alive.
        reply = await worker.run("x")
        assert isinstance(reply, Result)
        assert reply.value == 5


async def test_an_interrupt_between_calls_leaves_the_session_alone():
    # The driver can interrupt a call just as it finishes, so the worker
    # receives the SIGINT once it is back to waiting for the next line.
    async with make_worker() as worker:
        await worker.run("x = 5")
        os.killpg(process_of(worker).pid, signal.SIGINT)
        await asyncio.sleep(0.3)
        reply = await worker.run("x")
        assert isinstance(reply, Result)
        assert reply.value == 5


async def test_a_host_that_ignores_sigint_still_gets_its_calls_interrupted():
    # A background job's shell starts it with SIGINT ignored, which a child
    # inherits; the worker must not lose its interrupt to that.
    previous = signal.signal(signal.SIGINT, signal.SIG_IGN)
    worker = make_worker(call_timeout=0.5)
    try:
        await worker.run("x = 5")
    finally:
        signal.signal(signal.SIGINT, previous)
    async with worker:
        reply = await worker.run("import time; time.sleep(60)")
        assert isinstance(reply, Failure)
        assert "remain available" in reply.message
        reply = await worker.run("x")
        assert isinstance(reply, Result)
        assert reply.value == 5


async def test_a_worker_that_ignores_the_interrupt_is_restarted():
    async with make_worker(call_timeout=0.5, interrupt_grace=1) as worker:
        await worker.run("x = 5")
        code = (
            "import signal, time\n"
            "signal.signal(signal.SIGINT, signal.SIG_IGN)\n"
            "time.sleep(60)\n"
        )
        reply = await worker.run(code)
        assert isinstance(reply, Failure)
        assert "did not respond" in reply.message
        assert "restarted" in reply.message
        # The restart reset the session: x is gone.
        reply = await worker.run("x")
        assert isinstance(reply, Error)
        assert "NameError" in reply.message


async def test_a_timed_out_call_takes_its_children_with_it():
    async with make_worker(call_timeout=0.5, interrupt_grace=2) as worker:
        probe = await worker.run(
            "import subprocess; subprocess.run(['/bin/echo', 'x']).returncode"
        )
        if not isinstance(probe, Result) or probe.value != 0:
            # The macOS sandbox aborts child processes outright, which also
            # settles the question this test asks.
            pytest.skip("the sandbox refuses child processes on this host")
        code = (
            "import subprocess\n"
            # The interrupt fires while the call waits on the child. If only
            # the worker receives it, the child survives to write the file.
            # Popen().wait() rather than run(), which kills its own child on
            # KeyboardInterrupt and would pass either way.
            "subprocess.Popen(['sh', '-c', 'sleep 1.5; touch survived']).wait()\n"
        )
        reply = await worker.run(code)
        assert isinstance(reply, Failure)
        assert "interrupted" in reply.message
        await asyncio.sleep(2)
        reply = await worker.run("import os; os.path.exists('survived')")
        assert isinstance(reply, Result)
        assert reply.value is False


async def test_a_crashed_workers_children_do_not_outlive_it():
    async with make_worker() as worker:
        probe = await worker.run(
            "import subprocess; subprocess.run(['/bin/echo', 'x']).returncode"
        )
        if not isinstance(probe, Result) or probe.value != 0:
            # The macOS sandbox aborts child processes outright, so there
            # is nothing to outlive the worker on this host.
            pytest.skip("the sandbox refuses child processes on this host")
        process = process_of(worker)
        code = "import subprocess, os\nsubprocess.Popen(['sleep', '30'])\nos._exit(1)\n"
        reply = await worker.run(code)
        assert isinstance(reply, Failure)
        # The shutdown killed the group, not just the leader. The kill is sent
        # before run() returns, but a killed child takes a moment to finish
        # exiting, and until then the group still exists.
        deadline = time.monotonic() + 2
        while True:
            try:
                os.killpg(process.pid, 0)
            except ProcessLookupError:
                break
            assert time.monotonic() < deadline, "a child outlived the crashed worker"
            await asyncio.sleep(0.01)


@pytest.mark.skipif(
    sys.platform == "darwin" and sys.version_info >= (3, 14),
    reason="asyncio on 3.14 reads macOS's waitid() report of a stopped child "
    "as an exit and blocks the event loop in waitpid() until it really exits",
)
async def test_a_worker_that_stops_reading_fails_the_call_instead_of_hanging():
    async with make_worker(call_timeout=0.5) as worker:
        await worker.run("1")
        process = process_of(worker)
        # A stopped worker cannot drain its stdin; a call bigger than the
        # pipe buffer would block the write forever without a bound on it.
        process.send_signal(signal.SIGSTOP)
        reply = await worker.run("x = " + "1" * (1024 * 1024))
        assert isinstance(reply, Failure)
        assert "stopped reading" in reply.message


async def test_a_crash_is_reported_and_the_next_call_respawns():
    async with make_worker() as worker:
        await worker.run("x = 5")
        reply = await worker.run("import os; os._exit(1)")
        assert isinstance(reply, Failure)
        assert "crashed" in reply.message
        reply = await worker.run("x")
        assert isinstance(reply, Error)
        assert "NameError" in reply.message


async def test_an_idle_worker_is_reaped_and_the_next_call_respawns():
    async with make_worker(idle_timeout=0.5) as worker:
        await worker.run("x = 5")
        process = process_of(worker)
        await asyncio.sleep(2)
        # The reaper closed the worker; nothing is running now.
        assert worker._session is None
        reply = await worker.run("x")
        # The respawned session has never seen x.
        assert isinstance(reply, Error)
        assert "NameError" in reply.message
        assert process_of(worker).pid != process.pid


async def test_the_reaper_leaves_a_worker_with_a_call_in_flight_alone():
    async with make_worker(idle_timeout=0.5, call_timeout=10) as worker:
        # The first call arms the idle timer; the second runs straight
        # through the moment it fires.
        await worker.run("1")
        reply = await worker.run("import time; time.sleep(2); 6 * 7")
        # The idle window passed mid-call, but the call was in flight, so
        # the worker lived to answer it.
        assert isinstance(reply, Result)
        assert reply.value == 42


async def test_measure_sources_are_defined_at_spawn_and_at_respawn():
    async with make_worker(measure_sources=["ANSWER = 42"], idle_timeout=0.5) as worker:
        reply = await worker.run("ANSWER")
        assert isinstance(reply, Result)
        assert reply.value == 42
        await asyncio.sleep(2)
        assert worker._session is None
        # The respawned worker was given the same sources at spawn.
        reply = await worker.run("ANSWER")
        assert isinstance(reply, Result)
        assert reply.value == 42


async def test_a_measure_source_that_fails_stops_the_spawn():
    async with make_worker(measure_sources=["1 / 0"]) as worker:
        reply = await worker.run("1")
        assert isinstance(reply, Failure)
        assert "failed to start" in reply.message
        assert "ZeroDivisionError" in reply.message


async def test_a_measure_source_that_ends_the_worker_stops_the_spawn():
    async with make_worker(measure_sources=["import os; os._exit(1)"]) as worker:
        reply = await worker.run("1")
        assert isinstance(reply, Failure)
        assert "exited while defining" in reply.message
        assert worker._session is None


async def test_a_worker_that_never_becomes_ready_fails_the_call(tmp_path):
    script = tmp_path / "worker.py"
    script.write_text("import time\ntime.sleep(60)\n")
    backend = LocalBackend(worker_script=script, terminate_grace=0.1)
    async with make_worker(backend=backend, spawn_timeout=0.5) as worker:
        reply = await worker.run("1")
        assert isinstance(reply, Failure)
        assert "stopped responding during startup" in reply.message
        assert worker._session is None


async def test_harvested_measure_sources_define_their_names():
    # The real harvest: decorated and annotated, with the decorator and
    # the annotation's import both absent from the worker's session.
    layer = semantic_layer([total_x])
    async with make_worker(measure_sources=list(layer.source_text.values())) as worker:
        reply = await worker.run("total_x.__name__")
        assert isinstance(reply, Result)
        assert reply.value == "total_x"


async def test_a_measure_default_naming_an_unharvested_global_still_defines():
    # DEFAULT_REGION is a module global rather than a function, so the
    # harvest never includes it; the define must not fail on it.
    layer = semantic_layer([region_count])
    async with make_worker(measure_sources=list(layer.source_text.values())) as worker:
        reply = await worker.run("region_count.__name__")
        assert isinstance(reply, Result)
        assert reply.value == "region_count"
        # The default stands in as a placeholder that names what is missing.
        reply = await worker.run("repr(region_count.__defaults__[0])")
        assert isinstance(reply, Result)
        assert "DEFAULT_REGION" in reply.value


async def test_a_compound_default_naming_an_unharvested_import_still_defines():
    # `date` is an import, so the harvest excludes it, and the default is a
    # call on top of the missing name: the placeholder must survive both.
    layer = semantic_layer([orders_since])
    async with make_worker(measure_sources=list(layer.source_text.values())) as worker:
        reply = await worker.run("orders_since.__name__")
        assert isinstance(reply, Result)
        assert reply.value == "orders_since"
        reply = await worker.run("repr(orders_since.__defaults__[0])")
        assert isinstance(reply, Result)
        assert "date" in reply.value


async def test_a_default_composed_from_an_unharvested_global_still_defines():
    layer = semantic_layer([composed_default])
    async with make_worker(measure_sources=list(layer.source_text.values())) as worker:
        reply = await worker.run("composed_default.__name__")
        assert isinstance(reply, Result)
        reply = await worker.run("repr(composed_default.__defaults__[0])")
        assert isinstance(reply, Result)
        assert "DEFAULT_REGION" in reply.value


async def test_lambda_and_keyword_only_defaults_naming_unharvested_globals_define(
    tmp_path,
):
    # The harvest keeps module-level lambdas as well as defs, and a default
    # in either shape is evaluated as the source is defined.
    module = tmp_path / "scaled.py"
    module.write_text(
        "from typing import Annotated\n"
        "from pydantic import Field\n"
        "from commons import measure\n"
        "\n"
        "FACTOR = 2\n"
        "scale = lambda x, k=FACTOR: x * k\n"
        "\n"
        '@measure(description="Scaled orders.")\n'
        "def scaled(\n"
        '    *, n: Annotated[int, Field(description="Count.")] = FACTOR\n'
        ") -> int:\n"
        "    return scale(n)\n"
    )
    layer = semantic_layer(module)
    async with make_worker(measure_sources=list(layer.source_text.values())) as worker:
        reply = await worker.run("scale(3, k=2)")
        assert isinstance(reply, Result)
        assert reply.value == 6
        reply = await worker.run(
            "repr(scale.__defaults__[0]) + repr(scaled.__kwdefaults__['n'])"
        )
        assert isinstance(reply, Result)
        assert reply.value.count("FACTOR") == 2


async def test_a_default_that_resolves_keeps_its_real_value():
    layer = semantic_layer([double_n])
    async with make_worker(measure_sources=list(layer.source_text.values())) as worker:
        # The guard around a default that evaluates fine is invisible.
        reply = await worker.run("double_n()")
        assert isinstance(reply, Result)
        assert reply.value == 42


async def test_a_failed_start_reports_the_workers_stderr(tmp_path):
    script = tmp_path / "worker.py"
    script.write_text(
        "import sys\nprint('boom: the sandbox refused', file=sys.stderr)\nsys.exit(3)\n"
    )
    async with make_worker(backend=LocalBackend(worker_script=script)) as worker:
        reply = await worker.run("1")
        assert isinstance(reply, Failure)
        assert "failed to start" in reply.message
        assert "boom: the sandbox refused" in reply.message


async def test_handles_are_sent_with_the_call():
    store = HandleStore()
    store.register(41)
    async with make_worker() as worker:
        reply = await worker.run("r1 + 1", handles=store)
        assert isinstance(reply, Result)
        assert reply.value == 42
        # A handle registered later syncs on the next call; the first one
        # is still there.
        store.register(100)
        reply = await worker.run("r1 + r2", handles=store)
        assert isinstance(reply, Result)
        assert reply.value == 141


async def test_handles_are_resent_to_a_respawned_worker():
    store = HandleStore()
    store.register(41)
    async with make_worker(idle_timeout=0.5) as worker:
        reply = await worker.run("r1", handles=store)
        assert isinstance(reply, Result)
        await asyncio.sleep(2)
        assert worker._session is None
        reply = await worker.run("r1 + 1", handles=store)
        assert isinstance(reply, Result)
        assert reply.value == 42


async def test_closing_the_worker_removes_its_scratch_directory():
    worker = make_worker()
    reply = await worker.run("import os; os.getcwd()")
    assert isinstance(reply, Result)
    scratch = reply.value
    assert os.path.isdir(scratch)
    await worker.aclose()
    assert not os.path.exists(scratch)


async def test_a_reaped_workers_scratch_directory_is_removed():
    async with make_worker(idle_timeout=0.5) as worker:
        reply = await worker.run("import os; os.getcwd()")
        assert isinstance(reply, Result)
        scratch = reply.value
        await asyncio.sleep(2)
        assert worker._session is None
        assert not os.path.exists(scratch)


async def test_aclose_during_a_reap_still_kills_a_sigterm_ignoring_worker():
    worker = make_worker(idle_timeout=0.2)
    await worker.run("import signal; signal.signal(signal.SIGTERM, signal.SIG_IGN)")
    process = process_of(worker)
    # Wait for the reap to begin (it clears the process synchronously),
    # then close while its SIGTERM grace window is still open. Cancelling
    # the reaper must not strand the worker before its SIGKILL.
    deadline = asyncio.get_running_loop().time() + 5
    while worker._session is not None:
        assert asyncio.get_running_loop().time() < deadline
        await asyncio.sleep(0.05)
    await worker.aclose()
    assert process.returncode is not None


async def test_cancelling_a_call_shuts_the_worker_down():
    async with make_worker() as worker:
        await worker.run("x = 5")
        call = asyncio.ensure_future(worker.run("import time; time.sleep(30)"))
        await asyncio.sleep(0.2)
        call.cancel()
        with pytest.raises(asyncio.CancelledError):
            await call
        # The cancelled call's worker is gone rather than still computing,
        # so its late reply cannot poison the next call's channel.
        assert worker._session is None
        reply = await worker.run("x")
        assert isinstance(reply, Error)
        assert "NameError" in reply.message


async def test_a_closed_worker_stays_closed():
    worker = make_worker()
    await worker.run("1")
    await worker.aclose()
    reply = await worker.run("1")
    assert isinstance(reply, Failure)
    assert "closed" in reply.message


async def test_cancelling_aclose_still_closes_the_worker():
    worker = make_worker()
    call = asyncio.ensure_future(worker.run("import time; time.sleep(1); 1"))
    await asyncio.sleep(0.2)
    closing = asyncio.ensure_future(worker.aclose())
    await asyncio.sleep(0.2)
    # The close is waiting out the in-flight call when it is cancelled. The
    # cancellation reaches aclose()'s caller, and the close still happens
    # once the call finishes.
    process = process_of(worker)
    closing.cancel()
    with pytest.raises(asyncio.CancelledError):
        await closing
    reply = await call
    assert isinstance(reply, Result)
    # The cancelled close finishes on its own; nothing calls aclose() again
    # until it has.
    await asyncio.wait_for(process.wait(), 5)
    assert worker._session is None
    await worker.aclose()


async def test_a_call_queued_behind_aclose_does_not_start_a_worker():
    worker = make_worker()
    first = asyncio.ensure_future(worker.run("import time; time.sleep(0.5); 1"))
    await asyncio.sleep(0.2)
    queued = asyncio.ensure_future(worker.run("2"))
    await asyncio.sleep(0)
    await worker.aclose()
    assert isinstance(await first, Result)
    reply = await queued
    assert isinstance(reply, Failure)
    assert "closed" in reply.message
    assert worker._session is None


async def test_aclose_waits_for_a_spawn_in_flight():
    worker = make_worker()
    call = asyncio.ensure_future(worker.run("1"))
    await asyncio.sleep(0)
    await worker.aclose()
    # However the two interleaved, the close waited the call out and no
    # worker outlived it.
    await call
    assert worker._session is None


async def test_aclose_during_a_failing_spawn_does_not_deadlock(tmp_path):
    script = tmp_path / "worker.py"
    script.write_text("import sys\nsys.exit(3)\n")
    worker = make_worker(backend=LocalBackend(worker_script=script))
    call = asyncio.ensure_future(worker.run("1"))
    await asyncio.sleep(0)
    closing = asyncio.ensure_future(worker.aclose())
    # asyncio.wait bounds the two together without cancelling either, so
    # a deadlock shows up as a task left pending.
    done, _ = await asyncio.wait({call, closing}, timeout=10)
    assert done == {call, closing}
    assert isinstance(call.result(), Failure)
    assert worker._session is None


async def test_cancelling_during_the_spawn_leaves_nothing_tracked():
    async with make_worker() as worker:
        call = asyncio.ensure_future(worker.run("1"))
        await asyncio.sleep(0)
        call.cancel()
        with pytest.raises(asyncio.CancelledError):
            await call
        # Whether the call was cancelled before or during the spawn,
        # nothing half-started survives it.
        assert worker._session is None
        reply = await worker.run("6 * 7")
        assert isinstance(reply, Result)
        assert reply.value == 42


async def test_a_worker_that_died_between_calls_loses_its_scratch_directory():
    async with make_worker() as worker:
        reply = await worker.run("import os; os.getcwd()")
        assert isinstance(reply, Result)
        scratch = reply.value
        process = process_of(worker)
        process.kill()
        await process.wait()
        # The next call spawns a replacement, and the dead worker's
        # scratch directory goes with it.
        reply = await worker.run("1 + 1")
        assert isinstance(reply, Result)
        assert not os.path.exists(scratch)


# Model code can reach the worker's own module, and with it the protocol
# channel; these tests use that to put a bad line on the channel on demand.
WORKER_MODULE = "import sys, os; w = sys.modules['__main__']\n"
BOGUS_REPLY = "w._send(w._protocol.Result(id='bogus', value=1, stdout='', stderr=''))\n"


async def test_a_reply_that_does_not_parse_restarts_the_worker():
    async with make_worker() as worker:
        await worker.run("x = 5")
        reply = await worker.run(
            WORKER_MODULE + "os.write(w._PROTOCOL_OUT, b'garbage\\n')\n1"
        )
        assert isinstance(reply, Failure)
        assert "does not parse" in reply.message
        reply = await worker.run("x")
        assert isinstance(reply, Error)
        assert "NameError" in reply.message


async def test_a_reply_out_of_turn_restarts_the_worker():
    # Were the stale reply trusted, the next call would read this call's
    # real answer as its own.
    async with make_worker() as worker:
        await worker.run("x = 5")
        reply = await worker.run(WORKER_MODULE + BOGUS_REPLY + "1")
        assert isinstance(reply, Failure)
        assert "out of turn" in reply.message
        reply = await worker.run("x")
        assert isinstance(reply, Error)
        assert "NameError" in reply.message


async def test_a_worker_that_dies_on_the_interrupt_is_reported_as_crashed():
    async with make_worker(call_timeout=0.5) as worker:
        code = (
            "import os, signal, time\n"
            "signal.signal(signal.SIGINT, lambda *a: os._exit(1))\n"
            "time.sleep(60)\n"
        )
        reply = await worker.run(code)
        assert isinstance(reply, Failure)
        assert "crashed" in reply.message
        assert worker._session is None


async def test_an_out_of_turn_answer_to_the_interrupt_restarts_the_worker():
    async with make_worker(call_timeout=0.5) as worker:
        code = (
            WORKER_MODULE
            + "import signal, time\n"
            + "signal.signal(signal.SIGINT, lambda *a: "
            + BOGUS_REPLY.strip()
            + ")\n"
            + "time.sleep(60)\n"
        )
        reply = await worker.run(code)
        assert isinstance(reply, Failure)
        assert "out of turn" in reply.message
        assert worker._session is None


async def test_a_line_the_worker_cannot_decode_costs_only_that_line():
    async with make_worker() as worker:
        await worker.run("x = 5")
        session = worker._session
        assert session is not None
        session.stdin.write(b"garbage\n")
        reply = await worker.run("x")
        assert isinstance(reply, Result)
        assert reply.value == 5


async def test_a_call_the_worker_cannot_decode_is_answered_with_an_error():
    # The driver is waiting on this id; without an answer it would wait out
    # the whole call timeout and then the interrupt grace.
    backend = LocalBackend()
    session = await backend.start(network="none")
    try:
        ready = await asyncio.wait_for(session.stdout.readline(), 10)
        assert b'"ready"' in ready
        session.stdin.write(b'{"type": "call", "id": "c1", "code": 5}\n')
        reply = await asyncio.wait_for(session.stdout.readline(), 5)
        assert b'"error"' in reply
        assert b'"c1"' in reply
        assert b"could not be decoded" in reply
    finally:
        await session.close()


async def test_a_call_without_handles_leaves_the_synced_handles_alone():
    # A call that passes no store must not make the next one resend the
    # store, which would overwrite a handle the model reassigned.
    store = HandleStore()
    store.register(41)
    async with make_worker() as worker:
        await worker.run("r1 = 0", handles=store)
        await worker.run("1")
        reply = await worker.run("r1", handles=store)
        assert isinstance(reply, Result)
        assert reply.value == 0


async def test_a_different_store_is_synced_from_its_start():
    first, second = HandleStore(), HandleStore()
    first.register(41)
    second.register(7)
    async with make_worker() as worker:
        await worker.run("r1", handles=first)
        reply = await worker.run("r1", handles=second)
        assert isinstance(reply, Result)
        assert reply.value == 7


async def test_handles_too_large_for_one_message_all_reach_the_worker(monkeypatch):
    # Each handle fits the channel on its own, but together they do not; sent
    # in one message they would be shrunk to reprs. The limit is lowered in
    # the driver alone, which is the side that shrinks.
    import numpy as np

    from commons._execution import _protocol

    monkeypatch.setattr(_protocol, "STREAM_LIMIT", 150_000)
    frame = pd.DataFrame({"x": np.random.default_rng(0).integers(0, 2**62, 20000)})
    store = HandleStore()
    store.register(frame)
    store.register(frame.copy())
    async with make_worker() as worker:
        reply = await worker.run(
            "type(r1).__name__, type(r2).__name__, len(r2)", handles=store
        )
        assert isinstance(reply, Result)
        assert list(reply.value) == ["DataFrame", "DataFrame", len(store.get("r2"))]
