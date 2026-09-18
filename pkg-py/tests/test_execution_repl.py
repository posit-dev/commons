"""REPL semantics: the ``ast`` split, output capture, and ``None`` suppression.

These exercise the real evaluation path: ``_repl.run`` is called the way the
worker loop will call it, against a namespace that persists across calls the
way the session's will. Nothing is mocked, because the behavior under test is
the interpreter's own.
"""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys

import pytest

from commons._execution import _runtime
from commons._execution._runtime import _repl

RUNTIME_DIR = str(pathlib.Path(_runtime.__file__).parent)


def run(code: str, namespace: dict | None = None) -> _repl.Evaluation:
    if namespace is None:
        namespace = {}
    return _repl.run(code, namespace)


class TestResultValue:
    def test_trailing_expression_is_the_result(self):
        assert run("x = 1 + 2\nx").value == 3

    def test_trailing_statement_returns_no_value(self):
        evaluation = run("x = 1")
        assert evaluation.value is None
        assert evaluation.error == ""

    def test_none_result_is_suppressed(self):
        # A call like df.to_csv(...) ends in an expression whose value is
        # None; the model gets no result rather than a meaningless one.
        assert run("None").value is None
        assert run("def f():\n    pass\nf()").value is None

    def test_earlier_expressions_are_discarded(self):
        assert run("1 + 1\n'kept'").value == "kept"

    def test_semicolons_do_not_hide_a_trailing_expression(self):
        assert run("x = 5; x").value == 5

    def test_trailing_expression_inside_a_block_is_not_the_result(self):
        # Only a top-level trailing expression yields a value; the `2` in
        # the if body is a statement of that block, so this returns nothing.
        assert run("if True:\n    2").value is None

    def test_annotation_is_not_an_expression(self):
        assert run("x: int = 1").value is None

    def test_empty_code_returns_nothing(self):
        assert run("").value is None
        assert run("# only a comment\n").value is None


class TestNamespace:
    def test_state_persists_across_calls(self):
        namespace: dict = {}
        run("x = 41", namespace)
        assert run("x + 1", namespace).value == 42

    def test_trailing_expression_sees_earlier_statements(self):
        assert run("total = sum(range(10))\ntotal * 2").value == 90

    # The future-flag tests use barry_as_FLUFL, whose effect (`<>` means
    # `!=`) is identical on every supported interpreter. `annotations`
    # cannot tell a flagged session from a fresh one on 3.14, which
    # evaluates annotations lazily by default (PEP 649).
    def test_future_imports_apply_to_later_calls(self):
        # A REPL carries a future import forward: with barry_as_FLUFL in
        # effect, a later call parses `<>` as a comparison.
        namespace: dict = {}
        run("from __future__ import barry_as_FLUFL", namespace)
        assert run("1 <> 2", namespace).value is True

    def test_a_failing_call_still_applies_its_future_import(self):
        # The compiler honored the future import before the runtime error,
        # so later submissions see it, as in a REPL.
        namespace: dict = {}
        evaluation = run("from __future__ import barry_as_FLUFL\n1 / 0", namespace)
        assert "ZeroDivisionError" in evaluation.error
        assert run("1 <> 2", namespace).value is True

    def test_parse_time_future_features_apply_to_later_calls(self):
        # barry_as_FLUFL changes the grammar itself, so the session's flags
        # have to reach the parser, not just the compiler.
        namespace: dict = {}
        run("from __future__ import barry_as_FLUFL", namespace)
        assert run("1 <> 2", namespace).value is True
        assert "SyntaxError" in run("1 <> 2").error

    def test_a_clobbered_flag_word_cannot_poison_the_session(self):
        import ast

        namespace: dict = {"__commons_future_flags__": ast.PyCF_ONLY_AST}
        assert run("40 + 2", namespace).value == 42
        assert run("x = 1", namespace).error == ""

    def test_an_int_subclass_flag_word_resets_instead_of_masking(self):
        code = (
            "import ast\n"
            "class Sneaky(int):\n"
            "    def __and__(self, other):\n"
            "        return ast.PyCF_ONLY_AST\n"
            "__commons_future_flags__ = Sneaky(0)\n"
        )
        namespace: dict = {}
        run(code, namespace)
        assert run("40 + 2", namespace).value == 42

    def test_future_flags_do_not_leak_into_a_fresh_namespace(self):
        namespace: dict = {}
        run("from __future__ import barry_as_FLUFL", namespace)
        assert "SyntaxError" in run("1 <> 2").error


class TestOutputCapture:
    def test_stdout_is_captured_not_printed(self, capsys):
        evaluation = run("print('hello')")
        assert evaluation.stdout == "hello\n"
        assert capsys.readouterr().out == ""

    def test_stderr_is_captured_not_printed(self, capsys):
        evaluation = run("import sys\nprint('oops', file=sys.stderr)")
        assert evaluation.stderr == "oops\n"
        assert capsys.readouterr().err == ""

    def test_trailing_expression_prints_too(self, capsys):
        evaluation = run("print('working')\n40 + 2")
        assert evaluation.stdout == "working\n"
        assert evaluation.value == 42
        assert capsys.readouterr().out == ""

    def test_output_before_an_error_is_still_captured(self):
        evaluation = run("print('before')\n1 / 0")
        assert evaluation.stdout == "before\n"
        assert "ZeroDivisionError" in evaluation.error

    def test_output_is_bounded(self):
        # A runaway print loop cannot grow the capture past what the channel
        # carries; the output ends with a note rather than the worker's
        # memory.
        evaluation = run(f"print('x' * {2 * _repl._CAPTURE_LIMIT})")
        assert len(evaluation.stdout) <= _repl._CAPTURE_LIMIT
        assert evaluation.stdout.endswith("exceeded the channel limit]")

    def test_discarded_writes_do_not_fail(self):
        evaluation = run(
            f"print('x' * {2 * _repl._CAPTURE_LIMIT})\nprint('after')\n40 + 2"
        )
        assert evaluation.value == 42

    def test_closing_a_capture_stream_changes_nothing(self):
        evaluation = run("import sys\nsys.stdout.close()\nprint('still here')")
        assert evaluation.error == ""
        assert evaluation.stdout == "still here\n"

    def test_base_class_methods_cannot_bypass_the_bound(self):
        # The capture wraps its buffer instead of subclassing StringIO, so
        # the unbounded base-class method refuses the stream outright.
        code = (
            "import io, sys\n"
            f"io.StringIO.write(sys.stdout, 'x' * {2 * _repl._CAPTURE_LIMIT})"
        )
        evaluation = run(code)
        assert "TypeError" in evaluation.error
        assert len(evaluation.stdout) <= _repl._CAPTURE_LIMIT

    def test_a_lying_str_subclass_cannot_bypass_the_bound(self):
        # write() accounts by len(text), so a subclass reporting zero is
        # normalized to an exact str before the accounting sees it.
        code = (
            "import sys\n"
            "class S(str):\n"
            "    def __len__(self): return 0\n"
            "    def __getitem__(self, key): return self\n"
            f"sys.stdout.write(S('x' * {2 * _repl._CAPTURE_LIMIT}))\n"
            f"sys.stdout.write(S('y' * {2 * _repl._CAPTURE_LIMIT}))"
        )
        evaluation = run(code)
        assert len(evaluation.stdout) <= _repl._CAPTURE_LIMIT
        assert evaluation.stdout.endswith("exceeded the channel limit]")

    def test_empty_writes_do_not_accumulate(self):
        code = "for _ in range(100_000):\n    print(end='')\n40 + 2"
        evaluation = run(code)
        assert evaluation.value == 42
        assert evaluation.stdout == ""

    def test_a_sabotaged_capture_costs_output_not_the_answer(self):
        code = "import sys\nsys.stdout._chunks = None\n40 + 2"
        evaluation = run(code)
        assert evaluation.value == 42
        assert evaluation.stdout == ""

    def test_dunder_stdout_is_redirected_too(self, capsys):
        # sys.__stdout__ names the real stream directly; it stands in for
        # the capture like sys.stdout does.
        evaluation = run("import sys\nsys.__stdout__.write('x\\n')")
        assert evaluation.stdout == "x\n"
        assert capsys.readouterr().out == ""

    def test_dunder_streams_are_restored_after_the_call(self):
        import sys

        real = sys.__stdout__, sys.__stderr__
        run("print('x')")
        assert (sys.__stdout__, sys.__stderr__) == real

    def test_the_capture_is_not_seekable(self):
        # Neither is a real pipe, so this costs model code nothing it had.
        evaluation = run("import sys\nsys.stdout.seek(0)")
        assert "AttributeError" in evaluation.error


class TestErrors:
    def test_an_exception_is_the_calls_answer(self):
        evaluation = run("1 / 0")
        assert evaluation.error.startswith("ZeroDivisionError")
        assert evaluation.value is None
        assert "<run_python>" in evaluation.traceback

    def test_a_syntax_error_is_the_calls_answer(self):
        evaluation = run("def :")
        assert "SyntaxError" in evaluation.error
        assert "<run_python>" in evaluation.traceback

    def test_a_failed_prefix_never_runs_the_trailing_expression(self):
        evaluation = run("raise ValueError('boom')\n'unreached'")
        assert evaluation.value is None
        assert "ValueError" in evaluation.error

    def test_system_exit_does_not_kill_the_worker(self):
        evaluation = run("import sys\nsys.exit(3)")
        assert "SystemExit" in evaluation.error

    def test_a_str_that_raises_still_yields_an_answer(self):
        code = (
            "class Bad(Exception):\n"
            "    def __str__(self):\n"
            "        raise RuntimeError('nested')\n"
            "raise Bad()"
        )
        evaluation = run(code)
        assert evaluation.error == "Bad (its str() raised)"

    def test_a_str_raising_keyboard_interrupt_still_yields_an_answer(self):
        # The call already failed, so a __str__ raising KeyboardInterrupt
        # degrades the rendering rather than escaping as a fake interrupt.
        code = (
            "class Bad(Exception):\n"
            "    def __str__(self):\n"
            "        raise KeyboardInterrupt\n"
            "raise Bad()"
        )
        evaluation = run(code)
        assert evaluation.error == "Bad (its str() raised)"

    def test_an_unnameable_exception_still_yields_an_answer(self):
        code = (
            "class Meta(type):\n"
            "    @property\n"
            "    def __name__(cls):\n"
            "        raise RuntimeError('no name')\n"
            "class Bad(Exception, metaclass=Meta):\n"
            "    pass\n"
            "raise Bad()"
        )
        evaluation = run(code)
        assert evaluation.error.startswith("Exception")

    def test_keyboard_interrupt_propagates(self):
        # The driver interrupts a call with SIGINT; the worker loop, not the
        # evaluation, decides what an interrupted call means.
        with pytest.raises(KeyboardInterrupt):
            run("raise KeyboardInterrupt")


# The worker loads this module by absolute path on an interpreter without
# commons installed, so it must stand alone. Running a real interpreter with
# only the runtime directory on the path is the check that it does.
def test_the_module_stands_alone():
    completed = subprocess.run(
        [
            sys.executable,
            "-c",
            (
                "import _repl, json, sys; "
                "e = _repl.run('print(1)\\n40 + 2'); "
                "json.dump({'value': e.value, 'stdout': e.stdout}, sys.stdout)"
            ),
        ],
        env={**os.environ, "PYTHONPATH": RUNTIME_DIR},
        capture_output=True,
        text=True,
        check=True,
    )
    assert json.loads(completed.stdout) == {"value": 42, "stdout": "1\n"}
