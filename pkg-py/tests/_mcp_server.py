"""Real HTTP service harness shared by MCP and Connect tests."""

from __future__ import annotations

import os
import socket
import subprocess
import sys
import time
from collections.abc import Iterator
from pathlib import Path

import httpx
import pytest

API_KEY = "test-mcp-admin-not-a-default"
PROXY_KEY = "test-connect-api-key"
AUTH_HEADERS = {"X-API-Key": API_KEY}
PACKAGE_ROOT = Path(__file__).resolve().parents[1]


def _await_demo(process: subprocess.Popen[str], base_url: str, log_path: Path) -> None:
    deadline = time.monotonic() + 15
    last_error = "server did not answer"
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"Demo server exited early:\n{log_path.read_text()}")
        try:
            response = httpx.get(
                f"{base_url}/v1/catalog",
                headers={**AUTH_HEADERS, "Authorization": "Key " + PROXY_KEY},
                timeout=0.5,
            )
        except httpx.RequestError as error:
            last_error = str(error)
        else:
            if response.status_code == 200:
                return
            last_error = f"HTTP {response.status_code}: {response.text}"
        time.sleep(0.05)
    raise RuntimeError(
        f"Demo server did not start ({last_error}):\n{log_path.read_text()}"
    )


def _stop_demo(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def _serve_demo(
    tmp_path_factory: pytest.TempPathFactory,
    *,
    proxy: bool = False,
    datasets: bool = False,
    verify_proxy_auth: bool = False,
) -> Iterator[str]:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]

    base_url = f"http://127.0.0.1:{port}"
    work_dir = tmp_path_factory.mktemp("commons-mcp")
    log_path = work_dir / "uvicorn.log"
    environment = os.environ.copy()
    environment["COMMONS_DEMO_API_KEY"] = API_KEY
    environment.pop("COMMONS_HOSPITAL_DATA", None)
    environment.pop("COMMONS_ORDERS_DATA", None)
    source_path = str(PACKAGE_ROOT / "src")
    environment["PYTHONPATH"] = os.pathsep.join(
        part for part in (source_path, environment.get("PYTHONPATH", "")) if part
    )
    command = [
        sys.executable,
        str(PACKAGE_ROOT / "examples/connect-mcp/demo.py"),
        "--port",
        str(port),
    ]
    if proxy:
        command = [
            sys.executable,
            "-m",
            "uvicorn",
            "app:app",
            "--app-dir",
            str(PACKAGE_ROOT / "examples/connect-mcp"),
            "--host",
            "127.0.0.1",
            "--port",
            str(port),
        ]
        environment.pop("COMMONS_DEMO_API_KEY", None)

    if datasets:
        environment["COMMONS_HOSPITAL_DATA"] = str(
            PACKAGE_ROOT / "examples/connect-mcp/data/hospital_events.parquet"
        )
        environment["COMMONS_ORDERS_DATA"] = str(
            PACKAGE_ROOT / "examples/connect-mcp/data/sales/orders.parquet"
        )
    if verify_proxy_auth:
        command = [
            sys.executable,
            "-m",
            "uvicorn",
            "tests._mcp_proxy:app",
            "--host",
            "127.0.0.1",
            "--port",
            str(port),
        ]

    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(
            command,
            cwd=PACKAGE_ROOT,
            env=environment,
            stdout=log,
            stderr=subprocess.STDOUT,
            text=True,
        )
        try:
            _await_demo(process, base_url, log_path)
            yield base_url
        finally:
            _stop_demo(process)
