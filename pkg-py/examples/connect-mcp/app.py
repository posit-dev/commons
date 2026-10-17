"""ASGI entry point for sales and hospital events on Posit Connect."""

import os
from pathlib import Path

from demo import create_demo_app

app = create_demo_app(
    api_key=None,
    trust_proxy=True,
    hospital_data=Path(
        os.getenv(
            "COMMONS_HOSPITAL_DATA",
            str(Path(__file__).parent / "data/hospital_events.parquet"),
        )
    ),
    orders_data=Path(__file__).parent / "data/sales/orders.parquet",
)
