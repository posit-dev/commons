"""Read the optional repository-root `.env` the live warehouse tests use.

The rules both suites share are pinned in `tests/shared/live-warehouse-env.json`
under `env_file`, and tests/README.md describes the file.
"""

import os
from collections.abc import MutableMapping
from pathlib import Path

from dotenv import dotenv_values

REPO_ROOT = Path(__file__).resolve().parents[2]


def env_file_path(root: Path = REPO_ROOT) -> Path | None:
    """The `.env` at `root`, when `root` is a checkout of this repository."""
    path = root / ".env"
    if (root / "tests" / "shared").is_dir() and path.is_file():
        return path
    return None


def apply_env_file(path: Path, environ: MutableMapping[str, str] = os.environ) -> None:
    """Set each variable the file names, unless `environ` already has it."""
    for name, value in dotenv_values(path).items():
        if value is not None:
            environ.setdefault(name, value)
