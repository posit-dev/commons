"""Find the Connect content a project was deployed to, from its deployment records.

rsconnect-python writes ``rsconnect-python/<entry point>.json`` beside a
deployed entry point, and the R package rsconnect writes ``.dcf`` files under
``rsconnect/``. Both are read.
"""

import json
import logging
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from .._connect import normalize_server

_logger = logging.getLogger(__name__)

SKIPPED_DIRECTORIES = frozenset(
    {"rsconnect", "rsconnect-python", "renv", "packrat", "node_modules"}
)

_CONTENT_GUID = re.compile(
    r"/content/([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})"
)
_DCF_FIELD = re.compile(r"^([^\s:]+):(.*)$")
_HOSTED_DOMAINS = frozenset({"shinyapps.io", "api.shinyapps.io", "posit.cloud"})


@dataclass(frozen=True)
class Deployment:
    guid: str
    server: str
    name: str
    file: Path


def find_deployment(directory: Path | None = None) -> Deployment | None:
    """The most recently modified deployment record in the project, or None."""
    directory = Path.cwd() if directory is None else directory
    found: list[tuple[float, Deployment]] = []
    for file in deployment_record_files(directory):
        records = read_deployment_records(file)
        if not records:
            continue
        try:
            mtime = file.stat().st_mtime
        except OSError:
            continue
        found.extend((mtime, record) for record in records)
    if not found:
        return None
    found.sort(key=lambda item: item[0], reverse=True)
    deployment = found[0][1]
    if len(found) > 1:
        _logger.info(
            "Reading trajectories for the most recent deployment, %r on %s.",
            deployment.name,
            deployment.server,
        )
    return deployment


def deployment_record_files(directory: Path, max_depth: int = 3) -> list[Path]:
    """The record files at the project's top level and the levels below it."""
    # Walk a few levels rather than the whole tree: projects routinely have
    # large directories (renv/, data/) that a full listing would crawl.
    files: list[Path] = []
    level = [directory]
    for _ in range(max_depth):
        below: list[Path] = []
        for current in level:
            try:
                r_store = current / "rsconnect"
                if r_store.is_dir():
                    files.extend(
                        sorted(p for p in r_store.rglob("*.dcf") if p.is_file())
                    )
                python_store = current / "rsconnect-python"
                if python_store.is_dir():
                    files.extend(
                        sorted(p for p in python_store.glob("*.json") if p.is_file())
                    )
                below.extend(
                    sorted(
                        child
                        for child in current.iterdir()
                        if child.is_dir()
                        and not child.name.startswith(".")
                        and child.name not in SKIPPED_DIRECTORIES
                    )
                )
            except OSError:
                continue
        level = below
        if not level:
            break
    return files


def read_deployment_records(file: Path) -> list[Deployment]:
    """The deployments a record file names; a file that is not a record names none."""
    try:
        text = file.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    if file.suffix == ".json":
        return _python_records(file, text)
    record = _dcf_record(file, text)
    return [] if record is None else [record]


def _python_records(file: Path, text: str) -> list[Deployment]:
    try:
        entries = json.loads(text)
    except ValueError:
        return []
    if not isinstance(entries, dict):
        return []
    records: list[Deployment] = []
    for entry in entries.values():
        record = _python_record(file, entry)
        if record is not None:
            records.append(record)
    return records


def _python_record(file: Path, entry: Any) -> Deployment | None:
    if not isinstance(entry, dict):
        return None
    server = entry.get("server_url")
    url = entry.get("app_url")
    # A `#` marks a Connect Cloud account, and shinyapps.io content has no
    # /content/<guid> URL.
    if not isinstance(server, str) or not server or "#" in server:
        return None
    match = _CONTENT_GUID.search(url) if isinstance(url, str) else None
    if match is None:
        return None
    title = entry.get("title")
    name = title if isinstance(title, str) and title else file.name
    return Deployment(match.group(1), normalize_server(server), name, file)


def _dcf_record(file: Path, text: str) -> Deployment | None:
    fields = _dcf_fields(text)
    if fields is None:
        return None
    match = _CONTENT_GUID.search(fields.get("url", ""))
    if match is None:
        return None
    server = re.sub(r"/__api__/?$", "", fields.get("hostUrl", ""))
    if not server:
        return None
    return Deployment(match.group(1), server, fields.get("name", file.name), file)


def _dcf_fields(text: str) -> dict[str, str] | None:
    """The fields of the first DCF record in `text`, or None when it is not DCF."""
    fields: dict[str, str] = {}
    last: str | None = None
    for line in text.split("\n"):
        if not line.strip():
            if fields:
                break
            continue
        if line[0] in " \t":
            if last is None:
                return None
            fields[last] += "\n" + line
            continue
        match = _DCF_FIELD.match(line)
        if match is None:
            return None
        last = match.group(1)
        fields[last] = match.group(2)
    return {key: value.strip() for key, value in fields.items()}


def registered_connect_servers() -> list[str]:
    """The Connect servers registered with rsconnect-python, when it is installed."""
    try:
        from rsconnect import metadata

        servers = metadata.ServerStore(metadata.config_dirname()).get_all_servers()
    except Exception:  # noqa: BLE001 (an unreadable store registers no servers)
        return []
    urls: list[str] = []
    for server in servers if isinstance(servers, list) else []:
        url = server.get("url") if isinstance(server, dict) else None
        if not isinstance(url, str) or not url:
            continue
        host = (urlparse(url).hostname or "").lower()
        if host in _HOSTED_DOMAINS or host.endswith(".posit.cloud"):
            continue
        urls.append(normalize_server(url))
    return list(dict.fromkeys(urls))
