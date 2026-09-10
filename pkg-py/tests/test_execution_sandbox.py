"""The gate that decides whether the worker can be sandboxed on this host.

The decision table is driven with constructed capability values rather than
whatever the test machine happens to support, so every branch is reachable
from any host. The cases match pkg-r/tests/testthat/test-sandbox.R.
"""

from __future__ import annotations

import platform

import pytest

from commons._execution import _sandbox
from commons._execution._sandbox import (
    SandboxCapabilities,
    protection_mode,
    sandbox_capabilities,
)

NOTHING = SandboxCapabilities(
    landlock_abi=0, seccomp=False, seatbelt=False, userns=False
)


def test_the_host_probe_reports_every_mechanism() -> None:
    capabilities = sandbox_capabilities()
    assert isinstance(capabilities.landlock_abi, int)
    assert isinstance(capabilities.seccomp, bool)
    assert isinstance(capabilities.seatbelt, bool)
    assert isinstance(capabilities.userns, bool)


@pytest.mark.parametrize("landlock_abi, userns", [(1, False), (0, True)])
def test_linux_accepts_either_filesystem_sandbox(landlock_abi, userns) -> None:
    capabilities = SandboxCapabilities(
        landlock_abi=landlock_abi, seccomp=True, seatbelt=False, userns=userns
    )
    assert protection_mode(capabilities, sysname="Linux") == "sandbox"


def test_linux_without_seccomp_is_refused() -> None:
    capabilities = SandboxCapabilities(
        landlock_abi=1, seccomp=False, seatbelt=False, userns=True
    )
    with pytest.raises(RuntimeError, match="does not support seccomp"):
        protection_mode(capabilities, sysname="Linux")


def test_linux_without_a_filesystem_sandbox_is_refused() -> None:
    capabilities = SandboxCapabilities(
        landlock_abi=0, seccomp=True, seatbelt=False, userns=False
    )
    with pytest.raises(
        RuntimeError, match="neither Landlock nor unprivileged user namespaces"
    ):
        protection_mode(capabilities, sysname="Linux")


def test_a_refusal_names_the_opt_in_and_what_to_check() -> None:
    capabilities = SandboxCapabilities(
        landlock_abi=0, seccomp=True, seatbelt=False, userns=False
    )
    with pytest.raises(RuntimeError) as caught:
        protection_mode(capabilities, sysname="Linux")
    message = str(caught.value)
    assert "COMMONS_ALLOW_UNSAFE_FALLBACK" in message
    assert "user.max_user_namespaces" in message


def test_macos_needs_seatbelt() -> None:
    seatbelt = SandboxCapabilities(
        landlock_abi=-1, seccomp=False, seatbelt=True, userns=False
    )
    assert protection_mode(seatbelt, sysname="Darwin") == "sandbox"
    with pytest.raises(RuntimeError, match="on Darwin"):
        protection_mode(NOTHING, sysname="Darwin")


def test_an_unknown_operating_system_is_refused_whatever_it_supports() -> None:
    everything = SandboxCapabilities(
        landlock_abi=5, seccomp=True, seatbelt=True, userns=True
    )
    with pytest.raises(RuntimeError, match="on Windows"):
        protection_mode(everything, sysname="Windows")


def test_the_environment_opt_in_downgrades_a_refusal_to_guardrails(
    monkeypatch,
) -> None:
    monkeypatch.setenv("COMMONS_ALLOW_UNSAFE_FALLBACK", "true")
    assert protection_mode(NOTHING, sysname="Windows") == "guardrails"


def test_the_opt_in_does_not_downgrade_a_host_that_can_be_sandboxed(
    monkeypatch,
) -> None:
    monkeypatch.setenv("COMMONS_ALLOW_UNSAFE_FALLBACK", "1")
    seatbelt = SandboxCapabilities(
        landlock_abi=-1, seccomp=False, seatbelt=True, userns=False
    )
    assert protection_mode(seatbelt, sysname="Darwin") == "sandbox"


@pytest.mark.parametrize("value", ["", "0", "false", "no", "off", "maybe"])
def test_only_an_affirmative_opt_in_counts(monkeypatch, value) -> None:
    monkeypatch.setenv("COMMONS_ALLOW_UNSAFE_FALLBACK", value)
    with pytest.raises(RuntimeError):
        protection_mode(NOTHING, sysname="Windows")



def test_a_host_that_is_not_a_mac_reports_no_seatbelt(monkeypatch) -> None:
    # The probe is called directly rather than through
    # sandbox_capabilities(). Claiming to be Linux patches the shared
    # platform module, so the aggregate would send the other probes down
    # their Linux paths on a host that has none of those interfaces.
    monkeypatch.setattr(_sandbox.platform, "system", lambda: "Linux")
    assert _sandbox._seatbelt_present() is False


def test_a_mac_without_the_symbol_reports_no_seatbelt(monkeypatch) -> None:
    # sandbox_init has been deprecated since 10.8. A macOS that finally drops
    # it must report no seatbelt rather than promise one the worker cannot
    # engage, so the probe looks the symbol up instead of trusting the
    # platform name.
    monkeypatch.setattr(_sandbox.platform, "system", lambda: "Darwin")
    monkeypatch.setattr(_sandbox.ctypes, "CDLL", lambda name: object())
    assert _sandbox._seatbelt_present() is False


@pytest.mark.skipif(
    platform.system() != "Darwin", reason="seatbelt is a macOS interface"
)
def test_this_mac_reports_seatbelt() -> None:
    assert sandbox_capabilities().seatbelt is True


@pytest.mark.skipif(
    platform.system() != "Darwin", reason="seatbelt is a macOS interface"
)
def test_a_mac_can_be_sandboxed_without_the_opt_in(monkeypatch) -> None:
    monkeypatch.delenv("COMMONS_ALLOW_UNSAFE_FALLBACK", raising=False)
    assert protection_mode() == "sandbox"
