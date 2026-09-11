"""The macOS seatbelt profile the worker engages on itself.

Profile generation is pure, so its rules are checked on any host. The rules
themselves, and their order, follow the Darwin branch of pkg-r/src/sandbox.c.
"""

from __future__ import annotations

import json
import pathlib
import platform
import socket
import subprocess
import sys
import textwrap

import pytest

import commons._execution._runtime
from commons._execution._runtime._seatbelt import seatbelt_profile


def test_the_profile_opens_permissively_and_then_denies() -> None:
    profile = seatbelt_profile(["/usr"], ["/tmp/work"])
    assert profile.startswith('(version 1)\n(allow default)\n')


def test_a_write_root_is_readable_as_well_as_writable() -> None:
    profile = seatbelt_profile(["/usr"], ["/private/tmp/work"])
    write_rule, read_rule = _write_and_read_rules(profile)
    assert '(subpath "/private/tmp/work")' in write_rule
    assert '(subpath "/private/tmp/work")' in read_rule


def test_dev_null_stays_writable() -> None:
    write_rule, _ = _write_and_read_rules(seatbelt_profile([], ["/private/tmp/w"]))
    assert '(literal "/dev/null")' in write_rule


def test_every_deny_precedes_its_allowlist() -> None:
    # Later rules win in SBPL, so an allow that came before its deny would be
    # silently revoked by it.
    profile = seatbelt_profile(["/usr"], ["/private/tmp/w"])
    assert profile.index("(deny file-write*)") < profile.index("(allow file-write*")
    assert profile.index("(deny file-read*)") < profile.index("(allow file-read*")


def test_metadata_reads_stay_allowed_for_path_traversal() -> None:
    profile = seatbelt_profile(["/usr"], ["/private/tmp/w"])
    assert "(allow file-read-metadata)" in profile
    assert profile.index("(deny file-read*)") < profile.index(
        "(allow file-read-metadata)"
    )


def test_the_network_is_denied_by_default() -> None:
    assert "(deny network*)" in seatbelt_profile(["/usr"], [])


def test_full_network_access_leaves_the_network_alone() -> None:
    assert "(deny network*)" not in seatbelt_profile(["/usr"], [], network="full")


def test_an_unknown_network_level_is_refused() -> None:
    # The worker is told its network level over the protocol, where nothing
    # has checked it against the type.
    with pytest.raises(ValueError, match="unknown network access level"):
        seatbelt_profile(["/usr"], [], network="partial")  # type: ignore[bad-argument-type]


def test_a_root_containing_a_quote_is_refused() -> None:
    with pytest.raises(ValueError, match="quote or backslash"):
        seatbelt_profile(['/tmp/od"d'], [])


def test_a_root_containing_a_backslash_is_refused() -> None:
    with pytest.raises(ValueError, match="quote or backslash"):
        seatbelt_profile([r"/tmp/od\d"], [])


def test_a_relative_root_is_refused() -> None:
    # realpath would resolve it against the worker's cwd and grant some other
    # directory entirely.
    with pytest.raises(ValueError, match="absolute"):
        seatbelt_profile(["relative/dir"], [])


def test_both_the_original_and_resolved_path_are_granted(tmp_path) -> None:
    # The sandbox matches symlink-free paths, and macOS /tmp is a symlink to
    # /private/tmp, so a root named through a symlink needs both forms.
    target = tmp_path / "target"
    target.mkdir()
    link = tmp_path / "link"
    link.symlink_to(target)

    profile = seatbelt_profile([str(link)], [])

    assert f'(subpath "{link}")' in profile
    assert f'(subpath "{target}")' in profile


def test_a_root_is_granted_once(tmp_path) -> None:
    root = str(tmp_path)
    profile = seatbelt_profile([root, root], [])
    assert profile.count(f'(subpath "{root}")') == 1


def _write_and_read_rules(profile: str) -> tuple[str, str]:
    """Split a profile into its file-write and file-read allow rules."""
    write_rule = profile.split("(allow file-write*")[1].split("\n")[0]
    read_rule = profile.split("(allow file-read*")[1].split("\n")[0]
    return write_rule, read_rule


def test_a_root_that_is_both_readable_and_writable_is_read_granted_once(
    tmp_path,
) -> None:
    root = str(tmp_path)
    _, read_rule = _write_and_read_rules(seatbelt_profile([root], [root]))
    assert read_rule.count(f'(subpath "{root}")') == 1


# The sandbox is engaged in a subprocess for every live test: engaging it in
# the test runner would restrict the rest of the session.

RUNTIME_DIR = str(
    pathlib.Path(commons._execution._runtime.__file__).parent  # type: ignore[arg-type]
)

# Enough of the system for the interpreter to keep working once reads outside
# the roots are denied.
SYSTEM_READ_ROOTS = [
    "/usr",
    "/bin",
    "/sbin",
    "/System",
    "/Library",
    "/private/etc",
    "/private/var/db",
    "/opt",
    "/dev",
    sys.base_prefix,
    sys.prefix,
]

CONNECT = (
    "s = socket.socket()\n"
    "s.settimeout(10)\n"
    "s.connect(('127.0.0.1', {port}))\n"
    "s.close()\n"
    "result = 'connected'"
)


darwin_only = pytest.mark.skipif(
    platform.system() != "Darwin", reason="seatbelt is a macOS interface"
)


def run_sandboxed(
    body: str,
    *,
    read_roots: list[str],
    write_roots: list[str],
    network: str = "none",
    system_roots: bool = True,
) -> str:
    """Engage the seatbelt in a fresh interpreter, then run ``body``.

    ``body`` reports through a ``result`` name, which is printed as JSON. The
    module is imported by directory rather than as part of ``commons``, which
    is how the worker reaches it and proves it needs nothing from the package.
    """
    script = "\n".join(
        [
            "import json, os, pathlib, socket, sys",
            f"sys.path.insert(0, {RUNTIME_DIR!r})",
            "from _seatbelt import engage_seatbelt",
            (
                f"engage_seatbelt({read_roots + (SYSTEM_READ_ROOTS if system_roots else [])!r}, "
                f"{write_roots!r}, network={network!r})"
            ),
            "try:",
            textwrap.indent(textwrap.dedent(body).strip(), "    "),
            "except OSError as error:",
            "    result = type(error).__name__",
            "print(json.dumps(result))",
        ]
    )
    completed = subprocess.run(
        [sys.executable, "-c", script],
        check=False,
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert completed.returncode == 0, completed.stderr
    return json.loads(completed.stdout)


@darwin_only
def test_a_write_inside_a_write_root_succeeds(tmp_path) -> None:
    target = tmp_path / "allowed.txt"
    result = run_sandboxed(
        f"pathlib.Path({str(target)!r}).write_text('written'); result = 'ok'",
        read_roots=[str(tmp_path)],
        write_roots=[str(tmp_path)],
    )
    assert result == "ok"
    assert target.read_text() == "written"


@darwin_only
def test_a_write_outside_every_write_root_is_denied(tmp_path) -> None:
    work = tmp_path / "work"
    work.mkdir()
    forbidden = tmp_path / "elsewhere.txt"

    result = run_sandboxed(
        f"pathlib.Path({str(forbidden)!r}).write_text('nope'); result = 'ok'",
        read_roots=[str(work)],
        write_roots=[str(work)],
    )

    assert result == "PermissionError"
    assert not forbidden.exists()


@darwin_only
def test_a_read_outside_every_read_root_is_denied(tmp_path) -> None:
    work = tmp_path / "work"
    work.mkdir()
    secret = tmp_path / "secret.txt"
    secret.write_text("classified")

    result = run_sandboxed(
        f"result = pathlib.Path({str(secret)!r}).read_text()",
        read_roots=[str(work)],
        write_roots=[str(work)],
    )

    assert result == "PermissionError"


@darwin_only
def test_a_read_inside_a_read_root_succeeds(tmp_path) -> None:
    readable = tmp_path / "readable.txt"
    readable.write_text("public")

    result = run_sandboxed(
        f"result = pathlib.Path({str(readable)!r}).read_text()",
        read_roots=[str(tmp_path)],
        write_roots=[],
    )

    assert result == "public"


@darwin_only
def test_the_denied_network_blocks_even_a_local_connection(tmp_path) -> None:
    # A listener in this process, so the test needs no internet: under
    # (deny network*) even this connection cannot be made.
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        port = listener.getsockname()[1]

        result = run_sandboxed(
            CONNECT.format(port=port),
            read_roots=[str(tmp_path)],
            write_roots=[str(tmp_path)],
        )

    assert result == "PermissionError"


@darwin_only
def test_full_network_access_permits_a_local_connection(tmp_path) -> None:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        port = listener.getsockname()[1]

        result = run_sandboxed(
            CONNECT.format(port=port),
            read_roots=[str(tmp_path)],
            write_roots=[str(tmp_path)],
            network="full",
        )

    assert result == "connected"


@darwin_only
def test_dev_null_is_writable_under_the_sandbox(tmp_path) -> None:
    result = run_sandboxed(
        "pathlib.Path('/dev/null').write_text('discarded'); result = 'ok'",
        read_roots=[str(tmp_path)],
        write_roots=[str(tmp_path)],
    )
    assert result == "ok"


def test_no_read_roots_denies_every_read_rather_than_allowing_them_all() -> None:
    # An allow with no path predicate applies to everything, and it comes
    # after the deny, so it would hand back every file on the host.
    profile = seatbelt_profile([], [])
    assert "(allow file-read*)" not in profile
    assert "(allow file-read* )" not in profile
    assert "(deny file-read*)" in profile


@darwin_only
def test_a_profile_with_no_roots_cannot_read_an_unrelated_file(tmp_path) -> None:
    secret = tmp_path / "secret.txt"
    secret.write_text("classified")

    result = run_sandboxed(
        f"result = pathlib.Path({str(secret)!r}).read_text()",
        read_roots=[],
        write_roots=[],
        system_roots=False,
    )

    assert result == "PermissionError"
