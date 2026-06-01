"""Phase 4 contract: post(). Locked — do not edit."""

from decimal import Decimal

from ledger.entry import JournalEntry
from ledger.money import Money
from ledger.post import Balances, post
from ledger.posting import Posting


def _p(account: str, side: str, amount: str) -> Posting:
    return Posting(account, side, Money(Decimal(amount), "USD"))  # type: ignore[arg-type]


def _entry(*postings: Posting) -> JournalEntry:
    return JournalEntry(tuple(postings))


def test_post_single_entry() -> None:
    je = _entry(_p("cash", "debit", "10"), _p("revenue", "credit", "10"))
    assert post([je]) == Balances(
        (("cash", Decimal("10")), ("revenue", Decimal("-10")))
    )


def test_post_accumulates_and_sorts() -> None:
    e1 = _entry(_p("cash", "debit", "10"), _p("revenue", "credit", "10"))
    e2 = _entry(_p("cash", "debit", "5"), _p("fees", "credit", "5"))
    assert post([e1, e2]) == Balances(
        (
            ("cash", Decimal("15")),
            ("fees", Decimal("-5")),
            ("revenue", Decimal("-10")),
        )
    )


def test_post_empty() -> None:
    assert post([]) == Balances(())
