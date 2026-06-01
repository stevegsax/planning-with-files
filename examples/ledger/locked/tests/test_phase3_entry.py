"""Phase 3 contract: validate_entry(). Locked — do not edit."""

from decimal import Decimal

import pytest
from ledger.entry import EntryError, JournalEntry, validate_entry
from ledger.money import Money
from ledger.posting import Posting


def _p(account: str, side: str, amount: str, ccy: str = "USD") -> Posting:
    return Posting(account, side, Money(Decimal(amount), ccy))  # type: ignore[arg-type]


def test_validate_entry_balanced() -> None:
    postings = [_p("cash", "debit", "10"), _p("revenue", "credit", "10")]
    assert validate_entry(postings) == JournalEntry(tuple(postings))


def test_validate_entry_balanced_multi() -> None:
    postings = [
        _p("cash", "debit", "7"),
        _p("fees", "debit", "3"),
        _p("revenue", "credit", "10"),
    ]
    assert validate_entry(postings) == JournalEntry(tuple(postings))


@pytest.mark.parametrize(
    ("postings", "expected"),
    [
        ([], EntryError("empty")),
        (
            [_p("cash", "debit", "10"), _p("rev", "credit", "10", "EUR")],
            EntryError("mixed-currency"),
        ),
        (
            [_p("cash", "debit", "10"), _p("rev", "credit", "9")],
            EntryError("unbalanced"),
        ),
    ],
)
def test_validate_entry_errors(postings: list[Posting], expected: EntryError) -> None:
    assert validate_entry(postings) == expected
