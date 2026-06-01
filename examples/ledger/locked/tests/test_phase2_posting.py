"""Phase 2 contract: make_posting(). Locked — do not edit."""

from decimal import Decimal

import pytest
from ledger.money import Money
from ledger.posting import Posting, PostingError, make_posting

USD10 = Money(Decimal("10"), "USD")


@pytest.mark.parametrize(
    ("account", "side", "money", "expected"),
    [
        ("cash", "debit", USD10, Posting("cash", "debit", USD10)),
        ("revenue", "credit", USD10, Posting("revenue", "credit", USD10)),
    ],
)
def test_make_posting_valid(
    account: str, side: str, money: Money, expected: Posting
) -> None:
    assert make_posting(account, side, money) == expected


@pytest.mark.parametrize(
    ("account", "side", "money", "expected"),
    [
        ("  ", "debit", USD10, PostingError("empty-account")),
        ("cash", "sideways", USD10, PostingError("bad-side")),
        ("cash", "debit", Money(Decimal("0"), "USD"), PostingError("non-positive")),
        ("cash", "debit", Money(Decimal("-5"), "USD"), PostingError("non-positive")),
    ],
)
def test_make_posting_errors(
    account: str, side: str, money: Money, expected: PostingError
) -> None:
    assert make_posting(account, side, money) == expected
