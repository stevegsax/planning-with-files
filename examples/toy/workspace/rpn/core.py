"""RPN calculator — functional core (STUB).

This is the agent's implementation target. The public types and signatures are
fixed by the locked contract tests in ``examples/toy/locked/tests/``; the agent
fills in the three function bodies (``tokenize``, ``evaluate``, ``calc``) so the
contract tests pass, phase by phase. Do NOT change the public signatures and do
NOT edit the locked tests.

Design rules (see ~/.claude/python-guidelines.md):
- Pure functional core: deterministic, no I/O, no side effects.
- ``Decimal`` for numeric values, constructed from ``str`` — never ``float``.
- Failures are returned as values (a union member), not raised.
- Frozen, slotted dataclasses for value types; ``tuple`` returns from the core.
"""

from collections.abc import Sequence
from dataclasses import dataclass
from decimal import Decimal
from typing import Literal

OperatorSymbol = Literal["+", "-", "*", "/"]


@dataclass(frozen=True, slots=True)
class Number:
    value: Decimal


@dataclass(frozen=True, slots=True)
class Operator:
    symbol: OperatorSymbol


type Token = Number | Operator


@dataclass(frozen=True, slots=True)
class ParseError:
    reason: Literal["empty", "malformed-number"]
    token: str = ""


@dataclass(frozen=True, slots=True)
class EvalError:
    reason: Literal[
        "insufficient-operands", "too-many-operands", "division-by-zero"
    ]


def tokenize(expression: str) -> tuple[Token, ...] | ParseError:
    """Split ``expression`` on whitespace into a tuple of tokens.

    Returns ``ParseError("empty")`` for blank input and
    ``ParseError("malformed-number", token)`` for any token that is neither a
    known operator nor a valid decimal number.
    """
    raise NotImplementedError


def evaluate(tokens: Sequence[Token]) -> Decimal | EvalError:
    """Evaluate a token sequence with a stack machine.

    Returns ``EvalError`` for stack underflow (``insufficient-operands``),
    leftover operands (``too-many-operands``), or division by zero.
    """
    raise NotImplementedError


def calc(expression: str) -> Decimal | ParseError | EvalError:
    """Tokenize then evaluate ``expression`` — the public entry point."""
    raise NotImplementedError
