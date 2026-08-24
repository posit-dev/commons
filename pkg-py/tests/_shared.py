"""Read the cross-language fixtures in ``tests/shared/``.

The Python suite reads them in place. The R suite cannot, because testthat
needs its fixtures inside the package, so it reads a generated copy. See
``tests/shared/README.md``.
"""

import json
from pathlib import Path
from typing import Any

SHARED_DIR = Path(__file__).resolve().parents[2] / "tests" / "shared"


def load_shared_fixture(name: str) -> Any:
    path = SHARED_DIR / f"{name}.json"
    if not path.is_file():
        raise FileNotFoundError(
            f"No shared fixture at {path}. The Python suite reads "
            f"tests/shared/ from the repository, so it cannot run from an "
            f"installed wheel."
        )
    return json.loads(path.read_text(encoding="utf-8"))
