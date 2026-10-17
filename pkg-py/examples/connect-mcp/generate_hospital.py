"""Generate public synthetic hospital records, without using a supplied pin."""

from pathlib import Path

import duckdb


def main() -> None:
    destination = Path(__file__).parent / "data/hospital_events.parquet"
    with duckdb.connect(config={"threads": 1}) as connection:
        connection.execute("""
            CREATE TABLE hospital_events AS
            SELECT CASE WHEN i < 4000 THEN 'Example General Hospital'
                        WHEN i < 7000 THEN 'Example Port Hospital'
                        WHEN i < 9000 THEN 'Example Military Hospital'
                        ELSE 'Example Women''s Hospital' END AS hospitals_table,
                   CASE i % 10
                        WHEN 0 THEN 'diagnostic error'
                        WHEN 1 THEN 'medical complication'
                        WHEN 2 THEN 'behavior problem'
                        WHEN 3 THEN 'admission/discharge issue'
                        WHEN 4 THEN 'environmental hazard'
                        WHEN 5 THEN 'surgical complication'
                        WHEN 6 THEN 'transfusion problem'
                        WHEN 7 THEN 'medication error'
                        WHEN 8 THEN 'equipment problem'
                        ELSE 'perinatal problem' END AS events_table,
                   CASE WHEN i % 20 < 13 THEN 'Level 1'
                        WHEN i % 20 < 19 THEN 'Level 2'
                        ELSE 'Level 3' END AS severity_table
            FROM range(10000) AS t(i) ORDER BY i
        """)
        connection.execute(
            "COPY hospital_events TO ? (FORMAT PARQUET, COMPRESSION ZSTD)",
            [str(destination)],
        )
        assert connection.execute(
            "SELECT COUNT(*), COUNT(DISTINCT hospitals_table), COUNT(DISTINCT events_table) FROM hospital_events"
        ).fetchone() == (10000, 4, 10)
    print("Generated 10,000 synthetic hospital events.")


if __name__ == "__main__":
    main()
