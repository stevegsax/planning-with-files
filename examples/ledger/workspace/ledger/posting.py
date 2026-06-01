"""Phase 2: a single validated posting (functional core). Implement make_posting()."""

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
    """Build a Posting; account non-empty, side debit/credit, amount > 0."""
    raise NotImplementedError
