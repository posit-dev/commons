"""The HTML dependency that serves the browser assets to a page."""

import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

# shinychat brings shiny and htmltools with it, so it stands for the extra.
pytest.importorskip("shinychat", reason="commons[shiny] is not installed")

from commons._icons import get_asset_base_url
from commons._ui._assets import (
    asset_base_url,
    commons_chat_dependency,
)


def test_the_dependency_serves_the_chat_script_and_stylesheet() -> None:
    dep = commons_chat_dependency()
    assert dep.name == "commons-chat"
    rendered = dep.as_dict()
    base = asset_base_url()
    assert rendered["script"] == [{"src": f"{base}/commons-chat.js"}]
    assert rendered["stylesheet"][0]["href"] == f"{base}/commons-chat.css"


def test_the_dependency_serves_the_icons_beside_them() -> None:
    # The asides reference figs/ by URL, and only all_files=True puts a file
    # the script and stylesheet entries do not name on the served path.
    dep = commons_chat_dependency()
    assert dep.all_files
    source = Path(dep.source_path_map(lib_prefix=None)["source"])
    assert (source / "figs" / "citation-mark.svg").is_file()


def test_the_version_carries_the_package_version() -> None:
    from importlib.metadata import version

    from packaging.version import Version

    base = Version(version("commons")).base_version
    assert str(commons_chat_dependency().version).startswith(f"{base}.")


def test_the_version_changes_when_an_asset_changes() -> None:
    # Without this the browser keeps serving an edited asset from cache. The
    # bump is a single nanosecond, so an edit landing in the same second as
    # the last render is caught too.
    source = Path(commons_chat_dependency().source_path_map(lib_prefix=None)["source"])
    assets = [p for p in source.rglob("*") if p.is_file()]
    asset = max(assets, key=lambda p: p.stat().st_mtime_ns)
    before = commons_chat_dependency().version
    stat = asset.stat()
    try:
        os.utime(asset, ns=(stat.st_atime_ns, stat.st_mtime_ns + 1))
        assert commons_chat_dependency().version != before
    finally:
        os.utime(asset, ns=(stat.st_atime_ns, stat.st_mtime_ns))
    assert commons_chat_dependency().version == before


def test_the_ui_module_imports_like_any_other_submodule() -> None:
    from commons.ui import commons_chat_dependency as imported

    assert imported is commons_chat_dependency


def test_the_base_url_carries_the_library_prefix() -> None:
    # htmltools renders a dependency's hrefs under a library prefix, so the
    # bare directory name is not a URL that resolves in a page.
    dep = commons_chat_dependency()
    directory = f"{dep.name}-{dep.version}"

    assert asset_base_url() != directory
    assert asset_base_url().endswith(f"/{directory}")


def test_building_the_dependency_tells_the_asides_where_it_is_served() -> None:
    # The asides resolve their icon URLs as they stream, before any page has
    # rendered, so registering the bundle is what hands them its URL.
    assert get_asset_base_url() is None

    commons_chat_dependency()

    assert get_asset_base_url() == asset_base_url()


async def test_the_icon_urls_the_asides_emit_resolve_on_a_real_page() -> None:
    # The whole seam, end to end: a page carrying the theme serves the bundle
    # at the URL the asides built their icon links from.
    httpx = pytest.importorskip("httpx")
    from shiny import App, ui

    from commons._citations import citation_icon_url
    from commons._icons import icon_url
    from commons.ui import theme

    app = App(ui.page_fluid(ui.h1("commons"), theme=theme()), lambda i, o, s: None)
    urls = [citation_icon_url("prose"), icon_url("trusted-icon.svg")]
    assert all(url is not None for url in urls)

    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://page") as client:
        for url in urls:
            assert (await client.get(f"/{url}")).status_code == 200, url


def test_a_missing_extra_names_the_package_and_the_install() -> None:
    # Make shinychat fail to import the way an uninstalled one does, then
    # import commons.ui in a fresh interpreter and read what it says.
    code = """
import sys


class Absent:
    def find_spec(self, name, path=None, target=None):
        if name.split(".")[0] == "shinychat":
            raise ModuleNotFoundError(f"No module named {name!r}", name=name)
        return None


sys.meta_path.insert(0, Absent())
try:
    import commons.ui
except ImportError as err:
    print(err)
else:
    print("commons.ui imported anyway")
"""
    done = subprocess.run(
        [sys.executable, "-c", code], capture_output=True, text=True, check=True
    )
    assert "shinychat" in done.stdout
    assert 'pip install "commons[shiny]"' in done.stdout


def test_a_missing_extra_names_every_package_it_is_short() -> None:
    # R's `check_chat_packages()` lists all of them, so one install fixes the
    # import instead of one round trip per package.
    code = """
import sys


class Absent:
    def find_spec(self, name, path=None, target=None):
        if name.split(".")[0] in ("shiny", "shinychat"):
            raise ModuleNotFoundError(f"No module named {name!r}", name=name)
        return None


sys.meta_path.insert(0, Absent())
try:
    import commons.ui
except ImportError as err:
    print(err)
else:
    print("commons.ui imported anyway")
"""
    done = subprocess.run(
        [sys.executable, "-c", code], capture_output=True, text=True, check=True
    )
    # Read only the sentence that lists them: "shinychat" contains "shiny",
    # and the install hint says `commons[shiny]`, so either would satisfy a
    # naive substring test on the whole message.
    listed = done.stdout.split("Install")[0]
    assert re.search(r"\bshiny\b", listed), done.stdout
    assert "shinychat" in listed


def test_the_ui_module_is_only_imported_on_demand() -> None:
    # commons.ui is the public spelling, but importing commons must not drag
    # the shiny extra in for the many users who never build a UI.
    code = (
        "import sys, commons\n"
        "assert 'shiny' not in sys.modules, 'importing commons imported shiny'\n"
        "commons.ui.commons_chat_dependency()\n"
        "assert 'shiny' in sys.modules, 'commons.ui imported no extra'\n"
    )
    subprocess.run([sys.executable, "-c", code], check=True)
