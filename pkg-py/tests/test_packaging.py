"""Pin what the built distribution promises its consumers: the distribution
name, the import name, and the type marker.

Both names are ``commons``, so hatchling infers ``src/commons`` without an
explicit packages setting. These run against the installed package, so they
check the built artifact rather than the source tree.
"""

import importlib.resources
from importlib.metadata import metadata, version

import commons


def test_import_name_is_commons() -> None:
    assert commons.__name__ == "commons"


def test_distribution_name_is_commons() -> None:
    assert metadata("commons")["Name"] == "commons"
    assert version("commons")


def test_the_browser_assets_are_where_the_ui_layer_looks() -> None:
    # Synced from the root www/ by scripts/sync-shared.sh, and read through
    # importlib.resources by the UI layer, so this pins the layout that code
    # depends on. It does not prove the wheel ships them: the suite runs
    # against an editable install, which reads src/ regardless. A step in
    # py-check.yaml builds a wheel and checks its contents.
    served = importlib.resources.files("commons") / "www" / "commons-chat"
    assert (served / "commons-chat.js").is_file()
    assert (served / "commons-chat.css").is_file()
    assert (served / "figs" / "citation-mark.svg").is_file()


def test_package_ships_type_information() -> None:
    # py.typed is what makes the annotations visible to consumers' type
    # checkers; a missing marker degrades silently to Any at the boundary.
    assert (importlib.resources.files("commons") / "py.typed").is_file()
