"""Fixtures every test module gets."""

from __future__ import annotations

from collections.abc import Callable, Iterator
from typing import TYPE_CHECKING

import pytest

from commons._icons import get_asset_base_url, set_asset_base_url
from tests import _spans
from tests._env_file import load_repo_env_file

if TYPE_CHECKING:
    from opentelemetry.sdk.trace import ReadableSpan

# A stand-in for a served bundle: the live URL carries the assets' newest
# mtime, so no literal can name it.
_BUNDLE = "lib/commons-chat-0.1.0.1"


def pytest_configure(config: pytest.Config) -> None:
    load_repo_env_file()


@pytest.fixture(autouse=True)
def _no_asset_bundle() -> Iterator[None]:
    # Where the bundle is served is process-wide state the UI layer sets, so
    # a test that renders an aside would otherwise depend on import order.
    before = get_asset_base_url()
    set_asset_base_url(None)
    yield
    set_asset_base_url(before)


@pytest.fixture(autouse=True)
def _forget_grants() -> Iterator[None]:
    # Which users were granted access is process-wide memo state.
    from commons import _connect

    _connect._GRANTED.clear()
    yield
    _connect._GRANTED.clear()


@pytest.fixture
def served_bundle() -> str:
    """Serve a bundle for the duration of one test, and give its base URL."""
    set_asset_base_url(_BUNDLE)
    return _BUNDLE


@pytest.fixture
def spans() -> Iterator[Callable[..., list[ReadableSpan]]]:
    """Record spans for one test: yields `finished`, with the exporter cleared around it."""
    recording = _spans.exporter()
    recording.clear()
    yield _spans.finished
    recording.clear()
