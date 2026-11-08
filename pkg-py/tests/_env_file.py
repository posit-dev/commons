"""Read the optional repository-root `.env` the live warehouse tests use.

The rules are pinned in `tests/shared/live-warehouse-env.json` under
`env_file`, and tests/README.md describes the file.
"""

from collections.abc import Iterable, MutableMapping
from pathlib import Path

ENV_FILE = Path(__file__).resolve().parents[2] / ".env"


def env_file_values(lines: Iterable[str]) -> dict[str, str]:
    """The variables `.env` lines set, before the environment is consulted."""
    values: dict[str, str] = {}
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, value = (part.strip() for part in line.split("=", 1))
        if not name:
            continue
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[name] = value
    return values


def apply_env_file(lines: Iterable[str], environ: MutableMapping[str, str]) -> None:
    """Set each variable the lines name, unless `environ` already has it."""
    for name, value in env_file_values(lines).items():
        environ.setdefault(name, value)
