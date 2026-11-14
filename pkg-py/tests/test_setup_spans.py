"""The spans commons records while it sets up, as pinned by the shared fixture."""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
from typing import TYPE_CHECKING, Any

import pandas as pd
import pytest
import sqlalchemy

import commons
from commons import context_layer, data_source
from commons._agent import Commons

from . import _spans
from ._provider import scripted_chat
from ._shared import load_shared_fixture

if TYPE_CHECKING:
    from opentelemetry.sdk.trace import ReadableSpan

SCENARIOS = load_shared_fixture("traces")["setup_spans"]["scenarios"]

Spans = Callable[..., list["ReadableSpan"]]


def orders() -> pd.DataFrame:
    return pd.DataFrame({"id": [1, 2, 3], "total": [10.0, 20.0, 30.0]})


def customers() -> pd.DataFrame:
    return pd.DataFrame({"id": [1, 2], "name": ["Ada", "Bo"]})


def board(tmp_path: Path) -> Any:
    pins = pytest.importorskip("pins")
    board = pins.board_folder(str(tmp_path / "board"))
    board.pin_write(orders(), "orders", type="csv")
    board.pin_write(customers(), "customers", type="csv")
    return board


def engine(tmp_path: Path) -> sqlalchemy.Engine:
    engine = sqlalchemy.create_engine(f"sqlite:///{tmp_path / 'db.sqlite'}")
    orders().to_sql("orders", engine, index=False)
    customers().to_sql("customers", engine, index=False)
    return engine


def documents(tmp_path: Path) -> commons.ContextLayer:
    paths = []
    for position, text in enumerate(
        ["Revenue means booked revenue.", "A customer is an account."]
    ):
        path = tmp_path / f"doc{position}.md"
        path.write_text(f"# Term\n\n{text}", encoding="utf-8")
        paths.append(path)
    return context_layer(paths)


def agent(**kwargs: Any) -> Commons:
    return Commons(
        scripted_chat(),
        {"db": data_source(orders=orders())},
        **kwargs,
    )


# Each runner does its own preparation and returns the step to record, so the
# exporter sees the step under test and nothing else.
def run_frames_source(tmp_path: Path) -> Callable[[], Any]:
    return lambda: data_source(orders=orders(), customers=customers())


def run_connection_source(tmp_path: Path) -> Callable[[], Any]:
    db = engine(tmp_path)
    return lambda: data_source(db)


def run_board_source(tmp_path: Path) -> Callable[[], Any]:
    pins = board(tmp_path)
    return lambda: data_source(
        pins, tables={"orders": "orders", "customers": "customers"}
    )


def run_board_read(tmp_path: Path) -> Callable[[], Any]:
    source = data_source(
        board(tmp_path), tables={"orders": "orders", "customers": "customers"}
    )
    return source.ensure_loaded


def run_context_search(tmp_path: Path) -> Callable[[], Any]:
    layer = documents(tmp_path)
    return lambda: layer.search("revenue")


def run_context_prewarm(tmp_path: Path) -> Callable[[], Any]:
    return agent(context_layer=documents(tmp_path)).prewarm


def run_agent_create(tmp_path: Path) -> Callable[[], Any]:
    layer = documents(tmp_path)
    return lambda: agent(context_layer=layer)


def run_chat_server(tmp_path: Path) -> Callable[[], Any]:
    pytest.importorskip("shinychat")
    from shiny.session import session_context

    from ._session import IdleSession

    served = agent()

    def serve() -> None:
        with session_context(IdleSession()):
            commons.ui.server("chat", served)

    return serve


# One runner per fixture scenario.
RUNNERS: dict[str, Callable[[Path], Callable[[], Any]]] = {
    "frames source": run_frames_source,
    "connection source": run_connection_source,
    "board source": run_board_source,
    "board read": run_board_read,
    "context search": run_context_search,
    "context prewarm": run_context_prewarm,
    "agent create": run_agent_create,
    "chat server": run_chat_server,
}


def test_every_scenario_has_a_runner() -> None:
    assert SCENARIOS
    assert {scenario["name"] for scenario in SCENARIOS} == set(RUNNERS)


@pytest.mark.parametrize("scenario", SCENARIOS, ids=lambda s: s["name"])
def test_setup_records_the_shared_spans(
    scenario: dict[str, Any], spans: Spans, tmp_path: Path
) -> None:
    step = RUNNERS[scenario["name"]](tmp_path)
    # Preparation records spans of its own, which the step under test must not see.
    _spans.exporter().clear()
    step()

    for expected in scenario["spans"]:
        recorded = spans(expected["name"])
        assert len(recorded) == 1, expected["name"]
        assert dict(recorded[0].attributes or {}) == expected["attributes"]
