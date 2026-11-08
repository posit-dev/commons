"""The repository-root `.env` reader, against the shared cases."""

from typing import Any

import pytest

from tests._env_file import apply_env_file
from tests._shared import load_shared_fixture

_CASES = load_shared_fixture("live-warehouse-env")["env_file"]["cases"]


@pytest.mark.parametrize("case", _CASES, ids=[case["name"] for case in _CASES])
def test_env_file_case(case: dict[str, Any]) -> None:
    environ = dict(case["environment"])
    apply_env_file(case["lines"], environ)

    for name, value in case["expected"].items():
        assert environ[name] == value
    for name in case["unset"]:
        assert name not in environ
