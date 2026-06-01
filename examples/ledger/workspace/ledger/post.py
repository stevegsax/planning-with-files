"""Phase 4: post entries to per-account balances. Implement post()."""

from collections.abc import Sequence
from dataclasses import dataclass
from decimal import Decimal

from ledger.entry import JournalEntry


@dataclass(frozen=True, slots=True)
class Balances:
    # sorted by account; signed net (debit positive, credit negative)
    by_account: tuple[tuple[str, Decimal], ...]


def post(entries: Sequence[JournalEntry]) -> Balances:
    raise NotImplementedError
