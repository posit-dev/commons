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


def test_landlock_scopes_abstract_sockets_from_the_fixture_abi() -> None:
    fixture = load_shared_fixture("sandbox-abstract-ipc")
    scope = fixture["landlock_abstract_unix_scope"]
    assert scope["flag"] == "LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET"
    assert _landlock.SCOPE_MIN_ABI == scope["min_abi"]
    assert _landlock.SCOPE_ABSTRACT_UNIX_SOCKET == 1 << 0
