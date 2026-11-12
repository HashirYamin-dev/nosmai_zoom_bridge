#!/usr/bin/env python3
"""Zoom Video SDK session JWTs for development, signed OFF the device.

The SDK secret stays in config/zoom_secrets.json (git-ignored) on this machine;
the app only ever receives short-lived tokens.

  python3 tools/zoom_token.py --session nosmai-live            # writes config/local.json
  python3 tools/zoom_token.py --serve --port 4000               # LAN token server

--serve speaks the contract of Zoom's videosdk-auth-endpoint-sample:
POST / {"sessionName", "role", "userIdentity"?, "expirationSeconds"?} -> {"signature"}.
Production apps should run that sample (or equivalent) behind their own auth.
"""
import argparse, base64, hashlib, hmac, json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SECRETS = ROOT / "config" / "zoom_secrets.json"
LOCAL = ROOT / "config" / "local.json"
MIN_EXP, MAX_EXP = 1800, 48 * 3600  # Zoom's accepted token lifetime window.


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def make_token(key, secret, session, role, user_identity="", lifetime=7200, now=None):
    if not session or len(session) > 200:
        raise ValueError("sessionName must be 1-200 characters")
    if role not in (0, 1):
        raise ValueError("role must be 1 (host) or 0 (participant)")
    lifetime = max(MIN_EXP, min(MAX_EXP, int(lifetime)))
    iat = int(now if now is not None else time.time()) - 30  # tolerate clock skew
    payload = {"app_key": key, "tpc": session, "role_type": role, "version": 1,
               "iat": iat, "exp": iat + lifetime}
    if user_identity:
        payload["user_identity"] = user_identity[:35]
    header = {"alg": "HS256", "typ": "JWT"}
    signing = b64url(json.dumps(header, separators=(",", ":")).encode()) + "." + \
        b64url(json.dumps(payload, separators=(",", ":")).encode())
    sig = hmac.new(secret.encode(), signing.encode(), hashlib.sha256).digest()
    return signing + "." + b64url(sig)


def load_secrets():
    if not SECRETS.exists():
        sys.exit(f"Missing {SECRETS.relative_to(ROOT)}; copy config/zoom_secrets.example.json and fill it.")
    data = json.loads(SECRETS.read_text())
    key, secret = data.get("ZOOM_SDK_KEY", "").strip(), data.get("ZOOM_SDK_SECRET", "").strip()
    if not key or not secret or "PASTE" in key + secret:
        sys.exit("ZOOM_SDK_KEY / ZOOM_SDK_SECRET are not set in config/zoom_secrets.json")
    return key, secret


def write_local(session, lifetime):
    key, secret = load_secrets()
    local = json.loads(LOCAL.read_text()) if LOCAL.exists() else {}
    local["ZOOM_SESSION_NAME"] = session
    local["ZOOM_HOST_TOKEN"] = make_token(key, secret, session, 1, "host", lifetime)
    local["ZOOM_VIEWER_TOKEN"] = make_token(key, secret, session, 0, "", lifetime)
    local.setdefault("NOSMAI_LICENSE_KEY", "")
    LOCAL.write_text(json.dumps(local, indent=2) + "\n")
    print(f"Wrote {LOCAL.relative_to(ROOT)} (session '{session}', valid {lifetime // 60} min).")
    if not local["NOSMAI_LICENSE_KEY"]:
        print("NOSMAI_LICENSE_KEY is empty in config/local.json: hosting will fail until it is set.")


def serve(port):
    key, secret = load_secrets()

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            try:
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
                token = make_token(key, secret, str(body.get("sessionName", "")), int(body.get("role", -1)),
                                   str(body.get("userIdentity", "")), body.get("expirationSeconds", 7200))
                self._reply(200, {"signature": token})
            except (ValueError, TypeError, json.JSONDecodeError) as e:
                self._reply(400, {"errors": [str(e)]})

        def _reply(self, code, obj):
            data = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    print(f"Dev token server on 0.0.0.0:{port} (LAN only; no auth - do not expose publicly).")
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--session", default="nosmai-live")
    p.add_argument("--lifetime", type=int, default=7200, help="seconds (1800-172800)")
    p.add_argument("--serve", action="store_true")
    p.add_argument("--port", type=int, default=4000)
    a = p.parse_args()
    serve(a.port) if a.serve else write_local(a.session, a.lifetime)
