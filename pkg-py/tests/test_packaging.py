"""Pin the distribution/import name split.

The distribution is ``posit-commons`` (the PyPI name ``commons`` is taken).
Hatchling infers the package directory from the distribution name, so
the split works because ``[tool.hatch.build.targets.wheel]``
names ``src/commons`` explicitly.

Without that setting the wheel build fails outright, which is loud but invites
the wrong fix: renaming ``src/commons/`` to ``src/posit_commons/`` also makes
the error go away and silently changes what consumers import. These tests fail
on that rename, so the decision cannot be reversed by accident.
"""

import importlib
import importlib.resources
from importlib.metadata import metadata, version

import pytest

import commons


def test_import_name_is_commons() -> None:
    assert commons.__name__ == "commons"


def test_distribution_name_is_posit_commons() -> None:
    assert metadata("posit-commons")["Name"] == "posit-commons"
    assert version("posit-commons")


def test_posit_commons_is_not_an_import_name() -> None:
    with pytest.raises(ModuleNotFoundError):
        importlib.import_module("posit_commons")


def test_package_ships_type_information() -> None:
    # py.typed is what makes the annotations visible to consumers' type
    # checkers; a missing marker degrades silently to Any at the boundary.
    assert (importlib.resources.files("commons") / "py.typed").is_file()
