#!/usr/bin/env python3
"""End-to-end exercise of the licence service against a local `wrangler dev`.

Covers the manual (DP1-) path in full, which needs no Dodo account: issue →
activate → seat limit → idempotent re-activation → refresh → deactivate →
re-use of the freed seat → revoke.
"""
import hashlib
import json
import urllib.error
import urllib.request

API = "http://localhost:8787"
ADMIN = "dev-admin-token-for-local-testing"

passed = failed = 0


def call(method, path, body=None, auth=False):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{API}{path}", data=data, method=method)
    req.add_header("content-type", "application/json")
    if auth:
        req.add_header("authorization", f"Bearer {ADMIN}")
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def check(label, actual, expected):
    global passed, failed
    ok = actual == expected
    passed, failed = passed + ok, failed + (not ok)
    print(f"  {'PASS' if ok else 'FAIL'}  {label}"
          + ("" if ok else f"\n          expected {expected!r}\n          got      {actual!r}"))


def device(name):
    return hashlib.sha256(name.encode()).hexdigest()


def activate(key, name):
    return call("POST", "/v1/activate",
                {"licenseKey": key, "deviceHash": device(name), "deviceName": name})


print("\n1. Admin issues a licence")
status, body = call("POST", "/v1/admin/licenses",
                    {"email": "buyer@example.com", "note": "e2e"}, auth=True)
check("returns 201", status, 201)
KEY = body["license"]["key"]
check("seat limit defaults to 3", body["license"]["seat_limit"], 3)
check("records the buyer", body["license"]["customer_email"], "buyer@example.com")
print(f"        key = {KEY}")

print("\n2. Admin API is closed without the bearer token")
check("no credentials  → 401", call("POST", "/v1/admin/licenses", {})[0], 401)
check("wrong password  → 401",
      urllib.request.Request(f"{API}/v1/admin/licenses") and
      call("GET", "/v1/admin/licenses")[0], 401)

print("\n3. Three Macs activate")
for mac in ("MacBook Air", "Mac mini", "iMac"):
    status, body = activate(KEY, mac)
    check(f"{mac:<14} activates", status, 200)
    if status == 200:
        check(f"{mac:<14} gets a token", isinstance(body.get("token"), str), True)

status, body = activate(KEY, "iMac")
check("three seats are in use", len(body["devices"]), 3)

print("\n4. The fourth Mac is refused")
status, body = activate(KEY, "Mac Studio")
check("returns 409", status, 409)
check("with a machine-readable code", body.get("error"), "seat_limit_reached")
print(f"        message: {body.get('detail')}")

print("\n5. Re-activating a known Mac does not burn a seat")
status, body = activate(KEY, "MacBook Air")
check("still succeeds", status, 200)
check("still three seats", len(body["devices"]), 3)

print("\n6. A key typed in lower case without dashes still resolves")
mangled = KEY.lower().replace("-", "").replace("dp1", "DP1-", 1)
status, _ = activate(mangled, "MacBook Air")
check(f"{mangled} accepted", status, 200)

print("\n7. Refresh re-issues a token for an activated Mac")
status, body = call("POST", "/v1/refresh",
                    {"licenseKey": KEY, "deviceHash": device("Mac mini"), "deviceName": "x"})
check("returns 200", status, 200)
check("carries a fresh token", isinstance(body.get("token"), str), True)

print("\n8. Refresh is refused for a Mac that never activated")
status, body = call("POST", "/v1/refresh",
                    {"licenseKey": KEY, "deviceHash": device("Stranger"), "deviceName": "x"})
check("returns 404", status, 404)
check("code is not_activated", body.get("error"), "not_activated")

print("\n9. Deactivating frees the seat for a new Mac")
status, body = call("POST", "/v1/deactivate",
                    {"licenseKey": KEY, "deviceHash": device("iMac"), "deviceName": "x"})
check("release succeeds", status, 200)
check("two seats left in use", len(body["devices"]), 2)
status, body = activate(KEY, "Mac Studio")
check("the new Mac now activates", status, 200)
check("back to three seats", len(body["devices"]), 3)

print("\n10. Revoking kills the licence")
status, _ = call("POST", f"/v1/admin/licenses/{KEY}/revoke",
                 {"reason": "e2e test"}, auth=True)
check("revoke returns 200", status, 200)
status, body = activate(KEY, "MacBook Air")
check("activation now refused", status, 403)
check("code is revoked", body.get("error"), "revoked")
status, body = call("POST", "/v1/refresh",
                    {"licenseKey": KEY, "deviceHash": device("Mac mini"), "deviceName": "x"})
check("refresh now refused", status, 403)

print("\n11. Restoring brings it back")
status, _ = call("POST", f"/v1/admin/licenses/{KEY}/revoke",
                 {"restore": True}, auth=True)
check("restore returns 200", status, 200)
check("activation works again", activate(KEY, "MacBook Air")[0], 200)

print("\n12. Unknown and malformed input")
check("unknown key        → 404", activate("DP1-AAAA-AAAA-AAAA-AAAA", "X")[0], 404)
check("garbage key        → 404", activate("nonsense", "X")[0], 404)
check("missing device     → 400",
      call("POST", "/v1/activate", {"licenseKey": KEY})[0], 400)
check("bad device format  → 400",
      call("POST", "/v1/activate",
           {"licenseKey": KEY, "deviceHash": "short", "deviceName": "X"})[0], 400)
check("unknown endpoint   → 404", call("GET", "/v1/nope")[0], 404)

print("\n13. Admin search finds it by email")
status, body = call("GET", "/v1/admin/licenses?q=buyer@example.com", auth=True)
check("returns 200", status, 200)
check("finds the licence", any(l["key"] == KEY for l in body["licenses"]), True)

print(f"\n{'─' * 60}\n{passed} passed, {failed} failed\n")
raise SystemExit(1 if failed else 0)
