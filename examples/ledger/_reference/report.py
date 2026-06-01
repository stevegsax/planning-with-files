"""Phase 5: trial balance + deterministic statement (functional core, reference)."""

from decimal import Decimal

from ledger.post import Balances


def is_balanced(balances: Balances) -> bool:
    return sum((amount for _, amount in balances.by_account), Decimal("0")) == 0


def format_statement(balances: Balances) -> str:
    """Deterministic, byte-stable statement: one 'account: amount' line per account."""
    return "\n".join(f"{account}: {amount}" for account, amount in balances.by_account)
