"""The repository-root `.env` reader, against the shared cases."""

import io
import os
import re
from pathlib import Path
from typing import Any
from unittest import mock

import pytest
from dotenv import dotenv_values

from tests._env_file import (
    REPO_ROOT,
    apply_env_file,
    env_file_path,
    load_repo_env_file,
)
from tests._shared import load_shared_fixture

_CASES = load_shared_fixture("live-warehouse-env")["env_file"]["cases"]


@pytest.mark.parametrize("case", _CASES, ids=[case["name"] for case in _CASES])
def test_env_file_case(case: dict[str, Any], tmp_path: Path) -> None:
    path = tmp_path / ".env"
    path.write_text("".join(f"{line}\n" for line in case["lines"]))

    # patch.dict restores the whole environment when the block ends.
    with mock.patch.dict(os.environ):
        for name in [*case["expected"], *case["unset"]]:
            os.environ.pop(name, None)
        os.environ.update(case["environment"])

        apply_env_file(path)

        for name, value in case["expected"].items():
            assert os.environ.get(name) == value
        for name in case["unset"]:
            assert name not in os.environ


def test_the_env_file_is_read_from_the_repository_root() -> None:
    assert (REPO_ROOT / "tests" / "shared").is_dir()


def test_a_missing_env_file_is_not_read(tmp_path: Path) -> None:
    (tmp_path / "tests" / "shared").mkdir(parents=True)
    assert env_file_path(tmp_path) is None


def test_an_env_file_outside_a_checkout_is_not_read(tmp_path: Path) -> None:
    (tmp_path / ".env").write_text("COMMONS_ENV_FILE_STRAY=yes\n")
    assert env_file_path(tmp_path) is None

    (tmp_path / "tests" / "shared").mkdir(parents=True)
    assert env_file_path(tmp_path) == tmp_path / ".env"


def test_the_checkout_env_file_is_loaded(tmp_path: Path) -> None:
    (tmp_path / "tests" / "shared").mkdir(parents=True)
    (tmp_path / ".env").write_text("COMMONS_ENV_FILE_CHECKOUT=yes\n")

    with mock.patch.dict(os.environ):
        os.environ.pop("COMMONS_ENV_FILE_CHECKOUT", None)
        load_repo_env_file(tmp_path)
        assert os.environ.get("COMMONS_ENV_FILE_CHECKOUT") == "yes"


def _fixture_variables() -> tuple[set[str], set[str]]:
    """The required and optional variable names in the shared fixture."""
    required: set[str] = set()
    optional: set[str] = set()
    backends = load_shared_fixture("live-warehouse-env")["backends"]
    for backend in backends.values():
        connection = backend["connection"]
        required.update(connection["required"])
        if scopes := connection.get("scopes"):
            optional.add(scopes["variable"])
        for fixture in backend["fixtures"].values():
            target = required if fixture["required"] else optional
            target.add(fixture["variable"])
    return required, optional


def test_the_env_example_names_every_fixture_variable() -> None:
    example = (REPO_ROOT / ".env.example").read_text().splitlines()
    active = dotenv_values(stream=io.StringIO("\n".join(example)))
    # Optional variables are commented out as `# NAME=value`.
    commented = dotenv_values(
        stream=io.StringIO(
            "\n".join(
                line.removeprefix("# ")
                for line in example
                if re.match(r"# [A-Z_]+=", line)
            )
        )
    )
    required, optional = _fixture_variables()

    assert set(active) == required
    # The fixture owns the COMMONS_TEST_ names; vendor credentials it leaves
    # to the vendor's own authentication may appear as extras.
    assert optional <= set(commented)
    assert not {
        name for name in set(commented) - optional if name.startswith("COMMONS_TEST_")
    }
