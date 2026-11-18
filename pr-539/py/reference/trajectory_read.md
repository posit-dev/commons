## trajectory_read()


Read the conversations an agent logged with `log=True`.


Usage

``` python
trajectory_read(
    source=None,
    *,
    n=None,
    since=None,
    until=None,
)
```


`source` is a directory of OTLP JSON trace files: `trace.jsonl`, `trace-<n>.jsonl`, and files named from the `OTEL_EXPORTER_OTLP_TRACES_FILE` template. With none, the directory the file exporter writes to is read: the directory of `OTEL_EXPORTER_OTLP_TRACES_FILE` when it is set, and otherwise `COMMONS_TRACES_DIR`, or `commons-traces` under the temporary directory. Reading from Posit Connect is not supported yet, so a content GUID or URL, or no source on Connect, raises NotImplementedError.

`since` and `until` keep the chat activity at or after `since` and before `until`. Each is a datetime, a date, or a string like "2026-07-22" or "2026-07-22 14:30:00". A date, a string, or a datetime without a time zone is read in local time. A conversation that continues past `until` is returned as it was at `until`. `n` then keeps the `n` most recent conversations.

Conversations whose spans record no message content are dropped. The result is keyed by conversation id, with the oldest conversation first.
