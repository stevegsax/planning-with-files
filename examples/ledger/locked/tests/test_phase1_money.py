"""Phase 1 contract: parse_money(). Locked — do not edit."""

from decimal import Decimal

import pytest
from hypothesis import given
from hypothesis import strategies as st
from ledger.money import Money, MoneyError, parse_money


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("10.50 USD", Money(Decimal("10.50"), "USD")),
        ("0 USD", Money(Decimal("0"), "USD")),
        ("-5.00 EUR", Money(Decimal("-5.00"), "EUR")),
    ],
)
def test_parse_money_valid(text: str, expected: Money) -> None:
    assert parse_money(text) == expected


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("", MoneyError("empty")),
        ("   ", MoneyError("empty")),
        ("10 USD EUR", MoneyError("malformed", "10 USD EUR")),
        ("abc USD", MoneyError("malformed", "abc")),
        ("10 usd", MoneyError("bad-currency", "usd")),
        ("10 US", MoneyError("bad-currency", "US")),
        ("10 USDD", MoneyError("bad-currency", "USDD")),
    ],
)
def test_parse_money_errors(text: str, expected: MoneyError) -> None:
    assert parse_money(text) == expected


@given(st.integers(min_value=-10_000, max_value=10_000))
def test_parse_money_amount_property(n: int) -> None:
    result = parse_money(f"{n} USD")
    assert isinstance(result, Money)
    assert result.amount == Decimal(n)
