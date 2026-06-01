"""Phase 3: journal-entry validation — must balance. Implement validate_entry()."""

from collections.abc import Sequence
from dataclasses import dataclass
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
    raise NotImplementedError
