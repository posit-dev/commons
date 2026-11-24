"""Find the Connect content a project was deployed to, from its deployment records.

rsconnect-python writes ``rsconnect-python/<entry point>.json`` beside a
deployed entry point, and the R package rsconnect writes ``.dcf`` files under
``rsconnect/``. Both are read.
"""

import json
import os
import re
import sys
import warnings
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from .._connect import normalize_server

SKIPPED_DIRECTORIES = frozenset(
    {"rsconnect", "rsconnect-python", "renv", "packrat", "node_modules"}
)

GUID_PATTERN = r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}"
_CONTENT_GUID = re.compile(r"/content/(" + GUID_PATTERN + ")")
_DCF_FIELD = re.compile(r"^([^\s:]+):(.*)$")
_HOSTED_DOMAINS = frozenset({"shinyapps.io", "api.shinyapps.io", "posit.cloud"})


@dataclass(frozen=True)
class Deployment:
    guid: str
    server: str
    name: str
    file: Path


def find_deployment(
    directory: Path | None = None, *, quiet: bool = False, stacklevel: int = 2
) -> Deployment | None:
    """The most recently modified deployment record in the project, or None.

    Warns which record is read when there are several, unless `quiet`;
    `stacklevel` is as `warnings.warn` takes it, counted from this function.
    Raises ValueError when the most recent record file lists deployments to
    several servers and CONNECT_SERVER does not pick one of them.
    """
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
    deployment = _latest_in_file([d for _, d in found if d.file == found[0][1].file])
    if len(found) > 1 and not quiet:
        warnings.warn(
            f"Reading trajectories for the most recent deployment, "
            f"{deployment.name!r} on {deployment.server}.",
            stacklevel=stacklevel,
        )
    return deployment


def _latest_in_file(deployments: list[Deployment]) -> Deployment:
    # rsconnect-python keeps one entry per server in a file and records no
    # time, so a file's entries cannot be ordered by when they were deployed.
    distinct = list({(d.guid, d.server): d for d in deployments}.values())
    if len(distinct) == 1:
        return distinct[0]
    server = normalize_server(os.environ.get("CONNECT_SERVER", ""))
    chosen = [d for d in distinct if d.server == server]
    if len(chosen) == 1:
        return chosen[0]
    servers = ", ".join(d.server for d in distinct)
    raise ValueError(
        f"Can't tell which deployment in {distinct[0].file} is the most recent: "
        f"it lists deployments to {servers}. Set CONNECT_SERVER to one of them, "
        "or pass a content URL."
    )


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
                    files.extend(_dcf_files(r_store))
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


def _dcf_files(directory: Path) -> list[Path]:
    """The `.dcf` files below `directory`, skipping hidden files and directories."""
    files: list[Path] = []
    for root, directories, names in os.walk(directory):
        directories[:] = sorted(d for d in directories if not d.startswith("."))
        files.extend(
            Path(root) / name
            for name in sorted(names)
            if name.endswith(".dcf")
            and not name.startswith(".")
            and _is_regular_file(Path(root) / name)
        )
    return files


def _is_regular_file(path: Path) -> bool:
    try:
        return path.is_file()
    except OSError:
        return False


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
    # A `#` marks a Connect Cloud account. shinyapps.io content has neither a
    # GUID nor a /content/<guid> URL.
    if not isinstance(server, str) or not server or "#" in server:
        return None
    guid = entry.get("app_guid")
    if not isinstance(guid, str) or re.fullmatch(GUID_PATTERN, guid) is None:
        url = entry.get("app_url")
        match = _CONTENT_GUID.search(url) if isinstance(url, str) else None
        if match is None:
            return None
        guid = match.group(1)
    title = entry.get("title")
    name = title if isinstance(title, str) and title else file.name
    return Deployment(guid, normalize_server(server), name, file)


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
    """The Connect servers registered with rsconnect-python, in nickname order."""
    # rsconnect-python (1.33) keeps `servers.json` in its configuration
    # directory: a JSON object keyed by nickname, each value an object with
    # `name`, `url`, and `api_key`.
    try:
        text = (_rsconnect_python_config_dir() / "servers.json").read_text(
            encoding="utf-8"
        )
        servers = json.loads(text)
    except (OSError, ValueError):
        return []
    entries = (
        [s for s in servers.values() if isinstance(s, dict)]
        if isinstance(servers, dict)
        else []
    )
    entries.sort(key=lambda entry: str(entry.get("name") or ""))
    urls: list[str] = []
    for entry in entries:
        url = entry.get("url")
        if not isinstance(url, str) or not url:
            continue
        host = (urlparse(url).hostname or "").lower()
        if host in _HOSTED_DOMAINS or host.endswith(".posit.cloud"):
            continue
        urls.append(normalize_server(url))
    return list(dict.fromkeys(urls))


def _rsconnect_python_config_dir() -> Path:
    """rsconnect-python's configuration directory, as its config_dirname() finds it."""
    home = os.environ.get("HOME", "~")
    base = home
    if sys.platform.startswith("linux"):
        base = os.environ.get("XDG_CONFIG_HOME", home)
    elif sys.platform == "darwin":
        base = os.path.join(home, "Library", "Application Support")
    elif sys.platform == "win32":
        base = os.environ.get("APPDATA", home)
    name = ".rsconnect-python" if base == home else "rsconnect-python"
    return Path(os.path.expanduser(base)) / name
