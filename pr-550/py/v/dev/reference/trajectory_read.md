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


`source` is where to read from. With none, this content's own traces are read when it runs on Posit Connect. Off Connect, the deployed content's traces are read when the project has a deployment record, written by rsconnect-python under `rsconnect-python/` or by the R package rsconnect under `rsconnect/`. With several records, the most recently modified is read, and a warning names it. An rsconnect-python record that lists deployments to several servers does not say which is the latest, so `CONNECT_SERVER` picks one of them. When `CONNECT_SERVER` is set and the record names another server, the read is refused before any request is sent; pass the content URL to read from the record's server. Otherwise the directory the file exporter writes to is read: the directory of `OTEL_EXPORTER_OTLP_TRACES_FILE` when it is set, and otherwise `COMMONS_TRACES_DIR`, or `commons-traces` under the temporary directory. `source` can also be a Connect content GUID, a content URL (`.../content/<guid>/`), a vanity URL written as `<server>/content/<name>/` for content at `<server>/<name>/`, a dashboard URL (`.../connect/#/apps/<guid>/`), or a directory of OTLP JSON trace files: `trace.jsonl`, `trace-<n>.jsonl`, and files named from the `OTEL_EXPORTER_OTLP_TRACES_FILE` template.

Reading from Connect (2026.09.0 or later) needs `CONNECT_API_KEY`, and `CONNECT_SERVER` when the server is not in the URL, the deployment record, or the one server registered with rsconnect-python. The key's user needs editor-level access to the content: they must own it or be a collaborator (see `share_with` on [Commons](Commons.md#commons.Commons)). When Connect finds no traces and reports that the content's or the server's tracing setting is off, a warning names that setting.

`since` and `until` keep the chat activity at or after `since` and before `until`. Each is a datetime, a date, or a string like "2026-07-22" or "2026-07-22 14:30:00". A date, a string, or a datetime without a time zone is read in local time. A conversation that continues past `until` is returned as it was at `until`. A conversation that started before `since` is returned with the history its latest call in the window recorded, and its exchanges take provenance only from calls in the window, so an exchange answered only before `since` has no record. `n` then keeps the `n` most recent conversations. On Connect, `since` and `until` are sent with the request, so Connect leaves out most traces outside the window. The per-job trace stores that older content can have are filtered by `since` only. When `since` is set and a chat span in the window has its ancestry cut off, the read is repeated once without `since`, and the job stores are then read unfiltered. `n` is not sent, and is applied after the read.

Conversations whose spans record no message content are dropped. The result is keyed by conversation id, with the oldest conversation first.

Raises `TypeError` when `source`, `n`, or a bound has an unsupported type; `ValueError` when there is no Connect server or API key, a deployment record does not settle which server to read or names a server other than `CONNECT_SERVER`, a URL is not recognised, or a bound or `n` has an invalid value; `LookupError` when a vanity URL is not found; and a `RuntimeError` when Connect refuses access, has no such content, or a request to it fails.
