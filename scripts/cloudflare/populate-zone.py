#!/usr/bin/env python3
"""Populate the Cloudflare zone for codevertexitsolutions.com.

Mirrors the authoritative DNS as audited from the cloudoon nameservers on
2026-07-13, so the registrar nameserver flip is a no-op for traffic. Merge
semantics: creates missing records, corrects mismatched content on records
it owns, and never deletes anything Cloudflare's import scan already added.
Every record is created DNS-only (proxied=false); orange-clouding happens
manually, host by host, after the cutover is approved.

Usage:
    CF_API_TOKEN=<token> ./populate-zone.py <ZONE_ID>

Stdlib only (urllib) — no pip dependencies; runs on the node as-is.
"""

import json
import os
import sys
import urllib.request

API = "https://api.cloudflare.com/client/v4"

ORIGIN = "77.237.232.66"        # mss-prod ingress
TRUEHOST = "102.212.247.163"    # das112b.superfasthost01.cloud (legacy shared host)
APEX = "codevertexitsolutions.com"

# Hosts served by the k8s ingress (A -> origin, DNS-only).
ORIGIN_HOSTS = [
    "@", "www", "accounts", "sso", "pricing", "pricingapi",
    "pos", "posapi", "inventory", "inventoryapi",
    "erp", "erpapi", "marketflow", "marketflowapi", "marketflowai",
    "logistics", "logisticsapi", "riderapp", "routing", "tiles",
    "ordersapp", "orderingapi", "notifications", "notificationsapi",
    "projects", "library", "libraryapi", "books", "booksapi",
    "truload", "truloadapi", "truload-docs",
    "ispbilling", "ispbillingapi",
    "argocd", "nats",  # keep DNS-only permanently (admin / non-HTTP)
]

# Mirrored as-is from cloudoon: these currently point at the Truehost shared
# host, NOT the cluster (that's also why the k8s projects-api/ticketing-api
# certs have been stuck since Dec). Repointing them to ORIGIN is a separate,
# deliberate decision — flip the constant below when approved.
TRUEHOST_HOSTS = ["projectsapi", "ticketing", "ticketingapi", "webmail"]

def desired_records():
    recs = []
    for h in ORIGIN_HOSTS:
        recs.append({"type": "A", "name": h, "content": ORIGIN, "proxied": False})
    for h in TRUEHOST_HOSTS:
        recs.append({"type": "A", "name": h, "content": TRUEHOST, "proxied": False})
    recs.append({"type": "CNAME", "name": "mail", "content": APEX, "proxied": False})
    recs.append({"type": "MX", "name": "@", "content": "smtp.google.com", "priority": 1})
    recs.append({"type": "TXT", "name": "@",
                 "content": '"v=spf1 +a +mx include:_spf.truehostcloud.com ~all"'})
    recs.append({"type": "TXT", "name": "@",
                 "content": '"google-site-verification=s4W45Bi7hV_ouhQCPgu3yCBzVpWOnM8zOuk_atvE2B4"'})
    recs.append({"type": "TXT", "name": "_dmarc",
                 "content": '"v=DMARC1;p=quarantine;sp=quarantine;adkim=r;aspf=s;pct=100;fo=0;rf=afrf;ri=86400;'
                            'rua=mailto:dmarc-reports@truehostcloud.com;ruf=mailto:dmarc-reports@truehostcloud.com"'})
    return recs

def fqdn(name):
    return APEX if name == "@" else f"{name}.{APEX}"

def api(token, method, path, body=None):
    req = urllib.request.Request(
        f"{API}{path}",
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req) as resp:
        out = json.load(resp)
    if not out.get("success"):
        raise RuntimeError(f"{method} {path}: {out.get('errors')}")
    return out["result"]

def norm_txt(s):
    return s.strip().strip('"').replace(" ", "")

def main():
    token = os.environ.get("CF_API_TOKEN", "")
    if not token or len(sys.argv) != 2:
        print("Usage: CF_API_TOKEN=<token> populate-zone.py <ZONE_ID>", file=sys.stderr)
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
    print(f"zone has {len(existing)} existing records (import scan)")

    created = updated = ok = 0
    for want in desired_records():
        name = fqdn(want["name"])
        matches = [r for r in existing if r["type"] == want["type"] and r["name"].lower() == name.lower()]

        if want["type"] == "TXT":
            # TXT allows multiple values per name — match on content, create if absent.
            if any(norm_txt(r["content"]) == norm_txt(want["content"]) for r in matches):
                ok += 1
                continue
            api(token, "POST", f"/zones/{zone}/dns_records",
                {**want, "name": name})
            print(f"  + TXT {name} {want['content'][:50]}...")
            created += 1
            continue

        if not matches:
            api(token, "POST", f"/zones/{zone}/dns_records", {**want, "name": name})
            print(f"  + {want['type']} {name} -> {want['content']}")
            created += 1
        else:
            r = matches[0]
            same = r["content"].lower() == want["content"].lower()
            unproxied = not r.get("proxied", False)
            if same and unproxied:
                ok += 1
            else:
                api(token, "PUT", f"/zones/{zone}/dns_records/{r['id']}",
                    {**want, "name": name})
                print(f"  ~ {want['type']} {name}: {r['content']}(proxied={r.get('proxied')}) -> {want['content']}(proxied=false)")
                updated += 1

    print(f"done: {created} created, {updated} corrected, {ok} already right")
    print("NOTE: nothing was deleted; records the import scan added beyond this "
          "list were left untouched. All records are DNS-only (grey) — no traffic "
          "change until the registrar NS flip + manual orange-clouding.")

if __name__ == "__main__":
    main()
