#!/usr/bin/env python3
"""Hand the authenticator the key agreement key behind a verifier peer DID.

The authenticator derives the MSK from the content encryption key of the
presentation JWE, which it recovers by unwrapping the verifier recipient entry.
That needs the private key behind the peer DID the verifier minted for the
invitation, and Identus mints a new one per invitation and offers no way to ask
for it. So it is read out of the verifier's own store here.

This exists because the authenticator and the verifier are still two processes.
It goes away when the authenticator verifies presentations itself, which is
where the design is heading. Until then:

    THIS SERVICE HANDS OUT PRIVATE KEYS. Keep it on the verifier network,
    reachable by the authenticator and nothing else. It is a testbed
    component and has no place in a deployment.

Usage:
    verifier-key-service.py [--port 8090]

Environment:
    PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE — verifier agent database
"""

import argparse
import json
import os
import re
import subprocess
import time
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

# A did:peer:2 is method characters, base58 segments and separators. Anything
# else is not a DID we mint, and is refused rather than passed to the database.
DID_RE = re.compile(r"^did:peer:2[A-Za-z0-9._:-]{1,2048}$")

QUERY = (
    "SELECT key_pair::text FROM peer_did_rand_key "
    "WHERE did = {did} AND key_id = 'agreement';"
)

LOOKUP_ATTEMPTS = 4
LOOKUP_RETRY_DELAY = 0.5


def quote_literal(value):
    """Quote a string for SQL the way the server would."""
    return "'" + value.replace("'", "''") + "'"


def lookup(did):
    """Return the agreement JWK for a peer DID, or None when it has none."""
    env = dict(os.environ)
    env.setdefault("PGCONNECT_TIMEOUT", "5")

    result = subprocess.run(
        [
            "psql", "-t", "-A", "-q", "--no-psqlrc",
            "-v", "ON_ERROR_STOP=1",
            "-c", QUERY.format(did=quote_literal(did)),
        ],
        env=env,
        capture_output=True,
        text=True,
        timeout=15,
    )

    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "psql failed")

    row = result.stdout.strip()
    if not row:
        return None

    jwk = json.loads(row)
    if "d" not in jwk:
        raise RuntimeError("key pair carries no private component")

    return jwk


class Handler(BaseHTTPRequestHandler):
    server_version = "eap-did-verifier-keys"

    def _reply(self, status, body):
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path == "/healthz":
            self._reply(200, {"status": "ok"})
            return

        if parsed.path != "/peer-did-key":
            self._reply(404, {"error": "not found"})
            return

        did = (parse_qs(parsed.query).get("did") or [""])[0]
        if not DID_RE.match(did):
            self._reply(400, {"error": "not a did:peer:2"})
            return

        # The authenticator asks as soon as the invitation comes back, which
        # can beat the verifier's own write of the key by a moment.
        jwk = None
        for attempt in range(LOOKUP_ATTEMPTS):
            try:
                jwk = lookup(did)
            except Exception as exc:                    # noqa: BLE001
                self.log_error("lookup failed: %s", exc)
                self._reply(502, {"error": "lookup failed"})
                return
            if jwk is not None:
                break
            if attempt + 1 < LOOKUP_ATTEMPTS:
                time.sleep(LOOKUP_RETRY_DELAY)

        if jwk is None:
            self._reply(404, {"error": "no agreement key for that DID"})
            return

        self._reply(200, jwk)

    def log_message(self, fmt, *args):
        # The DID goes in the log; the key never does
        sys.stderr.write("[verifier-keys] %s\n" % (fmt % args))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8090)
    parser.add_argument("--bind", default="0.0.0.0")
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.bind, args.port), Handler)
    sys.stderr.write(
        "[verifier-keys] listening on %s:%d, database %s@%s\n"
        % (
            args.bind,
            args.port,
            os.environ.get("PGDATABASE", "?"),
            os.environ.get("PGHOST", "?"),
        )
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
