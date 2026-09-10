"""Fixtures every test module gets."""

from collections.abc import Iterator

import pytest

from commons._icons import get_asset_base_url, set_asset_base_url

# A stand-in for a served bundle: the live URL carries the assets' newest
# mtime, so no literal can name it.
_BUNDLE = "lib/commons-chat-0.1.0.1"


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
