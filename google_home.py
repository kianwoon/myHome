"""Google Home MCP client for the MyHome bridge.

baseline-guard:allow new file, no prior baseline exists

Talks to the Google Home remote MCP server (home.googleapis.com) over
streamable HTTP JSON-RPC and authenticates with an installed-app OAuth flow
(loopback redirect + PKCE). Tokens are cached in an owner-only file.

Secret handling: values from .env.txt, the OAuth client-secret file and any
token are never printed, logged or returned in error text. Only KEY NAMES and
booleans about their presence are reported.

CLI:
    python3 google_home.py probe          # offline check, key names only
    python3 google_home.py auth           # interactive OAuth consent
    python3 google_home.py list           # list_homes + list_home_resources
    python3 google_home.py states [id]    # list_home_states
    python3 google_home.py action <id> <action>

This module is dependency-free (urllib only) so importing it and running
`probe` works with no third-party packages installed.
"""

import base64
import glob
import hashlib
import http.server
import json
import logging
import os
import secrets
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request

log = logging.getLogger("google_home")

# Config lives beside the script for dev runs; a bundled app points this at a
# writable user-data directory because the .app bundle itself is read-only.
BASE_DIR = os.environ.get("MYHOME_DATA_DIR") or os.path.dirname(os.path.abspath(__file__))
ENV_PATH = os.path.join(BASE_DIR, ".env.txt")
CLIENT_GLOB = os.path.join(BASE_DIR, "client_secret_*.apps.googleusercontent.com.json")
TOKEN_PATH = os.environ.get(
    "GOOGLE_HOME_TOKEN_FILE",
    os.path.join(os.path.expanduser("~"), ".myhome", "google_home_token.json"),
)

EXPECTED_ENV_KEYS = ("GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET", "GOOGLE_HOME_API")

DEFAULT_MCP_URL = "https://home.googleapis.com/mcp"
DEFAULT_SCOPE = "https://www.googleapis.com/auth/home.platform.v2"
MCP_PROTOCOL_VERSION = "2025-03-26"
HTTP_TIMEOUT = 30
REDACTED = "[redacted]"


class GoogleHomeError(Exception):
    """Runtime failure with an already-redacted message."""

    def __init__(self, message, consent_url=None):
        Exception.__init__(self, message)
        self.consent_url = consent_url


class AuthRequired(GoogleHomeError):
    """No usable token; the caller must complete interactive consent."""


# ---------------------------------------------------------------------------
# Config loading (values stay in memory; never printed)
# ---------------------------------------------------------------------------


def load_env(path=None):
    """Parse KEY=VALUE lines from .env.txt into a dict."""
    path = path or ENV_PATH
    values = {}
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("export "):
                    line = line[7:].strip()
                if "=" not in line:
                    continue
                key, value = line.split("=", 1)
                key = key.strip()
                value = value.strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
                    value = value[1:-1]
                if key:
                    values[key] = value
    except OSError:
        pass
    return values


def load_client_config(path=None):
    """Return the 'installed'/'web' OAuth client dict, or raise."""
    if path is None:
        matches = sorted(glob.glob(CLIENT_GLOB))
        if not matches:
            raise GoogleHomeError("OAuth client secret file not found")
        path = matches[0]
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError) as exc:
        raise GoogleHomeError("OAuth client file could not be parsed: %s" % type(exc).__name__)
    if isinstance(data, dict):
        for key in ("installed", "web"):
            if isinstance(data.get(key), dict):
                return data[key]
    raise GoogleHomeError("OAuth client file has no installed/web section")


def cached_token():
    """Read the cached token dict, or {} when absent/unreadable."""
    try:
        with open(TOKEN_PATH, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def save_token(token):
    """Atomically cache a token in an owner-only (0o600) file."""
    directory = os.path.dirname(TOKEN_PATH)
    if directory and not os.path.isdir(directory):
        os.makedirs(directory, mode=0o700)
        try:
            os.chmod(directory, 0o700)
        except OSError:
            pass
    temp_path = TOKEN_PATH + ".tmp"
    descriptor = os.open(temp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(token, handle)
        os.replace(temp_path, TOKEN_PATH)
        os.chmod(TOKEN_PATH, 0o600)
    except Exception:
        try:
            os.unlink(temp_path)
        except OSError:
            pass
        raise


def redact(text):
    """Strip every configured secret value from a string."""
    text = "" if text is None else str(text)
    secrets_to_hide = []
    for value in load_env().values():
        if value:
            secrets_to_hide.append(value)
    try:
        client = load_client_config()
        for key in ("client_secret", "client_id"):
            if client.get(key):
                secrets_to_hide.append(client[key])
    except GoogleHomeError:
        pass
    for token in cached_token().values():
        if isinstance(token, str) and len(token) > 8:
            secrets_to_hide.append(token)
    for value in sorted(set(secrets_to_hide), key=len, reverse=True):
        text = text.replace(value, REDACTED)
    return text


def safe_error(exc):
    """Redacted error text safe to emit to the app."""
    return redact(str(exc) or type(exc).__name__)


# ---------------------------------------------------------------------------
# OAuth (installed app, loopback redirect + PKCE)
# ---------------------------------------------------------------------------


def _token_request(form, token_uri, timeout=HTTP_TIMEOUT):
    body = urllib.parse.urlencode(form).encode("utf-8")
    request = urllib.request.Request(
        token_uri,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as exc:
        raise GoogleHomeError("OAuth token endpoint returned HTTP %d" % exc.code)
    except (urllib.error.URLError, ValueError, OSError) as exc:
        raise GoogleHomeError("OAuth token request failed: %s" % type(exc).__name__)
    if not isinstance(payload, dict) or not payload.get("access_token"):
        raise GoogleHomeError("OAuth token response was incomplete")
    return payload


def _pkce_pair():
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(48)).decode("ascii").rstrip("=")
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    challenge = base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")
    return verifier, challenge


class _ConsentHandler(http.server.BaseHTTPRequestHandler):
    """One-shot loopback listener for the authorization code."""

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        self.server.auth_code = (params.get("code") or [None])[0]
        self.server.auth_error = (params.get("error") or [None])[0]
        body = b"Google Home consent received. You may close this window."
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.server.done.set()

    def log_message(self, format, *args):  # silence request logging
        return


class _ConsentServer(http.server.HTTPServer):
    """Loopback HTTP server carrying the consent result."""

    def __init__(self, *args, **kwargs):
        http.server.HTTPServer.__init__(self, *args, **kwargs)
        self.done = threading.Event()
        self.auth_code = None
        self.auth_error = None


def build_consent_url(client, redirect_uri, scope, state, challenge):
    """Construct the consent URL (client_id is public, no secret included)."""
    query = {
        "client_id": client.get("client_id", ""),
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "scope": scope,
        "access_type": "offline",
        "prompt": "consent",
        "state": state,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
    }
    auth_uri = client.get("auth_uri") or "https://accounts.google.com/o/oauth2/auth"
    return auth_uri + "?" + urllib.parse.urlencode(query)


def authorize(scope=None, open_browser=True, timeout=300):
    """Run the interactive consent flow and cache the resulting token."""
    client = load_client_config()
    scope = scope or os.environ.get("GOOGLE_HOME_SCOPE") or DEFAULT_SCOPE
    verifier, challenge = _pkce_pair()
    state = secrets.token_urlsafe(16)

    server = _ConsentServer(("127.0.0.1", 0), _ConsentHandler)
    port = server.server_address[1]
    redirect_uri = "http://localhost:%d" % port
    consent_url = build_consent_url(client, redirect_uri, scope, state, challenge)

    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        print("Open this URL in a browser to grant Google Home access:\n%s\n" % consent_url)
        print("Waiting for the consent redirect on %s (Ctrl-C to abort)..." % redirect_uri)
        if open_browser:
            try:
                import webbrowser

                webbrowser.open(consent_url)
            except Exception:
                pass
        if not server.done.wait(timeout):
            raise AuthRequired("consent timed out", consent_url)
    finally:
        server.shutdown()
        server.server_close()

    if server.auth_error:
        raise GoogleHomeError("consent was denied (%s)" % server.auth_error, consent_url)
    if not server.auth_code:
        raise GoogleHomeError("consent returned no authorization code", consent_url)

    token_uri = client.get("token_uri") or "https://oauth2.googleapis.com/token"
    form = {
        "code": server.auth_code,
        "client_id": client.get("client_id", ""),
        "client_secret": client.get("client_secret", ""),
        "redirect_uri": redirect_uri,
        "grant_type": "authorization_code",
        "code_verifier": verifier,
    }
    payload = _token_request(form, token_uri)
    payload["expires_at"] = _expires_at(payload)
    save_token(payload)
    return payload


def _expires_at(token):
    import time

    try:
        return int(time.time()) + int(token.get("expires_in", 3600))
    except (TypeError, ValueError):
        return None


def refresh_token(token=None):
    """Exchange a stored refresh token for a fresh access token."""
    token = token or cached_token()
    refresh = token.get("refresh_token")
    if not refresh:
        raise AuthRequired("no cached refresh token")
    client = load_client_config()
    token_uri = client.get("token_uri") or "https://oauth2.googleapis.com/token"
    form = {
        "client_id": client.get("client_id", ""),
        "client_secret": client.get("client_secret", ""),
        "refresh_token": refresh,
        "grant_type": "refresh_token",
    }
    payload = _token_request(form, token_uri)
    # Google omits refresh_token on refresh responses; preserve the old one.
    payload["refresh_token"] = payload.get("refresh_token") or refresh
    payload["expires_at"] = _expires_at(payload)
    save_token(payload)
    return payload


def access_token(token=None):
    """Return a valid access token, refreshing if expired. Never prints it."""
    import time

    token = token or cached_token()
    fresh = token.get("access_token")
    expires_at = token.get("expires_at")
    if fresh and (not expires_at or int(expires_at) - 60 > int(time.time())):
        return fresh
    if token.get("refresh_token"):
        return refresh_token(token)["access_token"]
    raise AuthRequired(
        "Google Home authorization required. Run: python3 google_home.py auth"
    )


# ---------------------------------------------------------------------------
# MCP transport (streamable HTTP JSON-RPC)
# ---------------------------------------------------------------------------


def _parse_sse(body, request_id):
    """Return the JSON-RPC payload for request_id from an SSE stream."""
    found = None
    for line in body.splitlines():
        if not line.startswith("data:"):
            continue
        chunk = line[5:].strip()
        if not chunk or chunk == "[DONE]":
            continue
        try:
            message = json.loads(chunk)
        except ValueError:
            continue
        if isinstance(message, dict) and message.get("id") == request_id:
            found = message
    return found


class McpClient:
    """Minimal MCP client over streamable HTTP."""

    def __init__(self, token=None, url=None, api_key=None):
        self.url = url or os.environ.get("GOOGLE_HOME_MCP_URL") or DEFAULT_MCP_URL
        self.api_key = api_key
        self.token = token
        self.session_id = None
        self.protocol_version = MCP_PROTOCOL_VERSION
        self._next_id = 0
        self._schemas = None

    def _headers(self):
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": self.protocol_version,
        }
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        if self.api_key:
            headers["X-Goog-Api-Key"] = self.api_key
        if self.session_id:
            headers["Mcp-Session-Id"] = self.session_id
        return headers

    def _post(self, payload):
        request = urllib.request.Request(
            self.url,
            data=json.dumps(payload).encode("utf-8"),
            method="POST",
            headers=self._headers(),
        )
        try:
            with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
                session = response.headers.get("Mcp-Session-Id")
                if session:
                    self.session_id = session
                raw = response.read().decode("utf-8", "replace")
                content_type = response.headers.get("Content-Type", "")
        except urllib.error.HTTPError as exc:
            body = ""
            try:
                # Read the whole body: a tools/list payload easily exceeds 2 KB.
                body = exc.read(4 * 1024 * 1024).decode("utf-8", "replace")
            except Exception:
                pass
            # Rule: the HTTP status code is only a hint. The Google Home
            # StatelessServer returns 401/403 even when the body holds a valid
            # JSON-RPC response, so a parseable body carrying "result" and no
            # "error" is authoritative and is returned as a normal response.
            usable = None
            if body.strip():
                try:
                    candidate = json.loads(body)
                except ValueError:
                    candidate = None
                    error_type = (exc.headers.get("Content-Type") or "").lower()
                    if "text/event-stream" in error_type:
                        candidate = _parse_sse(body, payload.get("id"))
                if (
                    isinstance(candidate, dict)
                    and "result" in candidate
                    and not candidate.get("error")
                ):
                    usable = candidate
            if usable is not None:
                session = exc.headers.get("Mcp-Session-Id")
                if session:
                    self.session_id = session
                return usable
            if exc.code in (401, 403):
                raise AuthRequired(
                    "Google Home authorization missing or expired. "
                    "Run: python3 google_home.py auth"
                )
            raise GoogleHomeError(
                "MCP HTTP %d: %s" % (exc.code, redact(body)[:200])
            )
        except (urllib.error.URLError, OSError) as exc:
            raise GoogleHomeError("MCP request failed: %s" % type(exc).__name__)

        if not raw.strip():
            return {}
        if "text/event-stream" in content_type.lower():
            parsed = _parse_sse(raw, payload.get("id"))
            if parsed is None:
                raise GoogleHomeError("MCP stream returned no matching response")
            return parsed
        try:
            return json.loads(raw)
        except ValueError:
            raise GoogleHomeError("MCP response was not valid JSON")

    def _request(self, method, params=None):
        self._next_id += 1
        payload = {"jsonrpc": "2.0", "id": self._next_id, "method": method}
        if params is not None:
            payload["params"] = params
        response = self._post(payload)
        if isinstance(response, dict) and response.get("error"):
            error = response["error"]
            message = error.get("message") if isinstance(error, dict) else str(error)
            raise GoogleHomeError("MCP error: %s" % redact(message)[:200])
        return response.get("result", {}) if isinstance(response, dict) else {}

    def initialize(self):
        result = self._request(
            "initialize",
            {
                "protocolVersion": MCP_PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "myhome-bridge", "version": "1.0"},
            },
        )
        if isinstance(result, dict) and result.get("protocolVersion"):
            self.protocol_version = result["protocolVersion"]
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return result

    def tool_schemas(self):
        if self._schemas is None:
            result = self._request("tools/list")
            tools = result.get("tools", []) if isinstance(result, dict) else []
            self._schemas = {
                tool.get("name"): tool for tool in tools if isinstance(tool, dict)
            }
        return self._schemas

    def call_tool(self, name, arguments):
        self.initialize()
        result = self._request("tools/call", {"name": name, "arguments": arguments})
        return _unwrap_tool_result(result)


def _unwrap_tool_result(result):
    """Return structured content when present, else joined text blocks."""
    if not isinstance(result, dict):
        return result
    if isinstance(result.get("structuredContent"), (dict, list)):
        return result["structuredContent"]
    texts = []
    for block in result.get("content", []) or []:
        if isinstance(block, dict) and block.get("type") == "text":
            texts.append(block.get("text", ""))
    joined = "\n".join(texts).strip()
    if not joined:
        return result
    try:
        return json.loads(joined)
    except ValueError:
        return {"text": joined}


# ---------------------------------------------------------------------------
# Tool adapters (schema-driven argument mapping)
# ---------------------------------------------------------------------------

_CANONICAL = {
    "homeid": "home_id",
    "home": "home_id",
    "homes": "home_id",
    "id": "device_id",
    "deviceid": "device_id",
    "device": "device_id",
    "resourceid": "device_id",
    "resource": "device_id",
    "deviceids": "device_id",
    "resourceids": "device_id",
    "resourcenames": "device_id",
    "devicenames": "device_id",
    "actions": "action",
    "action": "action",
    "command": "action",
    "commands": "action",
}


def _normalize(name):
    return "".join(ch for ch in str(name).lower() if ch.isalnum())


def build_arguments(schema, wanted):
    """Map semantic values onto a tool's declared parameter names."""
    properties = {}
    if isinstance(schema, dict):
        properties = schema.get("inputSchema", {}).get("properties", {}) or {}
    if not properties:
        return dict((key, value) for key, value in wanted.items() if value is not None)

    arguments = {}
    for prop in properties:
        canonical = _CANONICAL.get(_normalize(prop), _normalize(prop))
        if canonical not in wanted:
            continue
        value = wanted[canonical]
        if value is None:
            continue
        prop_type = properties.get(prop, {}).get("type")
        if prop_type == "array" and not isinstance(value, list):
            value = [value]
        arguments[prop] = value
    return arguments


def list_homes(token=None):
    """Call the list_homes tool."""
    client = _client(token)
    schema = client.tool_schemas().get("list_homes")
    return client.call_tool("list_homes", build_arguments(schema, {}))


def list_home_resources(token=None, home_id=None):
    """Call the list_home_resources tool."""
    client = _client(token)
    schema = client.tool_schemas().get("list_home_resources")
    return client.call_tool(
        "list_home_resources", build_arguments(schema, {"home_id": home_id})
    )


def list_home_states(token=None, device_id=None, home_id=None):
    """Call the list_home_states tool."""
    client = _client(token)
    schema = client.tool_schemas().get("list_home_states")
    return client.call_tool(
        "list_home_states",
        build_arguments(schema, {"device_id": device_id, "home_id": home_id}),
    )


def list_home_history(token=None, device_id=None, home_id=None):
    """Call the list_home_history tool."""
    client = _client(token)
    schema = client.tool_schemas().get("list_home_history")
    return client.call_tool(
        "list_home_history",
        build_arguments(schema, {"device_id": device_id, "home_id": home_id}),
    )


def run_home_actions(token=None, device_id=None, action=None, home_id=None):
    """Call the run_home_actions tool."""
    client = _client(token)
    schema = client.tool_schemas().get("run_home_actions")
    return client.call_tool(
        "run_home_actions",
        build_arguments(
            schema,
            {"device_id": device_id, "action": action, "home_id": home_id},
        ),
    )


def _client(token=None):
    env = load_env()
    return McpClient(
        token=token or access_token(),
        url=os.environ.get("GOOGLE_HOME_MCP_URL"),
        api_key=env.get("GOOGLE_HOME_API"),
    )


def _first_home_id(homes):
    """Best-effort extraction of a home id from a list_homes payload."""
    if isinstance(homes, dict):
        for key in ("homes", "items", "results", "data"):
            if isinstance(homes.get(key), list):
                homes = homes[key]
                break
    if isinstance(homes, list):
        for home in homes:
            if not isinstance(home, dict):
                continue
            for key in ("id", "home_id", "homeId", "name", "resource"):
                if isinstance(home.get(key), str) and home[key]:
                    return home[key]
    return None


# ---------------------------------------------------------------------------
# High-level operations used by the bridge
# ---------------------------------------------------------------------------


def list_overview():
    """Return homes plus their resources."""
    token = access_token()
    homes = list_homes(token=token)
    resources = list_home_resources(token=token, home_id=_first_home_id(homes))
    return {"ok": True, "homes": homes, "resources": resources}


def states(device_id=None):
    """Return device states, optionally narrowed to one device id."""
    token = access_token()
    if device_id is None:
        home_id = _first_home_id(list_homes(token=token))
        return {"ok": True, "states": list_home_states(token=token, home_id=home_id)}
    states_payload = list_home_states(token=token, device_id=device_id)
    return {"ok": True, "states": states_payload}


def action(device_id, action_value, home_id=None):
    """Run an action against one device."""
    token = access_token()
    if home_id is None:
        home_id = _first_home_id(list_homes(token=token))
    result = run_home_actions(
        token=token, device_id=device_id, action=action_value, home_id=home_id
    )
    return {"ok": True, "result": result}


# ---------------------------------------------------------------------------
# Probe (offline, key names only)
# ---------------------------------------------------------------------------


def probe(path=None):
    """Offline readiness report. Values are never included."""
    env = load_env(path)
    found = [key for key in EXPECTED_ENV_KEYS if env.get(key)]
    missing = [key for key in EXPECTED_ENV_KEYS if not env.get(key)]
    report = {
        "envFile": os.path.basename(path or ENV_PATH),
        "envPresent": os.path.isfile(path or ENV_PATH),
        "envKeysFound": found,
        "envKeysMissing": missing,
        "envExtraKeys": sorted(set(env) - set(EXPECTED_ENV_KEYS)),
    }
    try:
        client = load_client_config()
        redirects = client.get("redirect_uris") or []
        report["clientFile"] = "parsed"
        report["clientType"] = "installed" if client.get("token_uri") else "unknown"
        report["clientHasSecret"] = bool(client.get("client_secret"))
        report["loopbackRedirect"] = any(
            str(uri).startswith("http://localhost") for uri in redirects
        )
    except GoogleHomeError as exc:
        report["clientFile"] = "error: " + safe_error(exc)
    token = cached_token()
    report["tokenCached"] = bool(token.get("access_token") or token.get("refresh_token"))
    report["tokenHasRefresh"] = bool(token.get("refresh_token"))
    if os.path.exists(TOKEN_PATH):
        try:
            report["tokenFileMode"] = oct(os.stat(TOKEN_PATH).st_mode & 0o777)
        except OSError:
            report["tokenFileMode"] = "unknown"
    report["mcpUrl"] = os.environ.get("GOOGLE_HOME_MCP_URL") or DEFAULT_MCP_URL
    return report


def _print_probe(report):
    print("google_home probe (offline)")
    print("  env file: %s (present=%s)" % (report["envFile"], report["envPresent"]))
    print("  keys found:   %s" % ", ".join(report["envKeysFound"] or ["-"]))
    print("  keys missing: %s" % ", ".join(report["envKeysMissing"] or ["-"]))
    if report["envExtraKeys"]:
        print("  extra keys:   %s" % ", ".join(report["envExtraKeys"]))
    print("  oauth client: %s" % report["clientFile"])
    if report["clientFile"] == "parsed":
        print(
            "  client:       has_secret=%s loopback_redirect=%s"
            % (report["clientHasSecret"], report["loopbackRedirect"])
        )
    print(
        "  token cache:  exists=%s refresh=%s mode=%s"
        % (
            report["tokenCached"],
            report["tokenHasRefresh"],
            report.get("tokenFileMode", "n/a"),
        )
    )
    print("  mcp endpoint: %s" % report["mcpUrl"])


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _run_operation(operation):
    """Run a network operation, printing consent guidance on auth failure."""
    try:
        return operation()
    except AuthRequired as exc:
        print("Authorization required: %s" % safe_error(exc))
        if exc.consent_url:
            print("Consent URL: %s" % exc.consent_url)
        print("Then re-run: python3 google_home.py auth")
    except GoogleHomeError as exc:
        print("Error: %s" % safe_error(exc))
        if exc.consent_url:
            print("Consent URL: %s" % exc.consent_url)
    except Exception as exc:  # noqa: BLE001 - CLI boundary never tracebacks
        print("Error: %s" % safe_error(exc))
    return None


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    command = argv[0] if argv else "probe"
    if command == "probe":
        _print_probe(probe())
        return 0
    if command == "auth":
        _run_operation(lambda: authorize() and {"ok": True})
        return 0
    if command == "list":
        result = _run_operation(list_overview)
    elif command == "states":
        result = _run_operation(lambda: states(argv[1] if len(argv) > 1 else None))
    elif command == "action":
        if len(argv) < 3:
            print("usage: python3 google_home.py action <id> <action>")
            return 2
        result = _run_operation(lambda: action(argv[1], argv[2]))
    else:
        print("usage: python3 google_home.py [probe|auth|list|states|action]")
        return 2
    if result is not None:
        print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
