"""Imperative shell for the LLM brokering proxy.

A minimal loopback reverse proxy: the agent's ``claude -p`` points
``ANTHROPIC_BASE_URL`` at this process with a dummy token, and the real Anthropic
key — owned by the ``proxy`` user, delivered out of band via systemd
``LoadCredential`` — is injected here and never handed to the agent. This is also
the only place a hard cost cap + kill switch + per-request audit can be enforced,
since the agent cannot be trusted to cap itself.

All pure decisions (cost, caps, audit serialization) live in ``core.py``; this file
owns only the effects: the socket, the key, the ledger file, the audit file, the
sentinels, and the streaming passthrough (bytes are forwarded UNCHANGED; a passive
tee extracts ``usage`` for accounting).

Run:  python -m proxy.app   (or uvicorn proxy.app:app)
"""

from __future__ import annotations

import asyncio
import json
import os
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass
from datetime import UTC, datetime
from decimal import Decimal
from pathlib import Path

import httpx
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, Response, StreamingResponse
from starlette.routing import Route

from . import core

# Request headers we must never forward upstream: inbound auth (replaced with the
# real key) and hop-by-hop / length headers httpx recomputes.
_DROP_REQUEST_HEADERS = frozenset(
    {"authorization", "x-api-key", "host", "content-length", "connection", "accept-encoding"}
)
# Response headers we must not copy back (httpx/uvicorn manage framing).
_DROP_RESPONSE_HEADERS = frozenset(
    {"content-length", "content-encoding", "transfer-encoding", "connection"}
)


@dataclass(frozen=True, slots=True)
class Config:
    upstream: str
    api_key: str
    audit_path: Path
    ledger_path: Path
    sentinel_path: Path
    kill_path: Path
    caps: core.Caps


def _read_key() -> str:
    """The real upstream key: systemd credential first, then a file, then env (tests)."""
    cred_dir = os.environ.get("CREDENTIALS_DIRECTORY")
    name = os.environ.get("PWFG_PROXY_KEY_NAME", "anthropic_key")
    if cred_dir and (Path(cred_dir) / name).is_file():
        return (Path(cred_dir) / name).read_text().strip()
    key_file = os.environ.get("PWFG_PROXY_KEY_FILE")
    if key_file and Path(key_file).is_file():
        return Path(key_file).read_text().strip()
    return os.environ.get("PWFG_PROXY_KEY", "").strip()


def config_from_env() -> Config:
    state = Path(os.environ.get("PWFG_PROXY_STATE", "/srv/pwfg/proxy"))
    control = Path(os.environ.get("PWFG_CONTROL_DIR", "/srv/pwfg/control"))
    max_cost = os.environ.get("PWFG_PROXY_MAX_COST_USD")
    max_reqs = os.environ.get("PWFG_PROXY_MAX_REQUESTS")
    return Config(
        upstream=os.environ.get("PWFG_PROXY_UPSTREAM", "https://api.anthropic.com").rstrip("/"),
        api_key=_read_key(),
        audit_path=state / "audit.jsonl",
        ledger_path=state / "ledger.json",
        sentinel_path=state / "PROXY_BUDGET_EXHAUSTED",
        kill_path=control / "KILL",
        caps=core.Caps(
            max_cost_usd=Decimal(max_cost) if max_cost else None,
            max_requests=int(max_reqs) if max_reqs else None,
        ),
    )


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _model_of(body: bytes) -> str:
    try:
        obj = json.loads(body)
    except (json.JSONDecodeError, ValueError):
        return "unknown"
    return obj.get("model", "unknown") if isinstance(obj, dict) else "unknown"


def _usage_from_stream(buf: bytes) -> core.Usage:
    """Sum usage across a buffered response: SSE ``data:`` events or a plain JSON body.

    ``message_start`` carries input/cache tokens; ``message_delta`` carries the final
    ``output_tokens``. We take the max per field across events so partial deltas never
    under-count. Non-SSE JSON (e.g. a non-streamed message) is parsed whole.
    """
    text = buf.decode("utf-8", errors="replace")
    acc = core.Usage()
    saw_event = False
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("data:"):
            continue
        payload = line[len("data:"):].strip()
        if not payload or payload == "[DONE]":
            continue
        try:
            obj = json.loads(payload)
        except (json.JSONDecodeError, ValueError):
            continue
        saw_event = True
        u = core.parse_usage(obj)
        acc = core.Usage(
            input_tokens=max(acc.input_tokens, u.input_tokens),
            output_tokens=max(acc.output_tokens, u.output_tokens),
            cache_creation_input_tokens=max(
                acc.cache_creation_input_tokens, u.cache_creation_input_tokens
            ),
            cache_read_input_tokens=max(
                acc.cache_read_input_tokens, u.cache_read_input_tokens
            ),
        )
    if saw_event:
        return acc
    try:
        return core.parse_usage(json.loads(text))
    except (json.JSONDecodeError, ValueError):
        return core.Usage()


class Broker:
    """Holds the live ledger + client and serializes ledger/audit mutations."""

    def __init__(self, cfg: Config) -> None:
        self._cfg = cfg
        self._lock = asyncio.Lock()
        self._client = httpx.AsyncClient(timeout=httpx.Timeout(600.0, connect=10.0))
        self._ledger = (
            core.ledger_from_json(cfg.ledger_path.read_text())
            if cfg.ledger_path.is_file()
            else core.Ledger()
        )

    async def aclose(self) -> None:
        await self._client.aclose()

    def _deny_response(self, reason: str, status: int) -> JSONResponse:
        return JSONResponse(
            {"type": "error", "error": {"type": "permission_error", "message": reason}},
            status_code=status,
        )

    async def _record(self, model: str, usage: core.Usage, outcome: str) -> None:
        price = core.price_for(model)
        cost = core.cost_of(usage, price)
        async with self._lock:
            self._ledger = core.apply_usage(self._ledger, usage, price)
            self._cfg.audit_path.parent.mkdir(parents=True, exist_ok=True)
            with self._cfg.audit_path.open("a") as fh:
                fh.write(core.audit_line(_now(), model, usage, cost, outcome) + "\n")
            tmp = self._cfg.ledger_path.with_suffix(".tmp")
            tmp.write_text(core.ledger_to_json(self._ledger))
            tmp.replace(self._cfg.ledger_path)

    async def handle(self, request: Request) -> Response:
        cfg = self._cfg
        body = await request.body()
        model = _model_of(body)

        # Pre-flight gate, against spend already incurred + the kill switch.
        if cfg.kill_path.exists():
            await self._record(model, core.Usage(), "deny:kill-switch")
            return self._deny_response("proxy kill switch engaged", 403)
        decision = core.check_caps(self._ledger, cfg.caps)
        if isinstance(decision, core.Deny):
            cfg.sentinel_path.parent.mkdir(parents=True, exist_ok=True)
            cfg.sentinel_path.write_text(decision.reason + "\n")
            await self._record(model, core.Usage(), "deny:cap")
            return self._deny_response(decision.reason, decision.status)

        # Build the upstream request: strip inbound auth, inject the real key.
        out_headers = {
            k: v for k, v in request.headers.items() if k.lower() not in _DROP_REQUEST_HEADERS
        }
        out_headers["x-api-key"] = cfg.api_key
        url = cfg.upstream + request.url.path
        if request.url.query:
            url += "?" + request.url.query

        upstream_req = self._client.build_request(
            request.method, url, headers=out_headers, content=body
        )
        upstream = await self._client.send(upstream_req, stream=True)

        resp_headers = {
            k: v
            for k, v in upstream.headers.items()
            if k.lower() not in _DROP_RESPONSE_HEADERS
        }

        async def stream() -> AsyncIterator[bytes]:
            chunks: list[bytes] = []
            try:
                async for chunk in upstream.aiter_raw():
                    chunks.append(chunk)
                    yield chunk  # byte-exact passthrough
            finally:
                await upstream.aclose()
                usage = _usage_from_stream(b"".join(chunks))
                await self._record(model, usage, "allow")

        return StreamingResponse(
            stream(),
            status_code=upstream.status_code,
            headers=resp_headers,
            media_type=upstream.headers.get("content-type"),
        )


def create_app(cfg: Config | None = None) -> Starlette:
    cfg = cfg or config_from_env()
    broker = Broker(cfg)

    async def catch_all(request: Request) -> Response:
        return await broker.handle(request)

    @asynccontextmanager
    async def lifespan(_app: Starlette) -> AsyncIterator[None]:
        yield
        await broker.aclose()

    methods = ["GET", "POST", "PUT", "DELETE", "PATCH"]
    return Starlette(
        routes=[Route("/{path:path}", catch_all, methods=methods)],
        lifespan=lifespan,
    )


# Module-level app for `uvicorn proxy.app:app` (systemd sets the env first). The
# test path uses main() instead and sets PWFG_PROXY_AUTOSTART=0 to skip this.
_autostart = os.environ.get("PWFG_PROXY_AUTOSTART", "1") == "1"
app: Starlette | None = create_app() if _autostart else None


def main() -> None:
    import uvicorn

    uvicorn.run(
        create_app(),
        host=os.environ.get("PWFG_PROXY_HOST", "127.0.0.1"),
        port=int(os.environ.get("PWFG_PROXY_PORT", "8787")),
        log_level="warning",
    )


if __name__ == "__main__":
    main()
