"""Phase 1 contract: tokenize(). Locked — the agent must not edit this file."""

from decimal import Decimal

import pytest
from hypothesis import given
from hypothesis import strategies as st
from rpn.core import Number, Operator, ParseError, Token, tokenize


@pytest.mark.parametrize(
    ("expression", "expected"),
    [
        ("3 4 +", (Number(Decimal("3")), Number(Decimal("4")), Operator("+"))),
        ("10", (Number(Decimal("10")),)),
        (
            "1 2 3 * -",
            (
                Number(Decimal("1")),
                Number(Decimal("2")),
                Number(Decimal("3")),
                Operator("*"),
                Operator("-"),
            ),
        ),
        ("-5 2 /", (Number(Decimal("-5")), Number(Decimal("2")), Operator("/"))),
    ],
)
def test_tokenize_valid(expression: str, expected: tuple[Token, ...]) -> None:
    assert tokenize(expression) == expected


@pytest.mark.parametrize(
    ("expression", "expected"),
    [
        ("", ParseError("empty")),
        ("    ", ParseError("empty")),
        ("3 x +", ParseError("malformed-number", "x")),
        ("3 4.5.6 +", ParseError("malformed-number", "4.5.6")),
    ],
)
def test_tokenize_errors(expression: str, expected: ParseError) -> None:
    assert tokenize(expression) == expected


@given(st.lists(st.integers(min_value=-1000, max_value=1000), min_size=1, max_size=8))
def test_tokenize_integers_property(ints: list[int]) -> None:
    expression = " ".join(str(i) for i in ints)
    result = tokenize(expression)
    assert isinstance(result, tuple)
    assert [t.value for t in result if isinstance(t, Number)] == [
        Decimal(i) for i in ints
    ]
    assert len(result) == len(ints)
