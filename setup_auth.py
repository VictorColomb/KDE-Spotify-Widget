#!/usr/bin/env python3
"""
Spotify OAuth2 PKCE setup script for KDE Spotify Widget.
Uses only Python 3 stdlib — no pip installs needed.

Prerequisites:
  1. Create a Spotify app at https://developer.spotify.com/dashboard
  2. Add "http://127.0.0.1:8888/callback" as a Redirect URI in app settings
  3. Note down your Client ID and Client Secret

Usage:
  python3 setup_auth.py
  python3 setup_auth.py --selftest    # run the callback-parsing asserts

The script opens a browser, handles the OAuth callback, and stores the
client secret and refresh token in KWallet. Only the Client ID — which is
not a secret — gets pasted into the widget's Configure dialog.

Note on the client secret: it is deliberately used. Spotify rotates refresh
tokens on every renewal under pure PKCE, which would force the widget to
write back to KWallet on a schedule. QML can only reach kwallet-query
through a shell, and writing there would expose the token in the process
list. Authenticating with the secret keeps the refresh token stable, so the
widget only ever reads. Both values live in KWallet, never on disk in plain
text.
"""

import hashlib
import base64
import secrets
import json
import shutil
import subprocess
import urllib.parse
import urllib.request
import webbrowser
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from threading import Thread

REDIRECT_URI = "http://127.0.0.1:8888/callback"
AUTH_URL     = "https://accounts.spotify.com/authorize"
TOKEN_URL    = "https://accounts.spotify.com/api/token"
WALLET       = "kdewallet"
WALLET_FOLDER = "Spotify Widget"
SCOPES       = (
    "user-read-currently-playing "
    "user-read-playback-state "
    "user-modify-playback-state"
)

_callback_result = {"code": None, "error": None}
_expected_state = None


def _parse_callback(query, expected_state):
    """Return (code, error) for an OAuth callback query string.

    The state check is what stops a local process or a web page you happen to
    be visiting from feeding its own authorization code to our listener.
    """
    params = urllib.parse.parse_qs(query)
    state = params.get("state", [None])[0]

    if state != expected_state:
        return None, "state mismatch — callback rejected (possible CSRF, or a stray request)"
    if "error" in params:
        return None, params["error"][0]
    if "code" in params:
        return params["code"][0], None
    return None, "callback had neither code nor error"


class _CallbackHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        code, error = _parse_callback(parsed.query, _expected_state)

        _callback_result["code"]  = code
        _callback_result["error"] = error

        if code:
            body = b"<html><body><h2>Authorization successful!</h2><p>You can close this tab.</p></body></html>"
        else:
            body = b"<html><body><h2>Authorization failed.</h2><p>Check the terminal for details.</p></body></html>"

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass  # suppress access log noise


def _wallet_read(key):
    """Return the stored value, or None. kwallet-query reports failure only
    through its exit code — it prints error text on stdout, not stderr."""
    proc = subprocess.run(
        ["kwallet-query", "-f", WALLET_FOLDER, "-r", key, WALLET],
        capture_output=True,
    )
    if proc.returncode != 0:
        return None
    return proc.stdout.decode().strip()


def _wallet_write(key, value):
    """Store value under key, then read it back to prove it landed."""
    proc = subprocess.run(
        ["kwallet-query", "-f", WALLET_FOLDER, "-w", key, WALLET],
        input=value.encode(),          # via stdin: never appears in the process list
        capture_output=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"kwallet-query failed writing '{key}' (exit {proc.returncode}): "
            f"{proc.stdout.decode().strip()} {proc.stderr.decode().strip()}".strip()
        )
    if _wallet_read(key) != value:
        raise RuntimeError(f"wrote '{key}' to KWallet but read back a different value")


def _pkce_pair():
    verifier  = base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode()
    digest    = hashlib.sha256(verifier.encode()).digest()
    challenge = base64.urlsafe_b64encode(digest).rstrip(b"=").decode()
    return verifier, challenge


def _build_auth_url(client_id, state, code_challenge):
    params = {
        "client_id":             client_id,
        "response_type":         "code",
        "redirect_uri":          REDIRECT_URI,
        "scope":                 SCOPES,
        "state":                 state,
        "code_challenge_method": "S256",
        "code_challenge":        code_challenge,
    }
    return AUTH_URL + "?" + urllib.parse.urlencode(params)


def _exchange_code(client_id, client_secret, code, code_verifier):
    data = urllib.parse.urlencode({
        "grant_type":    "authorization_code",
        "code":          code,
        "redirect_uri":  REDIRECT_URI,
        "client_id":     client_id,
        "code_verifier": code_verifier,
    }).encode()

    credentials = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
    req = urllib.request.Request(
        TOKEN_URL,
        data=data,
        headers={
            "Content-Type":  "application/x-www-form-urlencoded",
            "Authorization": f"Basic {credentials}",
        },
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read().decode())


def main():
    print("=" * 60)
    print("  KDE Spotify Widget — One-Time Authorization Setup")
    print("=" * 60)
    print()
    print("Before running this script, make sure you have added:")
    print(f"  {REDIRECT_URI}")
    print("as a Redirect URI in your Spotify Developer Dashboard app.")
    print()

    # Fail before sending the user through a browser dance we can't store the
    # result of. No fallback to a config file — KWallet or nothing.
    if not shutil.which("kwallet-query"):
        print("Error: kwallet-query not found. Install the 'kf6-kwallet' package.")
        sys.exit(1)

    client_id     = input("Enter your Spotify Client ID:     ").strip()
    client_secret = input("Enter your Spotify Client Secret: ").strip()

    if not client_id or not client_secret:
        print("\nError: Client ID and Client Secret are required.")
        sys.exit(1)

    global _expected_state
    code_verifier, code_challenge = _pkce_pair()
    _expected_state = secrets.token_urlsafe(16)
    auth_url = _build_auth_url(client_id, _expected_state, code_challenge)

    # Start callback server in a background thread (handles one request).
    # Bound to the loopback address literally, matching REDIRECT_URI — "localhost"
    # can resolve to ::1, which would not match the URI Spotify redirects to.
    server = HTTPServer(("127.0.0.1", 8888), _CallbackHandler)
    thread = Thread(target=server.handle_request, daemon=True)
    thread.start()

    print("\nOpening browser to authorize the widget...")
    print("If it doesn't open automatically, visit:")
    print(f"  {auth_url}")
    print()
    webbrowser.open(auth_url)
    print("Waiting for Spotify callback (timeout: 2 minutes)...")

    thread.join(timeout=120)

    if _callback_result["error"]:
        print(f"\nAuthorization failed: {_callback_result['error']}")
        print("Re-run this script to try again.")
        sys.exit(1)

    if not _callback_result["code"]:
        print("\nTimeout: no callback received within 2 minutes.")
        print("Make sure the redirect URI is registered in your Spotify app settings.")
        sys.exit(1)

    print("Exchanging authorization code for tokens...")
    try:
        tokens = _exchange_code(client_id, client_secret, _callback_result["code"], code_verifier)
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        print(f"\nToken exchange failed ({e.code}): {body}")
        sys.exit(1)

    refresh_token = tokens.get("refresh_token", "")
    if not refresh_token:
        print("\nError: No refresh_token in the Spotify response.")
        print("Full response:", json.dumps(tokens, indent=2))
        sys.exit(1)

    print(f"Storing secrets in KWallet ({WALLET} → {WALLET_FOLDER})...")
    try:
        _wallet_write("clientSecret", client_secret)
        _wallet_write("refreshToken", refresh_token)
    except RuntimeError as e:
        print(f"\nError: {e}")
        print("Nothing was saved. Is KWallet running and unlocked?")
        sys.exit(1)

    print()
    print("=" * 60)
    print("  SUCCESS! Secrets are in KWallet.")
    print("=" * 60)
    print()
    print("  Paste this into the widget config (right-click → Configure):")
    print()
    print(f"    Client ID: {client_id}")
    print()
    print("  The client secret and refresh token were NOT printed — they")
    print("  went straight into KWallet. Manage them with kwalletmanager5.")
    print()


def _selftest():
    good = "code=abc&state=s1"
    assert _parse_callback(good, "s1")        == ("abc", None)
    assert _parse_callback(good, "other")[0]  is None      # forged code rejected
    assert _parse_callback("code=abc", "s1")[0] is None    # no state at all
    assert _parse_callback("error=access_denied&state=s1", "s1") == (None, "access_denied")
    assert _parse_callback("state=s1", "s1")[0] is None    # neither code nor error
    print("selftest ok")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        _selftest()
    else:
        main()
