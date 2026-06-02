"""Pure core for the LLM brokering proxy (function core / imperative shell).

Everything here is a pure function over immutable, frozen-slotted values: no I/O,
no clock, no network, no global mutable state. The shell (``app.py``) owns the
socket, the real key, the audit file, and the ledger file; it calls into these
functions to decide and to serialize. Keeping the cost/cap/audit logic pure makes
it exhaustively testable without a network or a key (see ``tests/test_core.py``).

Money is always ``Decimal`` constructed from ``str`` (never from a float), and
prices are quoted per *million* tokens to match vendor price sheets.
"""

from __future__ import annotations

import json
from collections.abc import Mapping
from dataclasses import dataclass, replace
from decimal import Decimal
from typing import Final

_MILLION: Final = Decimal("1000000")


@dataclass(frozen=True, slots=True)
class Usage:
    """Token counts for one request (the units a price is applied to)."""

    input_tokens: int = 0
    output_tokens: int = 0
    cache_creation_input_tokens: int = 0
    cache_read_input_tokens: int = 0


@dataclass(frozen=True, slots=True)
class ModelPrice:
    """USD per *million* tokens, by token class."""

    input: Decimal
    output: Decimal
    cache_write: Decimal
    cache_read: Decimal


@dataclass(frozen=True, slots=True)
class Ledger:
    """Accumulated spend. Immutable: ``apply_usage`` returns a new ledger."""

    total_cost: Decimal = Decimal("0")
    total_input_tokens: int = 0
    total_output_tokens: int = 0
    requests: int = 0


@dataclass(frozen=True, slots=True)
class Caps:
    """Authoritative ceilings. ``None`` = unbounded for that dimension."""

    max_cost_usd: Decimal | None = None
    max_requests: int | None = None


@dataclass(frozen=True, slots=True)
class Allow:
    """The request may proceed upstream."""


@dataclass(frozen=True, slots=True)
class Deny:
    """The request must be refused (cap breached or kill switch)."""

    reason: str
    status: int = 403


Decision = Allow | Deny


# A small, overridable price table. Unknown models fall back to DEFAULT_PRICE so a
# new model can never silently bill at zero (which would defeat the cap).
PRICES: Final[Mapping[str, ModelPrice]] = {
    "claude-opus-4-8": ModelPrice(Decimal("15"), Decimal("75"), Decimal("18.75"), Decimal("1.50")),
    "claude-sonnet-4-6": ModelPrice(Decimal("3"), Decimal("15"), Decimal("3.75"), Decimal("0.30")),
    "claude-haiku-4-5": ModelPrice(Decimal("0.80"), Decimal("4"), Decimal("1"), Decimal("0.08")),
}
DEFAULT_PRICE: Final = ModelPrice(Decimal("15"), Decimal("75"), Decimal("18.75"), Decimal("1.50"))


def price_for(model: str) -> ModelPrice:
    """Price for ``model`` by longest known prefix, else the (expensive) default.

    Prefix match so dated suffixes (``…-20251001``) and ``-latest`` resolve. The
    default is the *most* expensive tier so an unrecognized model over-counts rather
    than under-counts against the cap — fail safe for cost control.
    """
    best: str | None = None
    for known in PRICES:
        if model.startswith(known) and (best is None or len(known) > len(best)):
            best = known
    return PRICES[best] if best is not None else DEFAULT_PRICE


def cost_of(usage: Usage, price: ModelPrice) -> Decimal:
    """Exact USD cost of one request's ``usage`` at ``price`` (per-MTok)."""
    return (
        Decimal(usage.input_tokens) * price.input
        + Decimal(usage.output_tokens) * price.output
        + Decimal(usage.cache_creation_input_tokens) * price.cache_write
        + Decimal(usage.cache_read_input_tokens) * price.cache_read
    ) / _MILLION


def apply_usage(ledger: Ledger, usage: Usage, price: ModelPrice) -> Ledger:
    """Return a NEW ledger with ``usage`` accounted for (the old one is unchanged)."""
    return replace(
        ledger,
        total_cost=ledger.total_cost + cost_of(usage, price),
        total_input_tokens=ledger.total_input_tokens + usage.input_tokens,
        total_output_tokens=ledger.total_output_tokens + usage.output_tokens,
        requests=ledger.requests + 1,
    )


def check_caps(ledger: Ledger, caps: Caps) -> Decision:
    """Allow iff the ACCUMULATED ledger is strictly under every set cap.

    Checked pre-flight against spend already incurred, so the cap is a hard ceiling:
    once reached, every subsequent request is denied before any upstream call.
    """
    if caps.max_cost_usd is not None and ledger.total_cost >= caps.max_cost_usd:
        return Deny(f"cost cap reached: {ledger.total_cost} >= {caps.max_cost_usd} USD")
    if caps.max_requests is not None and ledger.requests >= caps.max_requests:
        return Deny(f"request cap reached: {ledger.requests} >= {caps.max_requests}")
    return Allow()


def _as_int(value: object) -> int:
    """Coerce a JSON value to a non-negative int; anything odd -> 0 (never raises)."""
    if isinstance(value, bool):  # bool is an int subclass; treat as not-a-count
        return 0
    if isinstance(value, int):
        return value if value >= 0 else 0
    if isinstance(value, str):
        try:
            n = int(value)
        except ValueError:
            return 0
        return n if n >= 0 else 0
    return 0


def parse_usage(obj: object) -> Usage:
    """Extract a ``Usage`` from a decoded JSON object — failure as a value.

    Accepts the shape Anthropic puts under ``usage`` (on ``message_start`` /
    ``message_delta`` / a non-streamed message). Missing or malformed fields become
    0 rather than raising, so a surprising upstream shape degrades to "no recorded
    usage" instead of crashing the proxy mid-stream.
    """
    usage = obj
    if isinstance(obj, Mapping) and "usage" in obj:
        usage = obj["usage"]
    if isinstance(obj, Mapping) and isinstance(obj.get("message"), Mapping):
        inner = obj["message"]
        if isinstance(inner.get("usage"), Mapping):
            usage = inner["usage"]
    if not isinstance(usage, Mapping):
        return Usage()
    return Usage(
        input_tokens=_as_int(usage.get("input_tokens")),
        output_tokens=_as_int(usage.get("output_tokens")),
        cache_creation_input_tokens=_as_int(usage.get("cache_creation_input_tokens")),
        cache_read_input_tokens=_as_int(usage.get("cache_read_input_tokens")),
    )


def audit_line(ts: str, model: str, usage: Usage, cost: Decimal, outcome: str) -> str:
    """One deterministic JSON audit record (sorted keys, ``Decimal`` -> str).

    ``ts`` is supplied by the shell (UTC ``…Z``) so this stays pure. Never includes
    the key or any header value — only counts, cost, and the allow/deny outcome.
    """
    record = {
        "ts": ts,
        "model": model,
        "outcome": outcome,
        "input_tokens": usage.input_tokens,
        "output_tokens": usage.output_tokens,
        "cache_creation_input_tokens": usage.cache_creation_input_tokens,
        "cache_read_input_tokens": usage.cache_read_input_tokens,
        "cost_usd": str(cost),
    }
    return json.dumps(record, sort_keys=True, separators=(",", ":"))


def ledger_to_json(ledger: Ledger) -> str:
    """Serialize the ledger for on-disk persistence (Decimal -> str)."""
    return json.dumps(
        {
            "total_cost": str(ledger.total_cost),
            "total_input_tokens": ledger.total_input_tokens,
            "total_output_tokens": ledger.total_output_tokens,
            "requests": ledger.requests,
        },
        sort_keys=True,
    )


def ledger_from_json(text: str) -> Ledger:
    """Load a persisted ledger; any corruption resets to an empty ledger (fail safe
    toward MORE caution would mean refusing, but an empty ledger simply re-bills from
    zero and is bounded by the same cap, so it is the safe restart default)."""
    try:
        data = json.loads(text)
    except (json.JSONDecodeError, TypeError):
        return Ledger()
    if not isinstance(data, Mapping):
        return Ledger()
    try:
        return Ledger(
            total_cost=Decimal(str(data.get("total_cost", "0"))),
            total_input_tokens=_as_int(data.get("total_input_tokens")),
            total_output_tokens=_as_int(data.get("total_output_tokens")),
            requests=_as_int(data.get("requests")),
        )
    except (ValueError, ArithmeticError):
        return Ledger()
