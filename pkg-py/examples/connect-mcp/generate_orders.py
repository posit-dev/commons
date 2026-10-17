"""Generate the deterministic 480-order warehouse snapshot."""

from pathlib import Path

import duckdb


def main() -> None:
    destination = Path(__file__).parent / "data/sales/orders.parquet"
    destination.parent.mkdir(parents=True, exist_ok=True)
    with duckdb.connect() as connection:
        connection.execute("""
            CREATE TABLE orders AS
            WITH seed AS (
                SELECT i, i // 4 AS cycle,
                       CASE WHEN i % 4 < 2 THEN 'North' ELSE 'South' END AS region,
                       CASE i % 4 WHEN 0 THEN 'Monitor' WHEN 1 THEN 'Keyboard'
                            WHEN 2 THEN 'Dock' ELSE 'Mouse' END AS product,
                       (1 + (i // 4) % 5) *
                           CASE WHEN i % 4 = 1 THEN 2 ELSE 1 END AS quantity,
                       CASE i % 4 WHEN 0 THEN 100.0 WHEN 1 THEN 75.0
                            WHEN 2 THEN 200.0 ELSE 50.0 END AS unit_price
                FROM range(480) AS t(i)
            )
            SELECT CAST(i + 1 AS INTEGER) AS order_id, region,
                   CAST(quantity * unit_price AS DOUBLE) AS revenue,
                   DATE '2025-01-01' + CAST(cycle AS INTEGER) AS ordered_at,
                   product, CAST(quantity AS INTEGER) AS quantity,
                   CAST(unit_price AS DOUBLE) AS unit_price,
                   CAST(1 + i % 80 AS INTEGER) AS customer_id
            FROM seed ORDER BY order_id
        """)
        connection.execute(
            "COPY orders TO ? (FORMAT PARQUET, COMPRESSION ZSTD)",
            [str(destination)],
        )
        assert connection.execute(
            "SELECT COUNT(*), SUM(revenue), COUNT(DISTINCT customer_id) FROM orders"
        ).fetchone() == (480, 180000.0, 80)
        assert connection.execute(
            "SELECT COUNT(*) FROM orders WHERE revenue != quantity * unit_price"
        ).fetchone() == (0,)
    print(f"Generated {destination.name}: 480 orders, $180,000 total revenue.")


if __name__ == "__main__":
    main()
