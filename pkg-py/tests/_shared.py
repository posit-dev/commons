"""Read the cross-language fixtures in ``tests/shared/``.

The Python suite reads them in place. The R suite cannot, because testthat
needs its fixtures inside the package, so it reads a generated copy. See
``tests/shared/README.md``.
"""

import json
from pathlib import Path
from typing import Annotated, Any, Literal

from pydantic import Field

from commons._measures import Injected, Measure, as_measure, measure

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


_SCALARS: dict[str, Any] = {
    "string": str,
    "integer": int,
    "number": float,
    "boolean": bool,
}


def _fixture_annotation(spec: dict[str, Any]) -> Any:
    kind = spec["type"]
    if kind == "enum":
        return Literal[tuple(spec["values"])]  # type: ignore[misc]
    if kind == "array":
        return list[_fixture_annotation(spec["items"])]
    return _SCALARS[kind]


def fixture_measure(spec: dict[str, Any]) -> Measure:
    """Build a measure from a fixture spec through the production ``@measure``.

    A real function is generated because ``@measure`` inspects a signature,
    not a spec; each described argument keeps its position, required arguments
    and injected arguments come first (Python requires that), and defaulted
    arguments follow. A case declaring a required argument after an optional
    one cannot be built without reordering, which would render a different
    argument order than the R runner, so it is rejected rather than built.
    """
    arguments = spec.get("arguments") or []
    injected = spec.get("injected") or []

    optional_seen = False
    for argument in arguments:
        if argument["required"] and optional_seen:
            raise ValueError(
                f"Fixture case {spec['name']!r} declares required argument "
                f"{argument['name']!r} after an optional one; Python requires "
                "defaulted parameters last, so this runner cannot preserve "
                "declaration order for that case."
            )
        optional_seen = optional_seen or not argument["required"]

    namespace: dict[str, Any] = {}
    required_params: list[str] = []
    optional_params: list[str] = []

    for argument in arguments:
        type_name = f"_{argument['name']}_type"
        namespace[type_name] = Annotated[
            _fixture_annotation(argument), Field(description=argument["description"])
        ]
        if argument["required"]:
            required_params.append(f"{argument['name']}: {type_name}")
        else:
            default_name = f"_{argument['name']}_default"
            namespace[default_name] = argument["default"]
            optional_params.append(f"{argument['name']}: {type_name} = {default_name}")

    injected_params: list[str] = []
    for injected_name in injected:
        type_name = f"_{injected_name}_type"
        namespace[type_name] = Injected[Any]
        injected_params.append(f"{injected_name}: {type_name}")

    params = ", ".join(required_params + injected_params + optional_params)
    exec(f"def {spec['name']}({params}) -> None: ...", namespace)  # noqa: S102
    func = namespace[spec["name"]]

    decorated = measure(description=spec["description"], name=spec["name"])(func)
    record = as_measure(decorated)
    assert record is not None
    return record
