# Sales and hospital events service

This public example contains 480 synthetic sales orders and 10,000 generated synthetic hospital events. It contains no supplied hospital pin or patient records. The generators reproduce the bundled Parquet files:

```bash
uv run python examples/connect-mcp/generate_orders.py
uv run python examples/connect-mcp/generate_hospital.py
```

The warehouse spans 120 days, four products, two regions, and 80 synthetic customers. Its total revenue is $180,000. The hospital data contains four fictitious hospitals, ten event types, and three categorical severity labels. Counts are descriptive; no dates, admission denominators, or clinical interpretation of severity are supplied.

The catalog exposes `warehouse` (`orders`) and `hospital` (`hospital_events`). Custom SQL cannot cross between sources. Approved tools are `revenue`, `hospital_summary`, and `hospital_event_counts`; `describe_table` returns schema and up to five raw rows, and `run_sql` runs bounded read-only queries. Dictionaries and context are MCP resources.

Run the service locally from `pkg-py/`, with an explicitly configured private key:

```bash
COMMONS_DEMO_API_KEY="$YOUR_LOCAL_SERVICE_KEY" \
  COMMONS_HOSPITAL_DATA=examples/connect-mcp/data/hospital_events.parquet \
  COMMONS_ORDERS_DATA=examples/connect-mcp/data/sales/orders.parquet \
  uv run python examples/connect-mcp/demo.py
```

The service refuses an empty or missing key. The administrative key grants all configured tools and sources. Its `-reader` credential grants revenue and warehouse table samples only; it cannot inspect hospital resources or rows. Library applications configure `Grant(tools, sources)` per key. `describe_table` is an explicit raw-row grant, not schema-only access.

`app.py` explicitly opts into `trust_proxy=True` for Connect, where the authenticating proxy protects the application port. Do not expose that port directly. Keep Connect content limited to the intended data audience. Swagger, ReDoc, and OpenAPI routes are disabled in either mode.

Deploy `app.py`, `demo.py`, `hospital.py`, `demo.html`, `data/`, the changed commons wheel, and its locked server dependencies. The example code and datasets are not included in the wheel.

A separately approved private snapshot can be supplied through `COMMONS_HOSPITAL_DATA`. Keep the Parquet file and its adjacent `data-dict.yaml` and `context.md` outside the public repository; add them only to the private deployment bundle. Nothing in this example polls a pins board.
