# baseline-guard:allow new module, no prior baseline exists
"""Tuya App API login and device roster, used when the IoT Core API fails.

Protocol recipe follows blakadder/tuya-uncover (MIT): the mobile app's
a1.tuya<region>.com endpoint, HMAC-SHA256 request signing over sorted
params, and plain-RSA password encryption against the token-create key.
Do not re-derive the scheme — the constants and ordering below match the
reference implementation.

General rule: credentials, the password hash and the session id never leave
this module in clear text. Responses are the tinytuya devices.json roster
shape, and every failure is an error_json() dict carrying only a code.
"""

import hashlib
import hmac
import json
import time

import requests

from tinytuya.core.error_helper import (
    ERR_CLOUD,
    ERR_CLOUDRESP,
    ERR_CLOUDTOKEN,
    ERR_CONNECT,
    ERR_TIMEOUT,
    error_json,
)

USER_AGENT = "TY-UA=APP/Android/1.1.6/SDK/null"
API_VERSION = "1.0"

# The Smart Life app pair is the default; a rotated/alternate pair can be
# supplied through config without touching this module.
DEFAULT_CLIENT_ID = "ekmnwp9f5pnh3trdtpgy"
DEFAULT_SECRET = (
    "0F:C3:61:99:9C:C0:C3:5B:A8:AC:A5:7D:AA:55:93:A2:0C:F5:57:27:70:2E:A8:5A:"
    "D7:B3:22:89:49:F8:88:FE_jfg5rs5kkmrj5mxahugvucrsvw43t48x_r3me7ghmxjevrvnpem"
    "wmhw3fxtacphyg"
)

# Session ids are reused across calls; a stale one is detected server-side and
# triggers exactly one re-login.
SESSION_TTL = 3600
SESSION_ERRORS = ("USER_SESSION_INVALID", "USER_TOKEN_INVALID",
                  "USER_SESSION_EXPIRED")


class AppApiError(RuntimeError):
    """One failed App API call. Holds a code only — never request material."""

    def __init__(self, code, number=ERR_CLOUD):
        self.code = code
        self.number = number
        super().__init__(str(code))


class AppApiSessionError(AppApiError):
    """The session id is missing or expired; a re-login may fix it."""


def _error_dict(exc):
    """Map a failure to the tinytuya error shape, carrying only the code."""
    return error_json(exc.number, exc.code)


class TuyaAppAPI(object):
    """Mobile-app API client: email/password login plus the device roster."""

    def __init__(self, client_id, secret, region, country_code, email, password):
        self._client_id = client_id
        self._secret = secret
        self._region = region or "eu"
        self._endpoint = "https://a1.tuya%s.com/api.json" % self._region
        self._country_code = country_code or ""
        self._email = email
        self._password = password
        self._session = requests.session()
        self._sid = None
        self._at = None
        self._sid_time = 0

    # MARK: - Public API

    def send_email_code(self):
        """Request a passwordless email login code. None, or an error dict.

        The code itself is generated server-side; this reply never contains
        it, and nothing here logs request or response material.
        """
        try:
            self._send_email_code()
        except AppApiError as exc:
            return _error_dict(exc)
        return None

    def login_with_code(self, code):
        """Exchange an emailed code for a session. None, or an error dict.

        Shares the session cache and expiry handling with password login:
        the resulting sid/at are stored exactly the same way.
        """
        try:
            self._login_with_code(code)
        except AppApiError as exc:
            self._sid = None
            return _error_dict(exc)
        return None

    def session_state(self):
        """Session material for owner-only persistence; None when absent."""
        if not self._sid:
            return None
        return {"sid": self._sid, "at": self._at,
                "savedAt": int(self._sid_time)}

    def restore_session(self, sid, at=None, saved_at=None):
        """Adopt a persisted session so a restart does not re-login."""
        if not isinstance(sid, str) or not sid:
            return False
        self._sid = sid
        self._at = at if isinstance(at, str) and at else None
        try:
            self._sid_time = float(saved_at)
        except (TypeError, ValueError):
            self._sid_time = time.time()
        return True

    def login(self):
        """Fetch and cache a session id. Returns None, or an error dict."""
        try:
            self._login()
        except AppApiError as exc:
            self._sid = None
            return _error_dict(exc)
        return None

    def getdevices(self):
        """Return the roster in tinytuya devices.json shape, or an error dict.

        The roster is the app's device list mapped exactly like uncover's
        map_tt_compat output: name/id/key/mac/uuid/category/product_id/icon.
        """
        if self._sid is None or (
                self._password
                and (time.time() - self._sid_time) > SESSION_TTL):
            error = self.login()
            if error is not None:
                return error
        try:
            return self._list_devices()
        except AppApiSessionError as exc:
            # A passwordless (code-login) session cannot be refreshed without
            # a fresh emailed code; report the expiry instead of attempting a
            # password flow that the account does not have.
            if not self._password:
                self._sid = None
                return _error_dict(exc)
            # Exactly one retry: a fresh session usually fixes an expired sid.
            self._sid = None
            error = self.login()
            if error is not None:
                return error
            try:
                return self._list_devices()
            except AppApiError as exc:
                return _error_dict(exc)
        except AppApiError as exc:
            return _error_dict(exc)

    # MARK: - Login flow

    def _login(self):
        token_info = self._api(
            "tuya.m.user.email.token.create",
            {"countryCode": self._country_code, "email": self._email},
            requires_sid=False,
            number=ERR_CLOUDTOKEN,
        )
        if not isinstance(token_info, dict):
            raise AppApiError("BAD_RESPONSE", ERR_CLOUDRESP)
        modulus = token_info.get("publicKey") or token_info.get("pbKey")
        exponent = token_info.get("exponent")
        token = token_info.get("token")
        if not modulus or not exponent or not token:
            raise AppApiError("BAD_RESPONSE", ERR_CLOUDRESP)

        payload = {
            "countryCode": self._country_code,
            "email": self._email,
            "ifencrypt": 1,
            "options": '{"group": 1}',
            "passwd": self._enc_password(modulus, exponent, self._password),
            "token": token,
        }
        login_info = self._api(
            "tuya.m.user.email.password.login",
            payload,
            requires_sid=False,
            number=ERR_CLOUDTOKEN,
        )
        self._store_session(login_info)

    def _send_email_code(self):
        # Same call shape as token.create: identity comes from the payload,
        # no session is required to request a code.
        self._api(
            "tuya.m.user.email.code.send",
            {"countryCode": self._country_code, "email": self._email},
            requires_sid=False,
            number=ERR_CLOUDTOKEN,
        )

    def _login_with_code(self, code):
        payload = {
            "countryCode": self._country_code,
            "email": self._email,
            "code": code,
        }
        login_info = self._api(
            "thing.m.user.email.code.login",
            payload,
            requires_sid=False,
            number=ERR_CLOUDTOKEN,
        )
        self._store_session(login_info)

    def _store_session(self, info):
        """Adopt sid/at from a login reply; both are opaque server tokens."""
        if not isinstance(info, dict):
            raise AppApiError("BAD_RESPONSE", ERR_CLOUDRESP)
        sid = info.get("sid")
        if not isinstance(sid, str) or not sid:
            raise AppApiError("NO_SESSION", ERR_CLOUDTOKEN)
        access = info.get("at")
        self._sid = sid
        self._at = access if isinstance(access, str) and access else None
        self._sid_time = time.time()

    def _list_devices(self):
        devices = []
        groups = self._api("tuya.m.location.list")
        if not isinstance(groups, list):
            raise AppApiError("BAD_RESPONSE", ERR_CLOUDRESP)
        for group in groups:
            group_id = group.get("groupId") if isinstance(group, dict) else None
            if not group_id:
                continue
            found = self._api(
                "tuya.m.my.group.device.list",
                extra_params={"gid": group_id},
            )
            if not isinstance(found, list):
                continue
            for device in found:
                mapped = self._map_device(device)
                if mapped is not None:
                    devices.append(mapped)
        return devices

    @staticmethod
    def _map_device(device):
        """One app device -> tinytuya devices.json entry (identity fields)."""
        if not isinstance(device, dict) or not device.get("devId"):
            return None
        mac = device.get("mac")
        if isinstance(mac, str) and len(mac) == 12:
            mac = ":".join(mac[i:i + 2] for i in range(0, len(mac), 2))
        else:
            mac = ""
        return {
            "name": device.get("name") or device.get("devId"),
            "id": device.get("devId"),
            "key": device.get("localKey", ""),
            "mac": mac,
            "uuid": device.get("uuid", ""),
            "category": device.get("category", ""),
            "product_id": device.get("productId", ""),
            "sub": bool(device.get("virtual")),
            "icon": device.get("iconUrl", ""),
        }

    # MARK: - Transport and signing

    def _api(self, action, payload=None, extra_params=None, requires_sid=True,
             number=ERR_CLOUD):
        params = {
            "a": action,
            "clientId": self._client_id,
            "v": API_VERSION,
            "time": str(int(time.time())),
        }
        if extra_params:
            params.update(extra_params)
        data = {}
        if payload is not None:
            data["postData"] = json.dumps(payload, separators=(",", ":"))
        if requires_sid:
            if not self._sid:
                raise AppApiSessionError("NO_SESSION")
            params["sid"] = self._sid
        params["sign"] = self._sign(dict(params, **data))

        try:
            response = self._session.post(
                self._endpoint,
                params=params,
                data=data,
                headers={"User-Agent": USER_AGENT},
                timeout=20,
            )
        except requests.Timeout as exc:
            raise AppApiError(None, ERR_TIMEOUT) from exc
        except requests.RequestException as exc:
            raise AppApiError(None, ERR_CONNECT) from exc

        try:
            body = response.json()
        except ValueError as exc:
            raise AppApiError("BAD_JSON", ERR_CLOUDRESP) from exc
        return self._unwrap(body, number)

    @staticmethod
    def _unwrap(body, number):
        """Return result on success; raise a code-only error otherwise."""
        if not isinstance(body, dict) or "success" not in body:
            raise AppApiError("BAD_RESPONSE", ERR_CLOUDRESP)
        if body.get("success"):
            return body.get("result")
        code = body.get("errorCode") or body.get("code") or "UNKNOWN"
        if code in SESSION_ERRORS:
            raise AppApiSessionError(code)
        raise AppApiError(code, number)

    def _sign(self, data):
        """HMAC-SHA256 over sorted k=v pairs, postData md5-swizzled."""
        parts = []
        for key in sorted(data.keys()):
            if key == "gid":
                continue
            value = data[key]
            if key == "postData":
                value = self._mobile_hash(value)
            parts.append(key + "=" + str(value))
        return hmac.new(
            self._secret.encode("utf-8"),
            "||".join(parts).encode("utf-8"),
            hashlib.sha256,
        ).hexdigest()

    @staticmethod
    def _mobile_hash(data):
        prehash = hashlib.md5(data.encode("utf-8")).hexdigest()
        return prehash[8:16] + prehash[0:8] + prehash[24:32] + prehash[16:24]

    @classmethod
    def _enc_password(cls, modulus, exponent, password):
        passwd_hash = hashlib.md5(password.encode("utf-8")).hexdigest()
        return cls._plain_rsa_encrypt(
            int(modulus), int(exponent), passwd_hash.encode("utf-8")).hex()

    @staticmethod
    def _plain_rsa_encrypt(modulus, exponent, message):
        message_int = int.from_bytes(message, "big")
        return pow(message_int, exponent, modulus).to_bytes(256, "big")
