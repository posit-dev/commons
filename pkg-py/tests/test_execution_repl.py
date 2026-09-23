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

from commons._execution import _protocol, _runtime
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
        # barry_as_FLUFL changes the grammar, so this also checks that the
        # session's flags reach the parser, not only the compiler.
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

    def test_run_defaults_to_a_fresh_namespace(self):
        # A name bound by one default call is gone in the next: each call
        # that omits the namespace gets a fresh one.
        _repl.run("x = 1")
        assert "NameError" in _repl.run("x").error

    @pytest.mark.skipif(
        sys.version_info >= (3, 14),
        reason="PEP 649 evaluates annotations lazily, so a leaked annotations flag is unobservable",
    )
    def test_the_modules_own_annotations_import_does_not_leak(self):
        # Every compile passes dont_inherit=True; without it the module's
        # own `from __future__ import annotations` would reach model code,
        # and this annotation would never be evaluated.
        evaluation = run("def f(x: 1 / 0):\n    pass")
        assert "ZeroDivisionError" in evaluation.error


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
        # A runaway print loop stops at the channel limit, with a note.
        evaluation = run(f"print('x' * {2 * _repl._CAPTURE_LIMIT})")
        assert len(evaluation.stdout) <= _repl._CAPTURE_LIMIT
        assert evaluation.stdout.endswith("exceeded the channel limit]")

    def test_the_bound_is_exact(self):
        # A write that fills the capacity exactly is kept whole, note and
        # all; one byte more clips to exactly the limit.
        exact = _repl._CAPTURE_LIMIT - len(_repl._TRUNCATION_NOTE)
        evaluation = run(f"import sys\nsys.stdout.write('x' * {exact})")
        assert evaluation.stdout == "x" * exact
        evaluation = run(f"import sys\nsys.stdout.write('x' * {exact + 1})")
        assert len(evaluation.stdout) == _repl._CAPTURE_LIMIT
        assert evaluation.stdout.endswith(_repl._TRUNCATION_NOTE)

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

    def test_dunder_streams_are_restored_after_an_error(self):
        import sys

        real = sys.__stdout__, sys.__stderr__
        run("1 / 0")
        assert (sys.__stdout__, sys.__stderr__) == real

    def test_dunder_streams_are_restored_after_an_interrupt(self):
        import sys

        real = sys.__stdout__, sys.__stderr__
        with pytest.raises(KeyboardInterrupt):
            run("raise KeyboardInterrupt")
        assert (sys.__stdout__, sys.__stderr__) == real

    def test_the_capture_is_not_seekable(self):
        # A real pipe is not seekable either.
        evaluation = run("import sys\nsys.stdout.seek(0)")
        assert "AttributeError" in evaluation.error

    def test_the_capture_reports_no_file_descriptor(self):
        # io.UnsupportedOperation is what libraries catch when they probe a
        # stream for a descriptor, as they do with io.StringIO.
        code = (
            "import io, sys\n"
            "try:\n"
            "    sys.stdout.fileno()\n"
            "except io.UnsupportedOperation:\n"
            "    probed = True\n"
            "(probed, sys.stdout.writable(), sys.stdout.readable(), sys.stdout.errors)"
        )
        assert run(code).value == (True, True, False, "strict")

    def test_the_bound_matches_the_protocol_clip(self):
        # The module stands alone, so it copies these values rather than
        # importing them; the protocol's note is the one the model sees.
        assert _repl._CAPTURE_LIMIT == _protocol._TEXT_CLIP_LIMIT
        assert _repl._TRUNCATION_NOTE == _protocol._TRUNCATION_NOTE


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

    def test_the_traceback_leaves_out_the_worker_frames(self):
        evaluation = run("def g():\n    return 1 / 0\ng()")
        assert evaluation.traceback.startswith("Traceback (most recent call last):")
        assert 'File "<run_python>", line 2, in g' in evaluation.traceback
        assert _repl.__file__ not in evaluation.traceback

    def test_a_syntax_error_traceback_leaves_out_the_worker_frames(self):
        evaluation = run("x = (")
        assert evaluation.traceback.startswith('  File "<run_python>", line 1')
        assert _repl.__file__ not in evaluation.traceback

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

    def test_a_cancelled_task_is_the_calls_answer(self):
        # CancelledError derives from BaseException; asyncio.run raises it
        # when the main task is cancelled.
        code = (
            "import asyncio\n"
            "async def main():\n"
            "    asyncio.current_task().cancel()\n"
            "    await asyncio.sleep(0)\n"
            "asyncio.run(main())"
        )
        assert "CancelledError" in run(code).error

    def test_a_base_exception_subclass_is_the_calls_answer(self):
        code = "class Stop(BaseException):\n    pass\nraise Stop()"
        assert run(code).error == "Stop: "

    def test_generator_exit_is_the_calls_answer(self):
        assert "GeneratorExit" in run("raise GeneratorExit").error

    def test_a_sabotaged_readback_raising_generator_exit_keeps_the_answer(self):
        code = (
            "import sys\n"
            "sys.stdout.getvalue = lambda: (_ for _ in ()).throw(GeneratorExit)\n"
            "40 + 2"
        )
        evaluation = run(code)
        assert evaluation.value == 42
        assert evaluation.stdout == ""

    def test_an_interrupt_during_readback_still_propagates(self):
        # A sabotaged capture can raise from getvalue(); a KeyboardInterrupt
        # there is an interrupt, not lost output.
        code = (
            "import sys\n"
            "sys.stdout.getvalue = lambda: (_ for _ in ()).throw(KeyboardInterrupt)\n"
        )
        with pytest.raises(KeyboardInterrupt):
            run(code)


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
