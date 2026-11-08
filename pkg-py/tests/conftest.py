"""Fixtures every test module gets."""

import os
from collections.abc import Iterator
from pathlib import Path

import pytest

from commons._icons import get_asset_base_url, set_asset_base_url

# A stand-in for a served bundle: the live URL carries the assets' newest
# mtime, so no literal can name it.
_BUNDLE = "lib/commons-chat-0.1.0.1"

_ENV_FILE = Path(__file__).resolve().parents[2] / ".env"


def pytest_configure(config: pytest.Config) -> None:
    """Read the optional repository-root `.env`; tests/README.md describes it."""
    if not _ENV_FILE.is_file():
        return
    for line in _ENV_FILE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, value = (part.strip() for part in line.split("=", 1))
        if not name:
            continue
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        # A variable set in the environment wins over the file.
        os.environ.setdefault(name, value)


@pytest.fixture(autouse=True)
def _no_asset_bundle() -> Iterator[None]:
    # Where the bundle is served is process-wide state the UI layer sets, so
    # a test that renders an aside would otherwise depend on import order.
    before = get_asset_base_url()
    set_asset_base_url(None)
    yield
    set_asset_base_url(before)


@pytest.fixture
def served_bundle() -> str:
    """Serve a bundle for the duration of one test, and give its base URL."""
    set_asset_base_url(_BUNDLE)
    return _BUNDLE
