#!/usr/bin/env python3
"""Set proxied=true (orange cloud) on the production web hosts.

Corrective/idempotent counterpart to populate-zone.py: that script's job is
the one-time grey-cloud MIRROR of the pre-cutover DNS (see docs/cloudflare-
cutover.md step 4) — re-running it re-asserts grey-cloud on every host it
manages, silently undoing step 7's "flip to Proxied (orange) ... all
remaining web hosts" once that's been done. This script re-applies step 7:
proxied=true on every host below. `nats` and `argocd` are excluded — the doc
requires those stay DNS-only (grey) permanently (non-HTTP / admin).

Usage:
    CF_API_TOKEN=<token> ./set-proxied.py <ZONE_ID>

Stdlib only (urllib) — no pip dependencies.
"""

import json
import os
import sys
import urllib.request

API = "https://api.cloudflare.com/client/v4"
APEX = "codevertexafrica.com"

# Every host populate-zone.py manages, MINUS nats/argocd (DNS-only permanently).
PROXIED_HOSTS = [
    "@", "www", "accounts", "sso", "pricing", "pricingapi",
    "pos", "posapi", "r", "inventory", "inventoryapi",
    "erp", "erpapi", "marketflow", "marketflowapi", "marketflowai",
    "logistics", "logisticsapi", "riderapp", "routing", "tiles",
    "ordering", "orderingapi", "notifications", "notificationsapi",
    "projects", "library", "libraryapi", "books", "booksapi",
    "truload", "truloadapi", "truload-docs", "docs",
    "ispbilling", "ispbillingapi",
    "afya", "afyaapi",
    "projectsapi", "ticketing", "ticketingapi", "webmail",
]
PROXIED_CNAMES = ["mail"]

DNS_ONLY_PERMANENT = {"nats", "argocd"}


def fqdn(name):
    return APEX if name == "@" else f"{name}.{APEX}"


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
    return out["result"]


def main():
    token = os.environ.get("CF_API_TOKEN", "")
    if not token or len(sys.argv) != 2:
        print("Usage: CF_API_TOKEN=<token> set-proxied.py <ZONE_ID>", file=sys.stderr)
        sys.exit(1)
    zone = sys.argv[1]

    existing = []
    page = 1
    while True:
        batch = api(token, "GET", f"/zones/{zone}/dns_records?per_page=100&page={page}")
        existing.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    print(f"zone has {len(existing)} existing records")

    wanted = [(h, "A") for h in PROXIED_HOSTS if h not in DNS_ONLY_PERMANENT] + \
             [(h, "CNAME") for h in PROXIED_CNAMES]

    updated = ok = skipped = 0
    for host, rtype in wanted:
        name = fqdn(host)
        matches = [r for r in existing if r["type"] == rtype and r["name"].lower() == name.lower()]
        if not matches:
            print(f"  ? {rtype} {name} not found — skipping")
            skipped += 1
            continue
        r = matches[0]
        if r.get("proxied", False):
            ok += 1
            continue
        api(token, "PUT", f"/zones/{zone}/dns_records/{r['id']}",
            {"type": r["type"], "name": name, "content": r["content"], "proxied": True,
             **({"priority": r["priority"]} if r.get("priority") is not None else {})})
        print(f"  ~ {rtype} {name}: proxied=false -> proxied=true")
        updated += 1

    print(f"done: {updated} flipped to proxied, {ok} already proxied, {skipped} not found")
    print(f"kept DNS-only (permanent, per docs/cloudflare-cutover.md): {sorted(DNS_ONLY_PERMANENT)}")


if __name__ == "__main__":
    main()
