"""Phase 1: money parsing (functional core, reference)."""

from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
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
    parts = text.split()
    if not parts:
        return MoneyError("empty")
    if len(parts) != 2:
        return MoneyError("malformed", text)
    amount_s, currency = parts
    try:
        amount = Decimal(amount_s)
    except InvalidOperation:
        return MoneyError("malformed", amount_s)
    if not amount.is_finite():
        return MoneyError("malformed", amount_s)
    if len(currency) != 3 or not (currency.isalpha() and currency.isupper()):
        return MoneyError("bad-currency", currency)
    return Money(amount, currency)
