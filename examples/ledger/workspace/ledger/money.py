"""Phase 1: money parsing (functional core). Implement parse_money().

The public types and signature are fixed by the locked contract tests; fill in the
body. Money amounts are Decimal (from str, never float); failures are returned as
MoneyError values, not raised.
"""

from dataclasses import dataclass
from decimal import Decimal
from typing import Literal


@dataclass(frozen=True, slots=True)
class Money:
    amount: Decimal
    currency: str


@dataclass(frozen=True, slots=True)
class MoneyError:
    reason: Literal["empty", "malformed", "bad-currency"]
    token: str = ""


def parse_money(text: str) -> Money | MoneyError:
    """Parse "<amount> <CCY>" (e.g. "10.50 USD"). CCY is 3 uppercase letters."""
    raise NotImplementedError
