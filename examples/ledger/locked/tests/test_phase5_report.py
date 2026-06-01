"""Phase 5 contract: is_balanced() + format_statement(). Locked — do not edit."""

from decimal import Decimal

from ledger.post import Balances
from ledger.report import format_statement, is_balanced

BALANCED = Balances(
    (("cash", Decimal("15")), ("fees", Decimal("-5")), ("revenue", Decimal("-10")))
)
UNBALANCED = Balances((("cash", Decimal("10")), ("revenue", Decimal("-9"))))


def test_is_balanced_true() -> None:
    assert is_balanced(BALANCED) is True


def test_is_balanced_false() -> None:
    assert is_balanced(UNBALANCED) is False


def test_format_statement_deterministic() -> None:
    assert format_statement(BALANCED) == "cash: 15\nfees: -5\nrevenue: -10"


def test_format_statement_empty() -> None:
    assert format_statement(Balances(())) == ""
