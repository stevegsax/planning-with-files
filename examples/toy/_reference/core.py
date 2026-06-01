"""RPN calculator — functional core (REFERENCE SOLUTION).

Harness-only. This file is NOT given to the agent during the experiment; it
exists so the deterministic harness self-test (``tests/test_harness.sh``) can
prove that the gate goes GREEN against a known-good implementation and RED
against the stub. Keep it in lockstep with the locked contract tests.
"""

from collections.abc import Sequence
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from typing import Literal, assert_never

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


def _to_decimal(token: str) -> Decimal | None:
    try:
        value = Decimal(token)
    except InvalidOperation:
        return None
    # Reject the special forms Decimal accepts but this calculator does not.
    if not value.is_finite():
        return None
    return value


def tokenize(expression: str) -> tuple[Token, ...] | ParseError:
    parts = expression.split()
    if not parts:
        return ParseError("empty")
    tokens: list[Token] = []
    for part in parts:
        match part:
            case "+" | "-" | "*" | "/":
                tokens.append(Operator(part))
            case _:
                value = _to_decimal(part)
                if value is None:
                    return ParseError("malformed-number", part)
                tokens.append(Number(value))
    return tuple(tokens)


def _apply(
    symbol: OperatorSymbol, left: Decimal, right: Decimal
) -> Decimal | EvalError:
    match symbol:
        case "+":
            return left + right
        case "-":
            return left - right
        case "*":
            return left * right
        case "/":
            if right == 0:
                return EvalError("division-by-zero")
            return left / right
        case _ as unreachable:
            assert_never(unreachable)


def evaluate(tokens: Sequence[Token]) -> Decimal | EvalError:
    stack: list[Decimal] = []
    for token in tokens:
        match token:
            case Number(value=value):
                stack.append(value)
            case Operator(symbol=symbol):
                if len(stack) < 2:
                    return EvalError("insufficient-operands")
                right = stack.pop()
                left = stack.pop()
                result = _apply(symbol, left, right)
                if isinstance(result, EvalError):
                    return result
                stack.append(result)
            case _ as unreachable:
                assert_never(unreachable)
    if len(stack) != 1:
        return EvalError("too-many-operands")
    return stack[0]


def calc(expression: str) -> Decimal | ParseError | EvalError:
    tokens = tokenize(expression)
    if isinstance(tokens, ParseError):
        return tokens
    return evaluate(tokens)
