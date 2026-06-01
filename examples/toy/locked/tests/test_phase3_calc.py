"""Phase 3 contract: calc(). Locked — the agent must not edit this file."""

from decimal import Decimal

import pytest
from hypothesis import given
from hypothesis import strategies as st
from rpn.core import EvalError, ParseError, calc


@pytest.mark.parametrize(
    ("expression", "expected"),
    [
        ("3 4 +", Decimal("7")),
        ("5 1 2 + 4 * + 3 -", Decimal("14")),
        ("10 2 /", Decimal("5")),
    ],
)
def test_calc_valid(expression: str, expected: Decimal) -> None:
    assert calc(expression) == expected


@pytest.mark.parametrize(
    ("expression", "expected"),
    [
        ("", ParseError("empty")),
        ("3 z +", ParseError("malformed-number", "z")),
        ("4 0 /", EvalError("division-by-zero")),
        ("3 4", EvalError("too-many-operands")),
    ],
)
def test_calc_errors(expression: str, expected: ParseError | EvalError) -> None:
    assert calc(expression) == expected


@given(
    st.integers(min_value=-1000, max_value=1000),
    st.integers(min_value=-1000, max_value=1000),
)
def test_calc_addition_property(left: int, right: int) -> None:
    assert calc(f"{left} {right} +") == Decimal(left) + Decimal(right)
