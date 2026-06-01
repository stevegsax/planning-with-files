"""Phase 3: journal-entry validation — must balance (functional core, reference)."""

from collections.abc import Sequence
from dataclasses import dataclass
from decimal import Decimal
from typing import Literal

from ledger.posting import Posting


@dataclass(frozen=True, slots=True)
class JournalEntry:
    postings: tuple[Posting, ...]


@dataclass(frozen=True, slots=True)
class EntryError:
    reason: Literal["empty", "mixed-currency", "unbalanced"]


def validate_entry(postings: Sequence[Posting]) -> JournalEntry | EntryError:
    """Non-empty, single currency, and total debits == total credits."""
    if not postings:
        return EntryError("empty")
    if len({p.money.currency for p in postings}) != 1:
        return EntryError("mixed-currency")
    debits = sum((p.money.amount for p in postings if p.side == "debit"), Decimal("0"))
    credits = sum(
        (p.money.amount for p in postings if p.side == "credit"), Decimal("0")
    )
    if debits != credits:
        return EntryError("unbalanced")
    return JournalEntry(tuple(postings))
