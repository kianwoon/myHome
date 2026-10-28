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

# TimerTypeEnum.DEVICE in the app. GwBroadcastMonitorService.mVersion (3.0)
# is what the app sends for group add/update; list/remove/status use 2.0.
TIMER_TYPE = "device"
TIMER_VERSION = "3.0"


def _timer_instruct_json(instruct):
    """IoT Core instruct[time/functions] -> app API [{time, dps}] JSON string."""
    points = []
    if isinstance(instruct, list):
        for item in instruct:
            if not isinstance(item, dict):
                continue
            dps = {}
            functions = item.get("functions")
            if isinstance(functions, list):
                for function in functions:
                    if not isinstance(function, dict):
                        continue
                    code = function.get("code")
                    if isinstance(code, str) and code:
                        dps[code] = function.get("value")
            points.append({"time": str(item.get("time") or ""), "dps": dps})
    return json.dumps(points, separators=(",", ":"))


def _normalise_timer_entries(result):
    """App DpTimerListBean list -> the IoT Core category/group/timer shape."""
    entries = []
    if not isinstance(result, list):
        return entries
    for bean in result:
        if not isinstance(bean, dict):
            continue
        raw_category = bean.get("category")
        if isinstance(raw_category, dict):
            category = {
                "category": raw_category.get("category", ""),
                "status": raw_category.get("status", 1),
            }
        else:
            category = {"category": str(raw_category or ""), "status": 1}
        groups = []
        raw_groups = bean.get("groups")
        if isinstance(raw_groups, list):
            for group in raw_groups:
                if not isinstance(group, dict):
                    continue
                timers = []
                raw_timers = group.get("timers")
                if isinstance(raw_timers, list):
                    for timer in raw_timers:
                        if not isinstance(timer, dict):
                            continue
                        dps = timer.get("dps")
                        if isinstance(dps, str):
                            try:
                                dps = json.loads(dps)
                            except ValueError:
                                dps = {}
                        if not isinstance(dps, dict):
                            dps = {}
                        timers.append({
                            "time": str(timer.get("time") or ""),
                            "loops": str(timer.get("loops") or ""),
                            "status": timer.get("status", 1),
                            "alias_name": timer.get("aliasName")
                                          or timer.get("alias_name") or "",
                            "functions": [
                                {"code": code, "value": value}
                                for code, value in dps.items()
                            ],
                        })
                groups.append({
                    "id": str(group.get("id") or group.get("groupId") or ""),
                    "timers": timers,
                })
        entries.append({"category": category, "groups": groups})
    return entries


_SCHEMA_TYPES = {
    "bool": "Boolean",
    "enum": "Enum",
    "value": "Value",
    "string": "String",
    "bitmap": "Bitmap",
    "raw": "Raw",
}


def _normalise_schema(schema):
    """App product schema -> (spec by dp id, code -> dp id) like IoT Core."""
    spec = {}
    codes = {}
    for entry in schema:
        if not isinstance(entry, dict):
            continue
        dp_id = entry.get("id")
        code = entry.get("code")
        if dp_id is None or not isinstance(code, str) or not code:
            continue
        prop = entry.get("property")
        prop = prop if isinstance(prop, dict) else {}
        raw_type = str(prop.get("type") or "").lower()
        values = {}
        if raw_type == "enum":
            values = {"range": list(prop.get("range") or [])}
        elif raw_type == "value":
            values = {
                key: prop[key]
                for key in ("min", "max", "scale", "step", "unit")
                if key in prop
            }
        spec[str(dp_id)] = {
            "code": code,
            "type": _SCHEMA_TYPES.get(raw_type, entry.get("type", "")),
            "values": values,
        }
        codes[code] = str(dp_id)
    return spec, codes


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

    def _raw_devices(self):
        """Every raw app device across the account's homes (unmapped)."""
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
                if isinstance(device, dict) and device.get("devId"):
                    devices.append(device)
        return devices

    def _list_devices(self):
        devices = []
        for device in self._raw_devices():
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

    # MARK: - Device actions (fallback for the IoT Core device routes)

    def _session_retry(self, operation):
        """Run one device call, retrying exactly once after a session expiry.

        Returns (value, None) or (None, code). A passwordless (code-login)
        session cannot be refreshed here; its server code is surfaced.
        """
        try:
            return operation(), None
        except AppApiSessionError as exc:
            if not self._password:
                return None, str(exc.code)
            self._sid = None
            error = self.login()
            if error is not None:
                return None, str(error.get("Payload") or error.get("Err"))
            try:
                return operation(), None
            except AppApiError as retry_exc:
                return None, str(retry_exc.code)
        except AppApiError as exc:
            return None, str(exc.code)

    def _device_call(self, action, payload, version=API_VERSION):
        """One device action through the session retry helper."""
        return self._session_retry(
            lambda: self._api(action, payload, version=version))

    def rename_device(self, device_id, name):
        """Rename one device upstream. (True, None) or (None, code)."""
        result, error = self._device_call(
            "thing.m.device.name.update", {"devId": device_id, "name": name})
        if error is not None:
            return None, error
        if result is False:
            return None, "NAME_UPDATE_FAILED"
        return True, None

    def device_status(self, device_id):
        """Dps keyed by dp id from the device detail call. (dps, code)."""
        result, error = self._device_call(
            "thing.m.device.get", {"devId": device_id}, version="4.1")
        if error is not None:
            return None, error
        points = result.get("dataPointInfo") if isinstance(result, dict) else None
        dps = points.get("dps") if isinstance(points, dict) else None
        if not isinstance(dps, dict):
            return None, "BAD_RESPONSE"
        return dict(dps), None

    def publish_dps(self, device_id, dps):
        """Publish dp values exactly like the app. (True, None) or code."""
        result, error = self._device_call(
            "thing.m.device.dp.publish",
            {"devId": device_id,
             "dps": json.dumps(dps, separators=(",", ":"))},
        )
        if error is not None:
            return None, error
        if result is False:
            return None, "DP_PUBLISH_FAILED"
        return True, None

    def device_online(self):
        """{device id: online} for the whole account from ONE list call."""
        devices, error = self._session_retry(self._raw_devices)
        if error is not None:
            return None, error
        mapping = {}
        for device in devices:
            device_id = device.get("devId")
            modules = device.get("moduleMap")
            if not device_id or not isinstance(modules, dict):
                continue
            states = [
                module.get("isOnline")
                for module in modules.values()
                if isinstance(module, dict) and "isOnline" in module
            ]
            if states:
                mapping[device_id] = any(state is True for state in states)
        return mapping, None

    def room_map(self):
        """{device id: room name} from home/room list calls. (map, code)."""
        locations, error = self._session_retry(
            lambda: self._api("tuya.m.location.list"))
        if error is not None:
            return None, error
        if not isinstance(locations, list):
            return None, "BAD_RESPONSE"
        mapping = {}
        for location in locations:
            group_id = location.get("groupId") if isinstance(location, dict) else None
            if not group_id:
                continue
            rooms, error = self._device_call(
                "thing.m.room.list", {"gid": group_id}, version="3.0")
            if error is not None or not isinstance(rooms, list):
                continue
            for room in rooms:
                room_id = room.get("id") if isinstance(room, dict) else None
                room_name = room.get("name") if isinstance(room, dict) else None
                if room_id is None or not room_name:
                    continue
                data, error = self._device_call(
                    "m.life.app.room.data.list",
                    {"roomId": room_id, "gid": group_id}, version="2.1")
                if error is not None or not isinstance(data, dict):
                    continue
                for member in data.get("deviceSortList") or []:
                    if not isinstance(member, dict) or member.get("bizType") != 6:
                        continue
                    device_id = member.get("bizId")
                    if device_id:
                        mapping[device_id] = room_name
        return mapping, None

    def product_specs(self, product_ids):
        """Capability specs for product ids in one call. (map, code).

        Returns {product id: (spec, codes)} shaped exactly like the IoT Core
        specifications payload: spec is keyed by dp id and codes maps each
        declared code to its dp id string.
        """
        unique = []
        for product_id in product_ids:
            if (isinstance(product_id, str) and product_id
                    and product_id not in unique):
                unique.append(product_id)
        if not unique:
            return {}, None
        payload = {
            "productIds": json.dumps(
                [{"pid": product_id, "ver": "1.0.0"}
                 for product_id in unique],
                separators=(",", ":")),
            "zigbeeGroup": True,
        }
        result, error = self._device_call(
            "thing.m.device.ref.info.list", payload, version="6.1")
        if error is not None:
            return None, error
        specs = {}
        if not isinstance(result, list):
            return specs, None
        for product in result:
            if not isinstance(product, dict):
                continue
            info = product.get("schemaInfo")
            raw = info.get("schema") if isinstance(info, dict) else None
            if isinstance(raw, str):
                try:
                    raw = json.loads(raw)
                except ValueError:
                    continue
            if not isinstance(raw, list):
                continue
            specs[product.get("id")] = _normalise_schema(raw)
        return specs, None

    # MARK: - Timer API (mirrors the IoT Core timer REST semantics)

    def timer_list(self, device_id, category=None):
        """All timer groups, normalised to the IoT Core timers shape.

        Returns (list, None) or (None, code). Timers are mapped from the app's
        dps map to the bridge's functions[] form; categories/groups keep the
        same nesting the flatten helper already consumes.
        """
        result, error = self._timer_call(
            "thing.m.timer.all.list",
            {"bizId": device_id, "type": TIMER_TYPE}, version="2.0")
        if error is not None:
            return None, error
        entries = _normalise_timer_entries(result)
        if category is not None:
            entries = [entry for entry in entries
                       if entry.get("category", {}).get("category") == category]
        return entries, None

    def timer_add(self, device_id, body):
        """Create a timer group. Returns ({"group_id": id}, None) or code."""
        payload = self._timer_payload(device_id, body)
        result, error = self._timer_call(
            "thing.m.timer.group.add", payload, version=TIMER_VERSION)
        if error is not None:
            return None, error
        group_id = ""
        if isinstance(result, dict):
            group_id = (result.get("groupId") or result.get("group_id")
                        or result.get("id") or "")
        elif isinstance(result, str):
            group_id = result
        if not group_id:
            # The app API returns {} for a successful add; recover the new
            # group id from the refreshed list (match time + loops).
            group_id = self._find_added_group(device_id, payload)
        return {"group_id": str(group_id)}, None

    def _find_added_group(self, device_id, payload):
        """Recover the id of a just-added group from the refreshed list."""
        try:
            points = json.loads(payload.get("instruct") or "[]")
        except ValueError:
            points = []
        wanted_time = str(points[0].get("time") or "") if points else ""
        entries, error = self.timer_list(
            device_id, category=payload.get("category"))
        if error is not None:
            return ""
        for entry in entries:
            for group in entry.get("groups") or []:
                for timer in group.get("timers") or []:
                    if (wanted_time and timer.get("time") == wanted_time
                            and timer.get("loops") == payload.get("loops")):
                        return str(group.get("id") or "")
        return ""

    def timer_update(self, device_id, group_id, category, body):
        """Replace one timer group's content (time/loops/instruct)."""
        payload = self._timer_payload(device_id, body)
        payload["groupId"] = group_id
        if category:
            payload["category"] = category
        return self._timer_call(
            "thing.m.timer.group.update", payload, version=TIMER_VERSION)

    def timer_remove(self, device_id, category, group_id):
        """Delete one timer group."""
        payload = {
            "bizId": device_id,
            "category": category,
            "groupId": group_id,
            "type": TIMER_TYPE,
        }
        return self._timer_call(
            "thing.m.timer.group.remove", payload, version="2.0")

    def timer_status_update(self, device_id, group_id, category, status):
        """Enable (1) or disable (0) one timer group."""
        payload = {
            "bizId": device_id,
            "groupId": group_id,
            "category": category,
            "status": 1 if status else 0,
            "type": TIMER_TYPE,
        }
        return self._timer_call(
            "thing.m.timer.group.status.update", payload, version="2.0")

    def _timer_payload(self, device_id, body):
        """Translate one IoT Core timer body into an app API group payload."""
        body = body if isinstance(body, dict) else {}
        payload = {
            "bizId": device_id,
            "category": body.get("category") or "",
            "loops": body.get("loops") or "1111111",
            "timeZone": body.get("time_zone") or "+00:00",
            "type": TIMER_TYPE,
            "instruct": _timer_instruct_json(body.get("instruct")),
        }
        alias = body.get("alias_name")
        if isinstance(alias, str) and alias:
            payload["aliasName"] = alias
        return payload

    def _timer_call(self, action, payload, version):
        """One timer action, retrying once after a session expiry.

        Returns (result, None) or (None, code). A code-login session cannot be
        refreshed here; its server code is surfaced unchanged.
        """
        return self._session_retry(
            lambda: self._api(action, payload, version=version))

    # MARK: - Transport and signing

    def _api(self, action, payload=None, extra_params=None, requires_sid=True,
             number=ERR_CLOUD, version=API_VERSION):
        params = {
            "a": action,
            "clientId": self._client_id,
            "v": version,
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
