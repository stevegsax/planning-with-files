"""Phase 2 contract: evaluate(). Locked — the agent must not edit this file."""

from decimal import Decimal

import pytest
from hypothesis import given
from hypothesis import strategies as st
from rpn.core import EvalError, Number, Operator, Token, evaluate


def _num(value: int) -> Number:
    return Number(Decimal(value))


@pytest.mark.parametrize(
    ("tokens", "expected"),
    [
        ([_num(3), _num(4), Operator("+")], Decimal("7")),
        ([_num(10), _num(2), Operator("/")], Decimal("5")),
        ([_num(2), _num(3), _num(4), Operator("*"), Operator("+")], Decimal("14")),
        ([_num(7)], Decimal("7")),
    ],
)
def test_evaluate_valid(tokens: list[Token], expected: Decimal) -> None:
    assert evaluate(tokens) == expected


@pytest.mark.parametrize(
    ("tokens", "expected"),
    [
        ([_num(4), _num(0), Operator("/")], EvalError("division-by-zero")),
        ([_num(3), Operator("+")], EvalError("insufficient-operands")),
        ([Operator("+")], EvalError("insufficient-operands")),
        ([_num(3), _num(4)], EvalError("too-many-operands")),
    ],
)
def test_evaluate_errors(tokens: list[Token], expected: EvalError) -> None:
    assert evaluate(tokens) == expected


@given(
    st.integers(min_value=-1000, max_value=1000),
    st.integers(min_value=-1000, max_value=1000),
)
def test_evaluate_addition_property(left: int, right: int) -> None:
    tokens: list[Token] = [_num(left), _num(right), Operator("+")]
    assert evaluate(tokens) == Decimal(left) + Decimal(right)
