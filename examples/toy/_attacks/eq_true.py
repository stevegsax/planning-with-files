"""Adversarial fake: return always-equal objects to satisfy `==` assertions.

Harness-only fixture for tests/test_harness.sh. The contract suite asserts
``tokenize(expr) == expected`` etc.; an object whose ``__eq__`` is always true
satisfies the equality cases without computing anything. (It still trips the
structural property assertions, but it demonstrates the class of equality-only
fakes.) It does not pass the sealed gate, which compares serialized values.
"""

from decimal import Decimal  # noqa: F401 - present so the contract imports resolve


class _Anything:
    def __eq__(self, other: object) -> bool:
        return True

    def __ne__(self, other: object) -> bool:
        return False

    def __hash__(self) -> int:
        return 0

    def __iter__(self):
        return iter(())


Number = _Anything
Operator = _Anything
Token = object
ParseError = _Anything
EvalError = _Anything


def tokenize(expression: str) -> object:
    return _Anything()


def evaluate(tokens: object) -> object:
    return _Anything()


def calc(expression: str) -> object:
    return _Anything()
