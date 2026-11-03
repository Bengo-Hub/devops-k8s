#!/usr/bin/env python3
"""Hadia (hadiafrica.com) DNS: list, plan or apply the web records for hadia-ui and hadia-api.

populate-zone.py is written for codevertexafrica.com only (fixed apex, host list, MX and TXT
records) and must never run against another zone. This script is the hadiafrica.com counterpart.

Safety rules:
- The zone is looked up by NAME through the API and must be hadiafrica.com. A zone id or any
  other name passed in is resolved and checked; anything else stops the run.
- It never deletes or modifies a record. It never creates, edits or deletes MX or TXT records,
  so the Namecheap Private Email mail setup (MX, SPF, DKIM, DMARC) is untouched.
- `apply` only creates the missing web A records below, DNS-only (proxied=false) so cert-manager
  can issue the TLS certificates; the proxied flip is a separate, later step. A host that already
  exists with other content is reported as a conflict and left alone.
- The token is read from CF_API_TOKEN and never printed.

Modes (CF_MODE, default plan):
  list   print every record in the zone (public DNS data)
  plan   print what apply would create, and any conflicts
  apply  create the missing records

Usage:
  CF_API_TOKEN=<token> CF_MODE=plan ./hadia-zone.py hadiafrica.com
"""

import importlib.util
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.cloudflare.com/client/v4"
ZONE_NAME = "hadiafrica.com"

# The ingress origin is defined once, in populate-zone.py; reuse it rather than copy it.
_spec = importlib.util.spec_from_file_location(
    "populate_zone", os.path.join(os.path.dirname(os.path.abspath(__file__)), "populate-zone.py"))
_pz = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_pz)
ORIGIN = _pz.ORIGIN

# Hosts served by the cluster ingress: hadia-ui (apex, www), hadia-api (api) and staging.
WEB_HOSTS = ["@", "www", "api", "staging", "api.staging"]


def api(token, method, path, body=None):
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


def resolve_zone(token, arg):
    """Returns the hadiafrica.com zone id, whatever was passed (name or id), or stops."""
    if arg == ZONE_NAME:
        zones = api(token, "GET", f"/zones?name={urllib.parse.quote(ZONE_NAME)}")["result"]
        if len(zones) != 1:
            raise SystemExit(f"zone {ZONE_NAME} not visible to this token (found {len(zones)})")
        return zones[0]["id"]
    zone = api(token, "GET", f"/zones/{urllib.parse.quote(arg)}")["result"]
    if zone.get("name") != ZONE_NAME:
        raise SystemExit(f"refusing: zone {arg} is {zone.get('name')!r}, not {ZONE_NAME}")
    return zone["id"]


def all_records(token, zone):
    out, page = [], 1
    while True:
        res = api(token, "GET", f"/zones/{zone}/dns_records?per_page=100&page={page}")
        out.extend(res["result"])
        info = res.get("result_info") or {}
        if page >= int(info.get("total_pages") or 1):
            return out
        page += 1


def fqdn(name):
    return ZONE_NAME if name == "@" else f"{name}.{ZONE_NAME}"


def main():
    token = os.environ.get("CF_API_TOKEN", "")
    mode = (os.environ.get("CF_MODE") or "plan").strip().lower()
    if not token or len(sys.argv) != 2 or mode not in ("list", "plan", "apply"):
        print("Usage: CF_API_TOKEN=<token> CF_MODE=list|plan|apply hadia-zone.py hadiafrica.com", file=sys.stderr)
        sys.exit(2)

    zone = resolve_zone(token, sys.argv[1].strip())
    records = all_records(token, zone)
    print(f"zone {ZONE_NAME} ({len(records)} records), mode {mode}")

    if mode == "list":
        for r in sorted(records, key=lambda r: (r["name"], r["type"])):
            extra = f" priority={r['priority']}" if r.get("priority") is not None else ""
            print(f"  {r['type']:6} {r['name']:40} {r['content'][:90]}{extra} proxied={r.get('proxied')}")
        return

    by_name = {}
    for r in records:
        by_name.setdefault(r["name"], []).append(r)

    to_create, conflicts, present = [], [], []
    for host in WEB_HOSTS:
        name = fqdn(host)
        existing = [r for r in by_name.get(name, []) if r["type"] in ("A", "AAAA", "CNAME")]
        if not existing:
            to_create.append(name)
        elif any(r["type"] == "A" and r["content"] == ORIGIN for r in existing):
            present.append(name)
        else:
            conflicts.append((name, [(r["type"], r["content"]) for r in existing]))

    for name in present:
        print(f"  ok        A {name} already points at the ingress")
    for name, found in conflicts:
        print(f"  CONFLICT  {name} has {found}; left unchanged, needs a decision")
    for name in to_create:
        print(f"  {'create' if mode == 'apply' else 'would add'}  A {name} -> ingress origin, DNS-only")

    if mode == "plan":
        print(f"plan: {len(to_create)} to add, {len(present)} already right, {len(conflicts)} conflicts; no changes made")
        return

    created = 0
    for name in to_create:
        body = {"type": "A", "name": name, "content": ORIGIN, "proxied": False, "ttl": 1,
                "comment": "hadia (hadia-zone.py)"}
        try:
            api(token, "POST", f"/zones/{zone}/dns_records", body)
            created += 1
        except RuntimeError as e:
            if "81058" in str(e):  # identical record already exists
                continue
            raise
    print(f"apply: created {created}, already right {len(present)}, conflicts {len(conflicts)}")


if __name__ == "__main__":
    main()
