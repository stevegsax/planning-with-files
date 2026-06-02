"""Pure-core tests for the proxy: cost, caps, parsing, audit determinism.

No network, no key, no clock. Run:
  uv run --python 3.13 --with pytest --with hypothesis pytest proxy/tests/test_core.py -q
"""

from __future__ import annotations

import json
from decimal import Decimal

from hypothesis import given
from hypothesis import strategies as st
from proxy import core


def test_cost_of_uses_per_million_pricing() -> None:
    price = core.ModelPrice(Decimal("3"), Decimal("15"), Decimal("3.75"), Decimal("0.30"))
    usage = core.Usage(input_tokens=1000, output_tokens=500, cache_read_input_tokens=200)
    # (1000*3 + 500*15 + 0 + 200*0.30) / 1e6
    assert core.cost_of(usage, price) == Decimal("10560") / Decimal("1000000")


def test_apply_usage_is_pure_and_accumulates() -> None:
    price = core.price_for("claude-sonnet-4-6")
    led0 = core.Ledger()
    u = core.Usage(input_tokens=100, output_tokens=10)
    led1 = core.apply_usage(led0, u, price)
    led2 = core.apply_usage(led1, u, price)
    assert led0 == core.Ledger()  # original untouched
    assert led2.requests == 2
    assert led2.total_cost == core.cost_of(u, price) * 2
    assert led2.total_input_tokens == 200


def test_price_for_prefix_match_and_default() -> None:
    assert core.price_for("claude-sonnet-4-6-20251022") == core.PRICES["claude-sonnet-4-6"]
    assert core.price_for("some-unknown-model") == core.DEFAULT_PRICE


def test_check_caps_boundary_is_inclusive_deny() -> None:
    caps = core.Caps(max_cost_usd=Decimal("1.00"))
    under = core.Ledger(total_cost=Decimal("0.99"))
    at = core.Ledger(total_cost=Decimal("1.00"))
    assert isinstance(core.check_caps(under, caps), core.Allow)
    assert isinstance(core.check_caps(at, caps), core.Deny)  # >= cap denies


def test_check_caps_request_limit() -> None:
    caps = core.Caps(max_requests=3)
    assert isinstance(core.check_caps(core.Ledger(requests=2), caps), core.Allow)
    assert isinstance(core.check_caps(core.Ledger(requests=3), caps), core.Deny)


def test_parse_usage_handles_nested_and_garbage() -> None:
    # message_start shape: usage under .message.usage
    start = {"type": "message_start", "message": {"usage": {"input_tokens": 5, "output_tokens": 1}}}
    assert core.parse_usage(start) == core.Usage(input_tokens=5, output_tokens=1)
    # message_delta shape: usage at top level
    delta = {"type": "message_delta", "usage": {"output_tokens": 9}}
    assert core.parse_usage(delta) == core.Usage(output_tokens=9)
    # garbage never raises
    assert core.parse_usage("not a dict") == core.Usage()
    garbage = {"usage": {"input_tokens": "oops", "output_tokens": -4}}
    assert core.parse_usage(garbage) == core.Usage()


def test_audit_line_is_deterministic_and_keyless() -> None:
    u = core.Usage(input_tokens=10, output_tokens=2)
    ts, model, cost = "2026-06-02T00:00:00Z", "claude-sonnet-4-6", Decimal("0.5")
    line = core.audit_line(ts, model, u, cost, "allow")
    assert line == core.audit_line(ts, model, u, cost, "allow")
    obj = json.loads(line)
    assert obj["cost_usd"] == "0.5"  # Decimal serialized as str
    assert obj["outcome"] == "allow"
    assert "key" not in line and "x-api-key" not in line


def test_ledger_roundtrip_and_corruption_resets() -> None:
    led = core.Ledger(total_cost=Decimal("1.2345"), total_input_tokens=7, requests=3)
    assert core.ledger_from_json(core.ledger_to_json(led)) == led
    assert core.ledger_from_json("{ not json") == core.Ledger()
    assert core.ledger_from_json("[]") == core.Ledger()


@given(
    inp=st.integers(min_value=0, max_value=10_000_000),
    out=st.integers(min_value=0, max_value=10_000_000),
    n=st.integers(min_value=1, max_value=50),
)
def test_cost_conservation_property(inp: int, out: int, n: int) -> None:
    """N identical requests cost exactly N times one request (no rounding drift)."""
    price = core.price_for("claude-opus-4-8")
    u = core.Usage(input_tokens=inp, output_tokens=out)
    led = core.Ledger()
    for _ in range(n):
        led = core.apply_usage(led, u, price)
    assert led.total_cost == core.cost_of(u, price) * n
    assert led.requests == n
