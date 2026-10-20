"""Run a local semantic service with four dummy orders and no external credentials."""

from __future__ import annotations

import argparse
import os
import tempfile
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Annotated, Any, Literal

import duckdb
import uvicorn
from fastapi.responses import HTMLResponse
from hospital import hospital_event_counts, hospital_summary
from pydantic import Field

from commons import Injected, measure, semantic_layer
from commons.server import Grant, Registry, create_app
from commons.server._registry import Context, Source

DICTIONARY = """$version: "0.1.0"
$learn_more: https://data-dict.tidyverse.org/
name: Demo sales
description: A dummy sales dataset for validating remote commons.
tables:
  - name: orders
    description: One row per completed order. Revenue is the booked order amount in USD.
    columns:
      - name: order_id
        type: number(id)
        description: Unique order identifier.
      - name: region
        type: string
        description: The order's sales region, North or South.
      - name: revenue
        type: number(quantity)
        description: Booked order revenue in USD.
"""
CONTEXT = "Revenue is the sum of booked order amounts. Group orders by region to compare regional revenue."


@measure(description="Approved total booked revenue in USD, optionally for a region.")
def revenue(
    warehouse: Injected[Any],
    region: Annotated[
        Literal["North", "South"] | None,
        Field(description="North or South; omit for all regions."),
    ] = None,
) -> dict[str, Any]:
    total = warehouse.execute(
        "SELECT COALESCE(SUM(revenue), 0) FROM orders WHERE (? IS NULL OR region = ?)",
        [region, region],
    ).fetchone()[0]
    return {"revenue": total, "currency": "USD"}


def create_demo_app(
    api_key: str | None = None,
    *,
    hospital_data: Path | None = None,
    orders_data: Path | None = None,
    trust_proxy: bool = False,
) -> Any:
    """Create an ephemeral dummy dataset; close it with the application's lifespan."""
    temporary = tempfile.TemporaryDirectory(prefix="commons-mcp-")
    database = Path(temporary.name) / "sales.duckdb"
    with duckdb.connect(str(database)) as connection:
        if orders_data is None:
            connection.execute(
                "CREATE TABLE orders(order_id INTEGER, region VARCHAR, revenue DOUBLE)"
            )
            connection.execute(
                "INSERT INTO orders VALUES (1, 'North', 100), (2, 'North', 150), (3, 'South', 200), (4, 'South', 50)"
            )
        else:
            connection.execute(
                "CREATE TABLE orders AS SELECT * FROM read_parquet(?)",
                [str(orders_data)],
            )
        connection.execute("CREATE TABLE private_notes AS SELECT 'not exposed' AS note")
        if hospital_data is not None:
            connection.execute(
                "CREATE TABLE hospital_events AS SELECT * FROM read_parquet(?)",
                [str(hospital_data)],
            )
    sources = {}
    contexts: dict[str, str | Context] = {"revenue-policy": CONTEXT}
    dictionary = DICTIONARY
    if orders_data is not None:
        dictionary = orders_data.with_name("data-dict.yaml").read_text()
        contexts["revenue-policy"] = orders_data.with_name("context.md").read_text()
    measures = [revenue]
    if hospital_data is not None:
        sources["hospital"] = Source(
            ("hospital_events",),
            hospital_data.with_name("data-dict.yaml").read_text(),
        )
        contexts["hospital-policy"] = Context(
            hospital_data.with_name("context.md").read_text(), frozenset({"hospital"})
        )
        measures.extend([hospital_summary, hospital_event_counts])
    registry = Registry(
        database,
        semantic_layer(*measures),
        dictionary,
        contexts,
        extra_sources=sources,
    )
    app = create_app(
        registry,
        api_keys=(
            {
                api_key: Grant(
                    frozenset(registry.operations), frozenset(registry.sources)
                ),
                f"{api_key}-reader": Grant(
                    frozenset({"revenue", "describe_table"}), frozenset({"warehouse"})
                ),
            }
            if api_key is not None
            else None
        ),
        trust_proxy=trust_proxy,
    )

    @app.get("/", response_class=HTMLResponse)
    def preview() -> HTMLResponse:
        document = Path(__file__).with_name("demo.html").read_text()
        if api_key is None:
            document = document.replace(
                'data-service-auth="required"', 'data-service-auth="proxy"'
            )
        return HTMLResponse(
            document,
            headers={"Cache-Control": "no-store"},
        )

    parent_lifespan = app.router.lifespan_context

    @asynccontextmanager
    async def lifespan(application: Any) -> Any:
        try:
            async with parent_lifespan(application):
                yield
        finally:
            temporary.cleanup()

    app.router.lifespan_context = lifespan
    return app


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()
    key = os.getenv("COMMONS_DEMO_API_KEY")
    if not key or not key.strip():
        parser.error("Set COMMONS_DEMO_API_KEY to a nonempty private key.")
    uvicorn.run(
        create_demo_app(
            key,
            hospital_data=(
                Path(path) if (path := os.getenv("COMMONS_HOSPITAL_DATA")) else None
            ),
            orders_data=(
                Path(path) if (path := os.getenv("COMMONS_ORDERS_DATA")) else None
            ),
        ),
        host="127.0.0.1",
        port=args.port,
    )


if __name__ == "__main__":
    main()
