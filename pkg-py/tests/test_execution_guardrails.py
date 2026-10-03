"""Guardrails: the best-effort checks a worker gets when it cannot be sandboxed.

Each test runs a real worker in guardrails mode. The mode is chosen by
``protection_mode()``, which on a host that can sandbox never picks it, so
the backend is built with that one decision overridden.
"""

from __future__ import annotations

import os

import pytest

from commons._execution import _backend
from commons._execution._backend import LocalBackend, Network
from commons._execution._driver import Worker
from commons._execution._protocol import Error, Result
from commons._handles import HandleStore

pytestmark = pytest.mark.skipif(
    os.name != "posix", reason="the worker's lifecycle is POSIX-shaped"
)


@pytest.fixture
def guarded(monkeypatch):
    def make(network: Network = "none") -> Worker:
        monkeypatch.setattr(_backend, "protection_mode", lambda: "guardrails")
        return Worker(network=network, backend=LocalBackend(), call_timeout=10)

    return make


async def denied(worker: Worker, code: str) -> str:
    reply = await worker.run(code)
    assert isinstance(reply, Error), f"{code!r} was allowed"
    assert "PermissionError" in reply.message
    return reply.message


async def test_the_worker_runs_in_guardrails_mode(guarded):
    async with guarded() as worker:
        reply = await worker.run("import sys; sys.argv[2]")
        assert isinstance(reply, Result)
        assert reply.value == "guardrails"


async def test_computation_and_scratch_files_are_allowed(guarded):
    async with guarded() as worker:
        code = (
            "import os, decimal\n"
            "with open(os.__file__) as f: first = f.readline()\n"
            "with open('notes.txt', 'w') as f: f.write(first)\n"
            "os.mkdir('sub'); os.rename('notes.txt', 'sub/notes.txt')\n"
            "with open('sub/notes.txt') as f: copied = f.readline()\n"
            "copied == first, sorted(os.listdir('.')), sum(range(11))\n"
        )
        reply = await worker.run(code)
        assert isinstance(reply, Result), reply
        assert list(reply.value) == [True, ["sub"], 55]


async def test_files_outside_the_roots_are_denied(guarded, tmp_path):
    outside = tmp_path / "secret.txt"
    outside.write_text("secret")
    async with guarded() as worker:
        read = await denied(worker, f"open({str(outside)!r}).read()")
        assert "denied read access" in read
        write = await denied(worker, f"open({str(outside)!r}, 'w').write('x')")
        assert "denied write access" in write
        await denied(worker, f"import os; os.listdir({str(tmp_path)!r})")
        await denied(worker, f"import os; os.remove({str(outside)!r})")
    assert outside.read_text() == "secret"


async def test_the_interpreter_is_readable_but_not_writable(guarded):
    async with guarded() as worker:
        await denied(worker, "import os; open(os.__file__, 'a')")


async def test_a_symlink_out_of_the_scratch_directory_is_followed(guarded, tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "secret.txt").write_text("secret")
    async with guarded() as worker:
        # Model code cannot link to a target it may not read, so the host
        # makes the link, as a file it left in the scratch directory would.
        await denied(worker, f"import os; os.symlink({str(outside)!r}, 'mine')")
        reply = await worker.run("import os; os.getcwd()")
        assert isinstance(reply, Result)
        os.symlink(outside, os.path.join(reply.value, "link"))
        read = await denied(worker, "open('link/secret.txt').read()")
        assert "denied read access" in read
        write = await denied(worker, "open('link/new.txt', 'w')")
        assert "denied write access" in write
    assert not (outside / "new.txt").exists()


async def test_processes_are_denied(guarded):
    async with guarded() as worker:
        for code in (
            "import subprocess; subprocess.run(['true'])",
            "import os; os.system('true')",
        ):
            message = await denied(worker, code)
            assert "denied subprocess creation" in message


async def test_the_network_follows_the_configured_access(guarded):
    code = (
        "import socket\n"
        "with socket.socket() as s: s.bind(('127.0.0.1', 0)); bound = True\n"
        "bound\n"
    )
    async with guarded("none") as worker:
        message = await denied(worker, code)
        assert "denied network access" in message
        await denied(worker, "import urllib.request; urllib.request.urlopen('https://example.com', timeout=1)")
    async with guarded("full") as worker:
        reply = await worker.run(code)
        assert isinstance(reply, Result), reply
        assert reply.value is True


async def test_a_file_url_is_denied_even_with_full_network(guarded, tmp_path):
    outside = tmp_path / "secret.txt"
    outside.write_text("secret")
    async with guarded("full") as worker:
        message = await denied(
            worker,
            f"import urllib.request; urllib.request.urlopen('file://{outside}').read()",
        )
        assert "denied read access" in message


async def test_the_workers_own_work_between_calls_is_not_checked(guarded):
    # A frame handle is decoded, and its reply encoded, outside model code;
    # both import libraries and read files the checks would otherwise see.
    pd = pytest.importorskip("pandas")
    store = HandleStore()
    store.register(pd.DataFrame({"x": [1, 2, 3]}))
    async with guarded() as worker:
        reply = await worker.run("r1['x'].sum()", handles=store)
        assert isinstance(reply, Result), reply
        assert reply.value == 6

