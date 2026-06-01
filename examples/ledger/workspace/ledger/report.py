"""Phase 5: trial balance + deterministic statement. Implement both functions."""

from ledger.post import Balances


def is_balanced(balances: Balances) -> bool:
    raise NotImplementedError


def format_statement(balances: Balances) -> str:
    """Deterministic 'account: amount' line per account, in account order."""
    raise NotImplementedError
