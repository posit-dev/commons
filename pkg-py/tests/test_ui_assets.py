"""The HTML dependency that serves the browser assets to a page."""

import os
import subprocess
import sys
from pathlib import Path

import pytest

# shinychat brings shiny and htmltools with it, so it stands for the extra.
pytest.importorskip("shinychat", reason="commons[shiny] is not installed")

from commons._ui._assets import (
    asset_base_url,
    commons_chat_dependency,
)


def test_the_dependency_serves_the_chat_script_and_stylesheet() -> None:
    dep = commons_chat_dependency()
    assert dep.name == "commons-chat"
    rendered = dep.as_dict(lib_prefix=None)
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


def test_the_base_url_is_where_htmltools_serves_the_assets() -> None:
    dep = commons_chat_dependency()
    href = dep.as_dict()["stylesheet"][0]["href"]
    assert href == f"lib/{asset_base_url()}/commons-chat.css"


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


def test_the_ui_module_is_only_imported_on_demand() -> None:
    # commons.ui is the public spelling, but importing commons must not drag
    # the shiny extra in for the many users who never build a UI.
    code = (
        "import sys, commons\n"
        "assert 'shiny' not in sys.modules, 'importing commons imported shiny'\n"
        "commons.ui.commons_chat_dependency()\n"
        "assert 'htmltools' in sys.modules, 'commons.ui imported no extra'\n"
    )
    subprocess.run([sys.executable, "-c", code], check=True)
