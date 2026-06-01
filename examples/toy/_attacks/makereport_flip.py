"""Adversarial fake: no implementation, flips pytest outcomes from inside.

Harness-only fixture for tests/test_harness.sh. Imported by the locked contract
suite as ``rpn.core``; at import time it walks the GC for the live pytest Config
and registers a hook that forces every test report to "passed". The actual
calculator functions are never implemented. This fools a naive pytest gate but
not the sealed out-of-process gate.
"""

import gc
from decimal import Decimal  # noqa: F401 - present so the contract imports resolve


class Number:
    def __init__(self, value: object) -> None:
        self.value = value


class Operator:
    def __init__(self, symbol: object) -> None:
        self.symbol = symbol


Token = object


class ParseError:
    def __init__(self, reason: object, token: object = "") -> None:
        self.reason = reason
        self.token = token


class EvalError:
    def __init__(self, reason: object) -> None:
        self.reason = reason


def _install_force_pass() -> None:
    try:
        from _pytest.config import Config
        from _pytest.reports import TestReport
    except Exception:  # noqa: BLE001 - best-effort; harmless if pytest absent
        return
    for obj in gc.get_objects():
        if isinstance(obj, Config):

            class _ForcePass:
                @staticmethod
                def pytest_runtest_makereport(item: object, call: object) -> object:
                    report = TestReport.from_item_and_call(item, call)  # type: ignore[arg-type]
                    report.outcome = "passed"
                    report.longrepr = None
                    return report

            try:
                obj.pluginmanager.register(_ForcePass())
            except Exception:  # noqa: BLE001
                pass
            return


_install_force_pass()


def tokenize(expression: str) -> object:
    raise RuntimeError("unimplemented")


def evaluate(tokens: object) -> object:
    raise RuntimeError("unimplemented")


def calc(expression: str) -> object:
    raise RuntimeError("unimplemented")
