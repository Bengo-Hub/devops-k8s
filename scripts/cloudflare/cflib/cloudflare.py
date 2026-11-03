"""Cloudflare API access shared by every zone script.

One HTTP helper, one paginated record listing and one zone lookup. The zone is always resolved
from the zone module's own name and checked against what Cloudflare returns, so a script can never
write one domain's records into another domain's zone (the zone id mix-up recorded in memory
`reference_cloudflare_zone_id_mixup.md`). The token is read from CF_API_TOKEN and never printed.
"""

import json
import os
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.cloudflare.com/client/v4"


def token_from_env():
    token = os.environ.get("CF_API_TOKEN", "")
    if not token:
        raise SystemExit("CF_API_TOKEN is not set")
    return token


def api(token, method, path, body=None):
    """Calls the API and returns the full response (result plus result_info)."""
    req = urllib.request.Request(
        f"{API}{path}",
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req) as resp:
            out = json.load(resp)
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:400]
        raise RuntimeError(f"{method} {path} -> HTTP {e.code}: {detail}") from None
    if not out.get("success"):
        raise RuntimeError(f"{method} {path}: {out.get('errors')}")
    return out


def resolve_zone(token, zone_name):
    """Returns the id of the zone named zone_name, or stops if the token cannot see exactly one."""
    zones = api(token, "GET", f"/zones?name={urllib.parse.quote(zone_name)}")["result"]
    if len(zones) != 1 or zones[0].get("name") != zone_name:
        raise SystemExit(f"zone {zone_name} not visible to this token (found {len(zones)})")
    return zones[0]["id"]


def list_records(token, zone):
    out, page = [], 1
    while True:
        res = api(token, "GET", f"/zones/{zone}/dns_records?per_page=100&page={page}")
        out.extend(res["result"])
        info = res.get("result_info") or {}
        if page >= int(info.get("total_pages") or 1):
            return out
        page += 1


def create_record(token, zone, body):
    """POSTs a record, treating Cloudflare's "identical record already exists" (81058) as a no-op.

    The scripts' own matching is advisory; Cloudflare's duplicate check is authoritative (seen live
    2026-08-18 on the codevertexafrica.com SPF record). Returns True when a record was created.
    """
    try:
        api(token, "POST", f"/zones/{zone}/dns_records", body)
        return True
    except RuntimeError as e:
        if "81058" in str(e):
            return False
        raise


def update_record(token, zone, record_id, body):
    api(token, "PUT", f"/zones/{zone}/dns_records/{record_id}", body)


def norm_txt(s):
    return s.strip().strip('"').replace(" ", "")
