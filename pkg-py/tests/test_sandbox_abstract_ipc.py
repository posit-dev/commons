"""Runner for ``tests/shared/sandbox-abstract-ipc.json``."""

from __future__ import annotations

from commons._execution._runtime import _landlock, _seccomp

from ._shared import load_shared_fixture


def test_the_fixture_carries_the_agreement() -> None:
    fixture = load_shared_fixture("sandbox-abstract-ipc")
    screened = fixture["seccomp_screened_under_network_none"]
    assert screened["always"]
    assert screened["when_addressed"]


def test_the_network_block_screens_the_fixture_calls() -> None:
    fixture = load_shared_fixture("sandbox-abstract-ipc")
    screened = fixture["seccomp_screened_under_network_none"]
    assert list(_seccomp.LOCAL_PEER_SCREENED) == screened["always"]
    assert (
        list(_seccomp.LOCAL_PEER_SCREENED_WHEN_ADDRESSED)
        == screened["when_addressed"]
    )


def test_socketcall_allows_only_the_fixture_sub_calls() -> None:
    fixture = load_shared_fixture("sandbox-abstract-ipc")
    allowed = fixture["socketcall_allowed_under_network_none"]
    assert allowed
    assert sorted(_seccomp.SOCKETCALL_ALLOWED) == sorted(allowed)


def test_landlock_scopes_abstract_sockets_from_the_fixture_abi() -> None:
    fixture = load_shared_fixture("sandbox-abstract-ipc")
    scope = fixture["landlock_abstract_unix_scope"]
    assert scope["flag"] == "LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET"
    assert _landlock.SCOPE_MIN_ABI == scope["min_abi"]
    assert _landlock.SCOPE_ABSTRACT_UNIX_SOCKET == 1 << 0


def test_landlock_handles_pathname_sockets_from_the_fixture_abi() -> None:
    fixture = load_shared_fixture("sandbox-abstract-ipc")
    spec = fixture["landlock_pathname_unix_right"]
    assert spec["right"] == "LANDLOCK_ACCESS_FS_RESOLVE_UNIX"
    right = _landlock.FS_RESOLVE_UNIX
    assert right == 1 << spec["bit"]
    assert _landlock.handled_access(spec["min_abi"] - 1) & right == 0
    assert _landlock.handled_access(spec["min_abi"]) & right == right
    assert bool(_landlock.FS_READ_ONLY & right) == spec["granted_to_read_roots"]
