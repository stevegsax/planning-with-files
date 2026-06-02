#!/usr/bin/env python3
"""A recording fake Anthropic upstream for the proxy's deterministic tests.

Stdlib only (no key, no network). Records the headers it RECEIVES to
``PWFG_FAKE_HEADERS`` (one JSON object) so the test can assert the proxy injected
the real key and stripped the inbound auth; returns a fixed SSE body so the test can
assert byte-exact passthrough and usage accounting.

Env: PWFG_FAKE_PORT, PWFG_FAKE_HEADERS
"""

from __future__ import annotations

import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

# A canonical Anthropic-style streaming body: usage is split across message_start
# (input + cache) and message_delta (final output_tokens).
SSE_BODY = (
    b'event: message_start\n'
    b'data: {"type":"message_start","message":{"id":"msg_test",'
    b'"usage":{"input_tokens":1000,"cache_read_input_tokens":200,"output_tokens":1}}}\n\n'
    b'event: content_block_delta\n'
    b'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}\n\n'
    b'event: message_delta\n'
    b'data: {"type":"message_delta","usage":{"output_tokens":500}}\n\n'
    b'event: message_stop\n'
    b'data: {"type":"message_stop"}\n\n'
)


class Handler(BaseHTTPRequestHandler):
    def _record(self) -> None:
        path = os.environ.get("PWFG_FAKE_HEADERS")
        if path:
            with open(path, "w") as fh:
                json.dump({k.lower(): v for k, v in self.headers.items()}, fh)

    def _serve(self) -> None:
        length = int(self.headers.get("content-length", "0") or "0")
        if length:
            self.rfile.read(length)
        self._record()
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("content-length", str(len(SSE_BODY)))
        self.end_headers()
        self.wfile.write(SSE_BODY)

    def do_POST(self) -> None:  # noqa: N802
        self._serve()

    def do_GET(self) -> None:  # noqa: N802
        self._serve()

    def log_message(self, *args: object) -> None:  # silence
        pass


def main() -> None:
    import sys

    if "--dump" in sys.argv:  # emit the canonical body so tests share one source of truth
        sys.stdout.buffer.write(SSE_BODY)
        return
    port = int(os.environ.get("PWFG_FAKE_PORT", "8788"))
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
