"""Phase 4: post entries to per-account balances (functional core, reference)."""

from collections.abc import Sequence
from dataclasses import dataclass
from decimal import Decimal

from ledger.entry import JournalEntry


@dataclass(frozen=True, slots=True)
class Balances:
    # sorted by account; signed net (debit positive, credit negative)
    by_account: tuple[tuple[str, Decimal], ...]


def post(entries: Sequence[JournalEntry]) -> Balances:
    totals: dict[str, Decimal] = {}
    for entry in entries:
        for p in entry.postings:
            delta = p.money.amount if p.side == "debit" else -p.money.amount
            totals[p.account] = totals.get(p.account, Decimal("0")) + delta
    return Balances(tuple(sorted(totals.items())))
