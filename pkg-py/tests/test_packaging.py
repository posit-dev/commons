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


def test_package_ships_the_browser_assets() -> None:
    # Synced from the root www/ by scripts/sync-shared.sh. The UI layer serves
    # these from the installed package, so a wheel that dropped them would
    # fail only at runtime, in the browser.
    served = importlib.resources.files("commons") / "www" / "commons-chat"
    assert (served / "commons-chat.js").is_file()
    assert (served / "commons-chat.css").is_file()
    assert (served / "figs" / "citation-mark.svg").is_file()


def test_package_ships_type_information() -> None:
    # py.typed is what makes the annotations visible to consumers' type
    # checkers; a missing marker degrades silently to Any at the boundary.
    assert (importlib.resources.files("commons") / "py.typed").is_file()
