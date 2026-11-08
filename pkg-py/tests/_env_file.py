"""Read the optional repository-root `.env` the live warehouse tests use.

The rules both suites share are pinned in `tests/shared/live-warehouse-env.json`
under `env_file`, and tests/README.md describes the file.
"""

import os
from pathlib import Path

from dotenv import dotenv_values

REPO_ROOT = Path(__file__).resolve().parents[2]


def env_file_path(root: Path = REPO_ROOT) -> Path | None:
    """The `.env` at `root`, when `root` is a checkout of this repository."""
    path = root / ".env"
    if (root / "tests" / "shared").is_dir() and path.is_file():
        return path
    return None


def apply_env_file(path: Path) -> None:
    """Set each variable the file names, unless the environment already has it."""
    for name, value in dotenv_values(path).items():
        if value is not None:
            os.environ.setdefault(name, value)


def load_repo_env_file(root: Path = REPO_ROOT) -> None:
    """Read the checkout's `.env`, when there is one."""
    if path := env_file_path(root):
        apply_env_file(path)
