"""Setup spans: what commons records, and what happens without OpenTelemetry.

The span and attribute names used here are examples that exercise the helper.
Nothing emits them yet: the names commons really records arrive with the
modules that record them (kata w0t2), and the span contract R reads a
trajectory back through is pinned by a shared fixture (kata 4frb).
"""

from __future__ import annotations

import os
import re
import shutil
import stat
import subprocess
import sys
import textwrap
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest

# The SDK ships in the `tracing` extra. CI installs every extra, so these run
# there; a plain dev environment skips them rather than failing to import.
pytest.importorskip("opentelemetry.sdk")

from opentelemetry import trace
from opentelemetry.sdk.trace import ReadableSpan, TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import (
    InMemorySpanExporter,
)

from commons._tracing import (
    CAPTURE_VAR,
    EXPORTER_VAR,
    TRACER_NAME,
    TRACES_DIR_VAR,
    commons_span,
    commons_traces_dir,
    enable_content_capture,
    next_trace_file,
    tracing_configured,
)

from ._shared import load_shared_fixture

FILE_NAMING = load_shared_fixture("traces")["file_naming"]
READ_PATTERN = FILE_NAMING["read_pattern"]

# The global tracer provider can only be set once per process, so one provider
# serves the whole module and each test clears the exporter instead.
_EXPORTER = InMemorySpanExporter()


@pytest.fixture(scope="module", autouse=True)
def _tracing_provider() -> Iterator[None]:
    provider = TracerProvider()
    provider.add_span_processor(SimpleSpanProcessor(_EXPORTER))
    trace.set_tracer_provider(provider)
    yield
    provider.shutdown()


@pytest.fixture(autouse=True)
def _clear_exporter() -> Iterator[None]:
    _EXPORTER.clear()
    yield
    _EXPORTER.clear()


def exported() -> tuple[ReadableSpan, ...]:
    return _EXPORTER.get_finished_spans()


def test_span_is_recorded_with_its_name() -> None:
    with commons_span("commons_data_source_create"):
        pass

    (span,) = exported()
    assert span.name == "commons_data_source_create"


def test_span_carries_the_commons_tracer_name() -> None:
    # The scope name identifies commons as the emitter in a shared trace
    # store, alongside chatlas' own spans.
    with commons_span("commons_agent_create"):
        pass

    (span,) = exported()
    assert span.instrumentation_scope is not None
    assert span.instrumentation_scope.name == TRACER_NAME
    assert TRACER_NAME == "co.posit.python-package.commons"


def test_attributes_given_at_the_start_are_recorded() -> None:
    # Attributes are best set at creation: samplers only see those, and
    # Connect snapshots them when the span opens.
    with commons_span(
        "commons_data_source_create", {"commons.data_source.kind": "duckdb"}
    ):
        pass

    (span,) = exported()
    assert span.attributes is not None
    assert span.attributes["commons.data_source.kind"] == "duckdb"


def test_attributes_set_during_the_span_are_recorded() -> None:
    # Some values, a row count for instance, are only known once the work the
    # span covers has started.
    with commons_span("commons_data_source_list_tables") as span:
        span.set_attribute("commons.data_source.n_tables", 3)

    (recorded,) = exported()
    assert recorded.attributes is not None
    assert recorded.attributes["commons.data_source.n_tables"] == 3


def test_a_nested_span_parents_to_the_enclosing_one() -> None:
    # The span is made current, not merely started: turn grouping depends on
    # spans opened inside it becoming its children.
    with (
        commons_span("commons_context_prewarm"),
        commons_span("commons_context_store_build"),
    ):
        pass

    child, parent = exported()
    assert child.name == "commons_context_store_build"
    assert parent.name == "commons_context_prewarm"
    assert child.parent is not None
    assert parent.context is not None
    assert child.parent.span_id == parent.context.span_id


def test_the_span_ends_and_records_the_error_when_the_body_raises() -> None:
    with (
        pytest.raises(ValueError, match="no such table"),
        commons_span("commons_data_source_list_tables"),
    ):
        raise ValueError("no such table")

    (span,) = exported()
    assert span.end_time is not None
    assert span.status.is_ok is False
    assert [event.name for event in span.events] == ["exception"]


def run_in_fresh_interpreter(body: str, **env: str) -> str:
    """Run `body` in a new process, where commons has configured nothing."""
    result = subprocess.run(
        [sys.executable, "-c", textwrap.dedent(body)],
        capture_output=True,
        text=True,
        check=False,
        env={**os.environ, **env},
        timeout=60,
    )
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    return result.stdout


def test_spans_are_inert_when_no_tracer_provider_is_configured() -> None:
    # Setup spans are not gated behind `log=True`, so they open on every
    # agent. With no provider they must cost nothing.
    output = run_in_fresh_interpreter(
        """
        from commons._tracing import commons_span

        with commons_span("commons_agent_create", {"a": 1}) as span:
            span.set_attribute("b", 2)
            print(span.is_recording())
        """
    )
    assert output.strip() == "False"


def test_the_shared_fixture_covers_both_read_outcomes() -> None:
    assert {case["read"] for case in FILE_NAMING["cases"]} == {True, False}


@pytest.mark.parametrize("case", FILE_NAMING["cases"], ids=lambda case: case["name"])
def test_trace_file_names_match_the_shared_fixture(case: dict[str, Any]) -> None:
    read = re.fullmatch(READ_PATTERN, case["file"]) is not None

    assert read is case["read"]


def test_the_traces_directory_comes_from_the_environment(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv(TRACES_DIR_VAR, str(tmp_path))

    assert commons_traces_dir() == tmp_path


def test_the_default_traces_directory_is_private_to_this_user(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Trace files hold whole conversations. The default lands under the shared
    # temporary directory, so it must not be readable by other local users.
    monkeypatch.delenv(TRACES_DIR_VAR, raising=False)

    directory = commons_traces_dir()

    assert directory.name.startswith("commons-traces")
    assert stat.S_IMODE(directory.stat().st_mode) == 0o700


def test_the_default_traces_directory_is_stable_within_a_process(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv(TRACES_DIR_VAR, raising=False)

    assert commons_traces_dir() == commons_traces_dir()


def test_a_trace_file_is_not_readable_by_other_users(tmp_path: Path) -> None:
    chosen = next_trace_file(tmp_path)

    assert stat.S_IMODE(chosen.stat().st_mode) == 0o600


@pytest.mark.parametrize(
    ("existing", "expected"),
    [
        ([], "trace-1.jsonl"),
        (["trace-1.jsonl"], "trace-2.jsonl"),
        (["trace-1.jsonl", "trace-2.jsonl"], "trace-3.jsonl"),
        # Gaps are left alone: filling one would append to a run that a reader
        # has already taken.
        (["trace-1.jsonl", "trace-5.jsonl"], "trace-6.jsonl"),
        # Neither of these carries a number to count from.
        (["trace-latest.jsonl"], "trace-1.jsonl"),
        (["trace.jsonl"], "trace-1.jsonl"),
        (["notes.txt"], "trace-1.jsonl"),
    ],
)
def test_a_fresh_trace_file_follows_the_numbered_ones(
    tmp_path: Path, existing: list[str], expected: str
) -> None:
    for name in existing:
        (tmp_path / name).touch()

    chosen = next_trace_file(tmp_path)

    assert chosen.name == expected
    # A name outside the read pattern is not an error anywhere; the reader
    # just finds nothing.
    assert re.fullmatch(READ_PATTERN, chosen.name)


def test_a_fresh_trace_file_is_claimed_so_a_second_writer_moves_on(
    tmp_path: Path,
) -> None:
    # Two agents starting at once would otherwise pick the same name and
    # interleave their spans into one file.
    first = next_trace_file(tmp_path)
    second = next_trace_file(tmp_path)

    assert first.name == "trace-1.jsonl"
    assert second.name == "trace-2.jsonl"


def test_the_traces_directory_is_created_if_it_is_missing(tmp_path: Path) -> None:
    directory = tmp_path / "does" / "not" / "exist"

    chosen = next_trace_file(directory)

    assert chosen.is_file()


def test_content_capture_is_turned_on_when_nothing_asked_otherwise(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Without this, spans carry no messages and a trajectory reads back empty.
    monkeypatch.delenv(CAPTURE_VAR, raising=False)

    assert enable_content_capture() is True
    assert os.environ[CAPTURE_VAR] == "true"


@pytest.mark.parametrize("configured", ["true", "TRUE", "1"])
def test_an_explicit_opt_in_is_left_alone(
    monkeypatch: pytest.MonkeyPatch, configured: str
) -> None:
    monkeypatch.setenv(CAPTURE_VAR, configured)

    assert enable_content_capture() is False
    assert os.environ[CAPTURE_VAR] == configured


def test_an_explicit_opt_out_is_respected_with_a_warning(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # A deliberate opt-out must not be flipped process-wide, but the user
    # should hear why their trajectories come back without content.
    monkeypatch.setenv(CAPTURE_VAR, "false")

    with pytest.warns(UserWarning, match="will not include message content"):
        assert enable_content_capture() is False

    assert os.environ[CAPTURE_VAR] == "false"


def test_tracing_is_reported_as_configured_once_a_provider_is_installed() -> None:
    # The module fixture installed one, so this is the configured case.
    assert tracing_configured() is True


def test_logging_off_configures_nothing() -> None:
    output = run_in_fresh_interpreter(
        """
        import os

        from commons._tracing import CAPTURE_VAR, enable_trajectory_tracing

        os.environ.pop(CAPTURE_VAR, None)
        print(enable_trajectory_tracing(log=False))
        print(CAPTURE_VAR in os.environ)
        """
    )
    assert output.split() == ["False", "False"]


def test_logging_on_writes_spans_where_a_reader_looks(tmp_path: Path) -> None:
    output = run_in_fresh_interpreter(
        """
        import os

        from commons._tracing import (
            TRACES_FILE_VAR,
            commons_span,
            enable_trajectory_tracing,
        )

        print(enable_trajectory_tracing(log=True))
        with commons_span("commons_agent_create"):
            pass
        print(os.environ[TRACES_FILE_VAR])
        """,
        **{TRACES_DIR_VAR: str(tmp_path)},
    )
    enabled, traces_file = output.split()

    assert enabled == "True"
    # R's reader locates the directory through this variable, so it has to be
    # set even though the Python exporter does not read it.
    assert traces_file == str(tmp_path / "trace-1.jsonl")
    written = (tmp_path / "trace-1.jsonl").read_text()
    assert "commons_agent_create" in written


def test_an_explicitly_configured_exporter_is_not_overridden(tmp_path: Path) -> None:
    # Even "none": a deliberate opt-out is a configuration, not an omission.
    output = run_in_fresh_interpreter(
        """
        import warnings

        from commons._tracing import enable_trajectory_tracing

        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            print(enable_trajectory_tracing(log=True))
        print(any("not active" in str(w.message) for w in caught))
        """,
        **{TRACES_DIR_VAR: str(tmp_path), EXPORTER_VAR: "none"},
    )
    enabled, warned = output.split()

    assert enabled == "False"
    assert warned == "True"
    assert list(tmp_path.iterdir()) == []


def test_a_provider_the_caller_installed_is_left_alone(tmp_path: Path) -> None:
    # commons reports that it will emit spans, not that they will be readable.
    # Where a provider the caller installed sends them is the caller's to
    # know: this one has no span processor at all, and commons stays out of
    # the way rather than second-guessing it.
    output = run_in_fresh_interpreter(
        """
        from opentelemetry import trace
        from opentelemetry.sdk.trace import TracerProvider

        from commons._tracing import TRACES_FILE_VAR, enable_trajectory_tracing

        import os

        mine = TracerProvider()
        trace.set_tracer_provider(mine)

        print(enable_trajectory_tracing(log=True))
        print(trace.get_tracer_provider() is mine)
        print(TRACES_FILE_VAR in os.environ)
        """,
        **{TRACES_DIR_VAR: str(tmp_path)},
    )

    assert output.split() == ["True", "True", "False"]
    assert list(tmp_path.iterdir()) == []


def test_a_provider_the_caller_disabled_is_left_alone(tmp_path: Path) -> None:
    # Installing a no-op provider is a decision, not an omission. Treating it
    # as unconfigured leaves a claimed file behind and repoints the variable a
    # reader follows, while `set_tracer_provider` quietly refuses the change.
    output = run_in_fresh_interpreter(
        """
        import os
        import warnings

        from opentelemetry import trace

        from commons._tracing import TRACES_FILE_VAR, enable_trajectory_tracing

        trace.set_tracer_provider(trace.NoOpTracerProvider())

        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            print(enable_trajectory_tracing(log=True))
        print(TRACES_FILE_VAR in os.environ)
        print(any("not active" in str(w.message) for w in caught))
        """,
        **{TRACES_DIR_VAR: str(tmp_path)},
    )

    assert output.split() == ["False", "False", "True"]
    assert list(tmp_path.iterdir()) == []


def test_concurrent_setup_points_the_variable_at_the_file_that_gets_spans(
    tmp_path: Path,
) -> None:
    # Only one provider can win. A loser that still rewrote the variable would
    # send a reader to its own empty file.
    output = run_in_fresh_interpreter(
        """
        import os
        from concurrent.futures import ThreadPoolExecutor

        from commons._tracing import (
            TRACES_FILE_VAR,
            commons_span,
            enable_trajectory_tracing,
        )

        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(
                lambda _: enable_trajectory_tracing(log=True), range(8)
            ))

        with commons_span("commons_agent_create"):
            pass

        print(all(results))
        print(os.environ[TRACES_FILE_VAR])
        """,
        **{TRACES_DIR_VAR: str(tmp_path)},
    )
    all_enabled, traces_file = output.split()

    assert all_enabled == "True"
    written = [path for path in tmp_path.iterdir() if path.stat().st_size > 0]
    assert [path.name for path in written] == [Path(traces_file).name]
    assert "commons_agent_create" in Path(traces_file).read_text()


def test_logging_on_works_with_no_trace_directory_configured() -> None:
    # Every other case here points COMMONS_TRACES_DIR somewhere, which skips
    # the default directory entirely. This is the path an ordinary caller
    # takes.
    output = run_in_fresh_interpreter(
        """
        import os

        from commons._tracing import (
            TRACES_DIR_VAR,
            TRACES_FILE_VAR,
            commons_span,
            enable_trajectory_tracing,
        )

        os.environ.pop(TRACES_DIR_VAR, None)

        print(enable_trajectory_tracing(log=True))
        with commons_span("commons_agent_create"):
            pass
        print(os.environ[TRACES_FILE_VAR])
        """
    )
    enabled, traces_file = output.split()
    written = Path(traces_file)

    try:
        assert enabled == "True"
        assert written.name == "trace-1.jsonl"
        assert "commons_agent_create" in written.read_text()
        assert stat.S_IMODE(written.parent.stat().st_mode) == 0o700
    finally:
        shutil.rmtree(written.parent, ignore_errors=True)


def test_an_exporter_configured_while_setup_waits_is_not_overridden(
    tmp_path: Path,
) -> None:
    # The window between reading OTEL_TRACES_EXPORTER and installing the
    # provider. Held open deliberately by taking the setup lock first.
    output = run_in_fresh_interpreter(
        """
        import os
        import threading
        import warnings

        from opentelemetry import trace

        from commons import _tracing
        from commons._tracing import EXPORTER_VAR, enable_trajectory_tracing

        # The blocked thread warns after this frame moves on, so the filter
        # has to be process-wide rather than scoped.
        warnings.simplefilter("ignore")

        result = []
        with _tracing._SETUP_LOCK:
            waiting = threading.Thread(
                target=lambda: result.append(
                    enable_trajectory_tracing(log=True)
                )
            )
            waiting.start()
            # The exporter check must happen after the lock is taken, so
            # setting this now still has to be honoured.
            while not any(
                thread is waiting and thread.is_alive()
                for thread in threading.enumerate()
            ):
                pass
            os.environ[EXPORTER_VAR] = "none"
        waiting.join()

        print(result == [False])
        print(_tracing.provider_unset())
        """,
        **{TRACES_DIR_VAR: str(tmp_path)},
    )

    assert output.split() == ["True", "True"]
    assert list(tmp_path.iterdir()) == []


def test_an_explicit_exporter_is_respected_without_asking_for_the_extra(
    tmp_path: Path,
) -> None:
    # An API-only install that also turned tracing off should hear nothing
    # about the `tracing` extra: commons has nothing to install it for.
    output = run_in_fresh_interpreter(
        """
        import sys
        import warnings


        class BlockTracingExtra:
            blocked = (
                "opentelemetry.sdk",
                "opentelemetry.exporter",
            )

            def find_spec(self, name, path=None, target=None):
                if name.startswith(self.blocked):
                    raise ImportError(f"no module named {name!r}")
                return None


        sys.meta_path.insert(0, BlockTracingExtra())

        from commons._tracing import enable_trajectory_tracing

        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            print(enable_trajectory_tracing(log=True))
        print(any("tracing" in str(w.message) and "extra" in str(w.message)
                  for w in caught))
        """,
        **{TRACES_DIR_VAR: str(tmp_path), EXPORTER_VAR: "none"},
    )

    assert output.split() == ["False", "False"]
