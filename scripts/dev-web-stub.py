#!/usr/bin/env python3
"""Development stand-in for skipperdesk.app and api.skipperdesk.app.

TEMPORARY. This exists only until the real backend lands in Phase 5
(docs/SCOPE.md §11) and is deleted then. It implements the account-link half of
protocol/API.md — §1.2 link, §1.3 challenge, §1.4 token, §1.5 refresh, §1.6
revoke, §3.4 device read and §4.1 entitlement — in memory, with the exact
response shapes and the §0.3 error envelope, plus the `/link` page the app opens
in the browser. Python 3 standard library only, no dependencies.

What it deliberately does NOT do, and what the real backend must: verify the
ECDSA P-256 signature over the raw challenge nonce (§1.1 rule 4), sign in a real
user through Cognito, hash `hardwareId` with a server salt (§3.2), enforce the
§8 rate limits, and serve TLS.

    python3 scripts/dev-web-stub.py            # http://127.0.0.1:18080
"""

import base64
import json
import os
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HOST = os.environ.get("SKIPPER_STUB_HOST", "127.0.0.1")
PORT = int(os.environ.get("SKIPPER_STUB_PORT", "18080"))

CODE_LIFETIME_SEC = 120
NONCE_LIFETIME_SEC = 60
TOKEN_TTL_SEC = 90 * 24 * 60 * 60

STATE_LOCK = threading.Lock()
PENDING_LINKS = {}
CODES = {}
NONCES = {}
DEVICES = {}
TOKENS = {}
IDEMPOTENCY = {}

ACCOUNT_ID = "acct_dev_stub"
ACCOUNT_LABEL = "dev@skipperdesk.local"


def now_ms():
    return int(time.time() * 1000)


def new_device_id():
    return "".join(secrets.choice("0123456789") for _ in range(9))


def request_id():
    return secrets.token_hex(8).upper()


LINK_PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>Link this Mac &middot; SkipperDesk (dev stub)</title>
<style>
 body {{ font: 15px -apple-system, sans-serif; margin: 12vh auto; max-width: 30rem; color: #111; }}
 code {{ font-size: 12px; color: #555; word-break: break-all; }}
 button {{ font-size: 16px; padding: .6rem 1.2rem; }}
 p.note {{ color: #777; font-size: 13px; }}
</style></head>
<body>
<h1>Link this Mac</h1>
<p>Development stub standing in for the SkipperDesk website. There is no real
sign-in here; pressing the button issues a one-time code and hands it back to
the app over <code>skipperdesk://link</code>.</p>
<p><code>device={device}</code></p>
<p><button onclick="location.href='skipperdesk://link?code={code}'">Sign in and link</button></p>
<p class="note">The code is valid for {lifetime} seconds and can be used once.</p>
</body></html>
"""


class Handler(BaseHTTPRequestHandler):

    server_version = "SkipperDeskDevStub/0"

    def log_message(self, fmt, *args):
        print("[stub] %s - %s" % (self.address_string(), fmt % args), flush=True)

    # ---- plumbing ----------------------------------------------------------

    def send_json(self, status, payload, extra_headers=None):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Request-Id", self.request_id)
        for key, value in (extra_headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def send_error_envelope(self, status, code, message, reason=None, retry_after=None):
        error = {"code": code, "message": message, "requestId": self.request_id}
        if reason is not None:
            error["reason"] = reason
        if retry_after is not None:
            error["retryAfterSec"] = retry_after
        self.send_json(status, {"error": error})

    def send_html(self, status, html):
        body = html.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Request-Id", self.request_id)
        self.end_headers()
        self.wfile.write(body)

    def read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length > 64 * 1024:
            return None
        raw = self.rfile.read(length) if length else b""
        if not raw:
            return {}
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except ValueError:
            return None
        return parsed if isinstance(parsed, dict) else None

    def bearer(self):
        header = self.headers.get("Authorization") or ""
        if not header.startswith("Bearer "):
            return None
        return header[len("Bearer "):]

    # ---- routing -----------------------------------------------------------

    def do_GET(self):
        self.request_id = request_id()
        route = urlparse(self.path)
        if route.path == "/link":
            return self.link_page(parse_qs(route.query))
        if route.path == "/v1/health":
            return self.send_json(200, {"status": "ok", "serverTime": now_ms()})
        if route.path == "/healthz":
            return self.send_json(200, {"status": "ok", "serverTime": now_ms()})
        if route.path == "/v1/entitlement":
            return self.entitlement()
        if route.path.startswith("/v1/devices/"):
            return self.device(route.path[len("/v1/devices/"):])
        self.send_error_envelope(404, "not_found", "no such path")

    def do_POST(self):
        self.request_id = request_id()
        route = urlparse(self.path)
        body = self.read_json()
        if body is None:
            return self.send_error_envelope(400, "bad_request", "the body is not a JSON object")

        idempotent_paths = (
            "/v1/auth/link",
            "/v1/auth/device/token",
            "/v1/auth/device/refresh",
            "/v1/auth/device/revoke",
        )
        if route.path in idempotent_paths:
            key = self.headers.get("Idempotency-Key")
            if not key or not (16 <= len(key) <= 64):
                return self.send_error_envelope(
                    400, "bad_request", "this endpoint requires an Idempotency-Key of 16-64 characters")
            fingerprint = json.dumps(body, sort_keys=True)
            with STATE_LOCK:
                stored = IDEMPOTENCY.get((route.path, key))
            if stored is not None:
                if stored["body"] != fingerprint:
                    return self.send_error_envelope(
                        409, "idempotency_conflict", "this key was used with a different body",
                        reason="body_mismatch")
                return self.send_json(
                    stored["status"], stored["payload"], {"Idempotency-Replayed": "true"})
            self.idempotency_slot = (route.path, key, fingerprint)
        else:
            self.idempotency_slot = None

        if route.path == "/v1/auth/link":
            return self.auth_link(body)
        if route.path == "/v1/auth/device/challenge":
            return self.auth_challenge(body)
        if route.path == "/v1/auth/device/token":
            return self.auth_token(body)
        if route.path == "/v1/auth/device/refresh":
            return self.auth_refresh(body)
        if route.path == "/v1/auth/device/revoke":
            return self.auth_revoke()
        self.send_error_envelope(404, "not_found", "no such path")

    def send_idempotent(self, status, payload):
        slot = getattr(self, "idempotency_slot", None)
        if slot is not None:
            path, key, fingerprint = slot
            with STATE_LOCK:
                IDEMPOTENCY[(path, key)] = {
                    "body": fingerprint, "status": status, "payload": payload}
        self.send_json(status, payload)

    # ---- the website's half ------------------------------------------------

    def link_page(self, query):
        """The page the app opens (API.md §1.1 step 1).

        A real website signs the user in with Cognito and then calls §1.2 with
        its user-session credential. The stub does the §1.2 call for itself, so
        the browser hop is real while the sign-in is not.
        """
        nonce = (query.get("nonce") or [""])[0]
        pubkey = (query.get("device") or [""])[0]
        if not nonce or not pubkey:
            return self.send_html(400, "<h1>Missing nonce or device</h1>")
        code = self.mint_code(nonce=nonce, pubkey=pubkey, platform="macos", label=None)["code"]
        self.send_html(200, LINK_PAGE.format(
            device=pubkey[:24] + "…", code=code, lifetime=CODE_LIFETIME_SEC))

    def mint_code(self, nonce, pubkey, platform, label):
        code = secrets.token_urlsafe(24)
        expires = now_ms() + CODE_LIFETIME_SEC * 1000
        with STATE_LOCK:
            PENDING_LINKS[nonce] = code
            CODES[code] = {
                "nonce": nonce, "pubkey": pubkey, "platform": platform,
                "label": label, "expiresAt": expires, "used": False,
            }
            existing = next(
                (device_id for device_id, record in DEVICES.items() if record["pubkey"] == pubkey), None)
        answer = {"code": code, "expiresAt": expires}
        if existing:
            answer["deviceId"] = existing
        return answer

    # ---- §1.2 --------------------------------------------------------------

    def auth_link(self, body):
        for field in ("nonce", "pubkey", "platform"):
            if not isinstance(body.get(field), str) or not body[field]:
                return self.send_error_envelope(400, "bad_request", "missing or malformed '%s'" % field)
        unknown = set(body) - {"nonce", "pubkey", "platform", "label"}
        if unknown:
            return self.send_error_envelope(400, "bad_request", "unknown members: %s" % ", ".join(sorted(unknown)))
        answer = self.mint_code(
            nonce=body["nonce"], pubkey=body["pubkey"],
            platform=body["platform"], label=body.get("label"))
        self.send_idempotent(201, answer)

    # ---- §1.3 --------------------------------------------------------------

    def auth_challenge(self, body):
        unknown = set(body) - {"code", "deviceId"}
        if unknown:
            return self.send_error_envelope(400, "bad_request", "unknown members: %s" % ", ".join(sorted(unknown)))
        if ("code" in body) == ("deviceId" in body):
            return self.send_error_envelope(400, "bad_request", "send exactly one of 'code' or 'deviceId'")

        nonce = base64.b64encode(secrets.token_bytes(32)).decode("ascii")
        expires = now_ms() + NONCE_LIFETIME_SEC * 1000
        with STATE_LOCK:
            NONCES[nonce] = {
                "code": body.get("code"), "deviceId": body.get("deviceId"),
                "expiresAt": expires, "used": False,
            }
        self.send_json(200, {"nonce": nonce, "serverTime": now_ms(), "expiresAt": expires})

    def consume_nonce(self, nonce):
        with STATE_LOCK:
            entry = NONCES.get(nonce)
            if entry is None or entry["used"] or entry["expiresAt"] < now_ms():
                return None
            entry["used"] = True
            return entry

    # ---- §1.4 --------------------------------------------------------------

    def auth_token(self, body):
        required = ("code", "pubkey", "sig", "platform", "hardwareId")
        for field in required:
            if not isinstance(body.get(field), str) or not body[field]:
                return self.send_error_envelope(400, "bad_request", "missing or malformed '%s'" % field)
        unknown = set(body) - set(required) - {"label"}
        if unknown:
            return self.send_error_envelope(400, "bad_request", "unknown members: %s" % ", ".join(sorted(unknown)))

        with STATE_LOCK:
            pending = CODES.get(body["code"])
        if pending is None or pending["used"] or pending["expiresAt"] < now_ms():
            return self.send_error_envelope(401, "unauthenticated", "that sign-in code is not usable")
        if pending["pubkey"] != body["pubkey"]:
            return self.send_error_envelope(
                403, "forbidden", "that code was issued for a different device key")
        try:
            base64.b64decode(body["sig"], validate=True)
        except Exception:
            return self.send_error_envelope(400, "bad_request", "'sig' is not base64")

        with STATE_LOCK:
            pending["used"] = True
            device_id = next(
                (existing for existing, record in DEVICES.items()
                 if record["pubkey"] == body["pubkey"]), None) or new_device_id()
            record = DEVICES.get(device_id) or {
                "deviceId": device_id,
                "pubkey": body["pubkey"],
                "createdAt": now_ms(),
                "trialEndsAt": now_ms() + 14 * 24 * 60 * 60 * 1000,
            }
            record.update({
                "label": body.get("label") or pending["label"] or "Mac",
                "platform": body["platform"],
                "linkedAt": now_ms(),
                "lastSeen": now_ms(),
                "unlinked": False,
            })
            DEVICES[device_id] = record
        self.send_idempotent(200, self.issue_token(device_id))

    def issue_token(self, device_id):
        token = secrets.token_urlsafe(32)
        expires = now_ms() + TOKEN_TTL_SEC * 1000
        with STATE_LOCK:
            TOKENS[token] = {"deviceId": device_id, "expiresAt": expires, "revoked": False}
        return {
            "deviceToken": token,
            "expiresAt": expires,
            "ttlSec": TOKEN_TTL_SEC,
            "deviceId": device_id,
            "accountId": ACCOUNT_ID,
        }

    # ---- §1.5 --------------------------------------------------------------

    def auth_refresh(self, body):
        for field in ("deviceId", "pubkey", "sig"):
            if not isinstance(body.get(field), str) or not body[field]:
                return self.send_error_envelope(400, "bad_request", "missing or malformed '%s'" % field)
        unknown = set(body) - {"deviceId", "pubkey", "sig"}
        if unknown:
            return self.send_error_envelope(400, "bad_request", "unknown members: %s" % ", ".join(sorted(unknown)))

        with STATE_LOCK:
            record = DEVICES.get(body["deviceId"])
        if record is None or record["pubkey"] != body["pubkey"]:
            return self.send_error_envelope(403, "forbidden", "that device is not linked", reason="unlinked")
        if record.get("unlinked"):
            return self.send_error_envelope(403, "forbidden", "that device was unlinked", reason="unlinked")
        self.send_idempotent(200, self.issue_token(body["deviceId"]))

    # ---- §1.6 --------------------------------------------------------------

    def auth_revoke(self):
        token = self.bearer()
        with STATE_LOCK:
            entry = TOKENS.get(token or "")
            if entry is None or entry["revoked"]:
                return self.send_error_envelope(401, "unauthenticated", "no such device token")
            entry["revoked"] = True
        self.send_response(204)
        self.send_header("X-Request-Id", self.request_id)
        self.end_headers()

    # ---- §3.4, §4.1 --------------------------------------------------------

    def authenticated_device(self):
        token = self.bearer()
        with STATE_LOCK:
            entry = TOKENS.get(token or "")
            if entry is None or entry["revoked"] or entry["expiresAt"] < now_ms():
                return None
            record = DEVICES.get(entry["deviceId"])
            if record is None or record.get("unlinked"):
                return None
            record["lastSeen"] = now_ms()
            return dict(record)

    def device(self, device_id):
        record = self.authenticated_device()
        if record is None:
            return self.send_error_envelope(401, "unauthenticated", "a device token is required")
        if record["deviceId"] != device_id:
            return self.send_error_envelope(
                403, "forbidden", "a device token may read only its own record")
        self.send_json(200, {
            "deviceId": record["deviceId"],
            "label": record["label"],
            "platform": record["platform"],
            "pubkey": record["pubkey"],
            "createdAt": record["createdAt"],
            "linkedAt": record["linkedAt"],
            "lastSeen": record["lastSeen"],
            "trialEndsAt": record["trialEndsAt"],
        })

    def entitlement(self):
        record = self.authenticated_device()
        if record is None:
            return self.send_error_envelope(401, "unauthenticated", "a device token is required")
        self.send_json(200, {
            "status": "trial",
            "tier": "base",
            "trialEndsAt": record["trialEndsAt"],
            "concurrency": {"maxActivePairs": 1},
            "refreshAfterSec": 60,
        })


def main():
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print("[stub] serving the API.md §1 account surface on http://%s:%d" % (HOST, PORT), flush=True)
    print("[stub] run the app with SKIPPER_API_BASE_URL=http://%s:%d" % (HOST, PORT), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
