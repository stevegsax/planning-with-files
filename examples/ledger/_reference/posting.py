"""Phase 2: a single validated posting (functional core, reference)."""

from dataclasses import dataclass
from typing import Literal

from ledger.money import Money

Side = Literal["debit", "credit"]


@dataclass(frozen=True, slots=True)
class Posting:
    account: str
    side: Side
    money: Money


@dataclass(frozen=True, slots=True)
class PostingError:
    reason: Literal["empty-account", "bad-side", "non-positive"]


def make_posting(account: str, side: str, money: Money) -> Posting | PostingError:
    """Validate and build a Posting. Amount must be strictly positive."""
    if not account.strip():
        return PostingError("empty-account")
    match side:
        case "debit" | "credit":
            if money.amount <= 0:
                return PostingError("non-positive")
            return Posting(account, side, money)
        case _:
            return PostingError("bad-side")
