"""The repository-root `.env` reader, against the shared cases."""

import os
from pathlib import Path
from typing import Any
from unittest import mock

import pytest

from tests._env_file import REPO_ROOT, apply_env_file, env_file_path
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
