#!/usr/bin/env python3
"""Populate the Cloudflare zone for codevertexafrica.com.

Mirrors the authoritative DNS as audited from the cloudoon nameservers on
2026-07-13, so the registrar nameserver flip is a no-op for traffic. Merge
semantics: creates missing records, corrects mismatched content on records
it owns, and never deletes anything Cloudflare's import scan already added.
New records are created DNS-only (proxied=false); orange-clouding happens
via set-proxied.py, separately.

SAFE TO RE-RUN: as of 2026-08-17 this script never modifies the `proxied`
flag on an existing, content-correct record — only content (A/CNAME/TXT
values) is corrected. If it also forced `proxied=false` back onto every
already-proxied record, it would silently undo set-proxied.py's cutover
on every re-run — this happened twice (2026-08-10, 2026-08-17) before the
proxied-touching code was removed. If you're re-adding that behavior for
some reason, don't — run set-proxied.py instead, deliberately, afterward.

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
APEX = "codevertexafrica.com"

# Hosts served by the k8s ingress (A -> origin, DNS-only).
ORIGIN_HOSTS = [
    "@", "www", "accounts", "sso", "pricing", "pricingapi",
    "pos", "posapi", "r", "inventory", "inventoryapi",
    "erp", "erpapi", "marketflow", "marketflowapi", "marketflowai",
    "logistics", "logisticsapi", "riderapp", "routing", "tiles",
    "ordering", "orderingapi", "notifications", "notificationsapi",
    "projects", "library", "libraryapi", "books", "booksapi",
    "truload", "truloadapi", "truload-docs", "docs",
    "ispbilling", "ispbillingapi",
    "afya", "afyaapi",
    "argocd", "nats",  # keep DNS-only permanently (admin / non-HTTP)
    # Email hosting platform (Stalwart), added 2026-08-10 — see
    # .claude/plans/codevertex-email-hosting-service-plan.md Part 5/12.1.
    # mx1 must stay unproxied permanently (MX target, TLS cert CN, PTR).
    "mx1", "mail-admin", "mta-sts", "autoconfig", "autodiscover",
    # `webmail` repointed to the cluster 2026-08-18 — the real mail-ui
    # frontend (apps/mail-ui/) is deployed, Healthy, and is the sole owner
    # of this hostname's Ingress (stalwart-mail's own Ingress had this host
    # removed the same day to avoid an nginx conflict). The root-cause fix
    # for the incident that motivated waiting for a "billing cycle with no
    # incidents" (Stalwart's own week-long self-inflicted port-scan ban) has
    # been confirmed live and stable since; no longer worth deferring this.
    "webmail",
]

# Mirrored as-is from cloudoon: these currently point at the Truehost shared
# host, NOT the cluster (that's also why the k8s projects-api/ticketing-api
# certs have been stuck since Dec). Repointing them to ORIGIN is a separate,
# deliberate decision — flip the constant below when approved.
TRUEHOST_HOSTS_LEGACY_APPS = ["projectsapi", "ticketing", "ticketingapi"]

def desired_records():
    recs = []
    for h in ORIGIN_HOSTS:
        recs.append({"type": "A", "name": h, "content": ORIGIN, "proxied": False})
    for h in TRUEHOST_HOSTS_LEGACY_APPS:
        recs.append({"type": "A", "name": h, "content": TRUEHOST, "proxied": False})
    recs.append({"type": "CNAME", "name": "mail", "content": APEX, "proxied": False})
    # smtp/imap are client-facing aliases for the MX target, not the apex —
    # separate from the generic ORIGIN_HOSTS A-record shape above.
    recs.append({"type": "CNAME", "name": "smtp", "content": f"mx1.{APEX}", "proxied": False})
    recs.append({"type": "CNAME", "name": "imap", "content": f"mx1.{APEX}", "proxied": False})
    recs.append({"type": "MX", "name": "@", "content": "smtp.google.com", "priority": 1})
    # Day-0 deliverability fix (2026-08-10, plan Part 0): the previous SPF had
    # no Google include (Google Workspace's real sending IPs were never
    # authorized -> outbound mail failed SPF) and `+a` also authorized
    # Cloudflare's shared proxy IPs to send as this domain (removed). This is
    # a CORRECTION (see the spf/dmarc special-case in main()'s matching loop
    # below), not an addition — the old content must not be left in place
    # alongside this one, or SPF becomes a PermError with two v=spf1 records.
    #
    # Second correction (2026-08-17): notifications-api's platform SMTP
    # provider is being flipped from the dead Zoho account to Stalwart's
    # no-reply@ mailbox, which sends from ORIGIN (mx1's IP) — not covered by
    # either existing include, so those sends were failing SPF (DMARC would
    # still pass via DKIM alignment alone, since Stalwart's DKIM keys are
    # published, but this closes the gap properly rather than relying on
    # DKIM-only alignment).
    recs.append({"type": "TXT", "name": "@",
                 "content": f'"v=spf1 include:_spf.google.com include:_spf.truehostcloud.com ip4:{ORIGIN} ~all"'})
    recs.append({"type": "TXT", "name": "@",
                 "content": '"google-site-verification=s4W45Bi7hV_ouhQCPgu3yCBzVpWOnM8zOuk_atvE2B4"'})
    # Day-0 fix continued: reports now come to us (not Truehost, which nobody
    # reads), relaxed SPF alignment (aspf=r — strict alignment breaks
    # subdomain/relay sending for no real benefit), forensic reports (ruf=)
    # dropped (full message content to a third party is a real DPA/GDPR
    # exposure and almost nobody honors ruf= anyway).
    recs.append({"type": "TXT", "name": "_dmarc",
                 "content": '"v=DMARC1; p=quarantine; sp=quarantine; adkim=r; aspf=r; pct=100; fo=1; '
                            'ri=86400; rua=mailto:dmarc@codevertexafrica.com"'})
    # TLS-RPT (Part 5) — read-only reporting, safe to add anytime, no
    # dependency on Stalwart or MTA-STS enforcement being live.
    recs.append({"type": "TXT", "name": "_smtp._tls",
                 "content": '"v=TLSRPTv1; rua=mailto:tlsrpt@codevertexafrica.com"'})
    # DKIM (added 2026-08-11, plan Part 13.1/saga log) — Stalwart's own
    # automatic DKIM management generates dated selectors (not the
    # originally-planned static `cvx2026a`) and rotates them over time;
    # pulled verbatim from the live `x:Domain/get` dnsZoneFile via the JMAP
    # admin API. Deliberately NOT pulling that same zone file's SPF/MX/DMARC/
    # mta-sts suggestions here — those assume Stalwart is the sole mail
    # system for the apex, which contradicts the deliberate "don't touch the
    # apex MX" decision (Part 4). Only the DKIM keys are safe/correct to take
    # as-is. Re-run this block whenever Stalwart rotates to a new selector.
    recs.append({"type": "TXT", "name": "v1-ed25519-20260811._domainkey",
                 "content": '"v=DKIM1; k=ed25519; h=sha256; '
                            'p=Pi92OsUg1xTi03Vg7EscBYl/D0ikAiyl0osV4svuxAU="'})
    recs.append({"type": "TXT", "name": "v1-rsa-20260811._domainkey",
                 "content": '"v=DKIM1; k=rsa; h=sha256; '
                            'p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA3BIkxGMv3YYDQPKM1+FgGMhlaDxDbDa7'
                            'jT7FElafFv7n+Nx9rN5MYHraUA0QgJqDgO3n0NW2Pv+Ir+ReGSt7BUpYEEaz1tCY2/Q/21vSorGNWr'
                            'Ikifir2TZJOikpg1C+XHhBF+ZumbqvmaSD+mEf0SFW7sgfqhXFf/UFqMr4qSm0+Yw2uajoOThrmI7'
                            'vOXovZNgcO+dBjfdIcCyGcTXg/Yi7z9GeotFh1S0Zrbp9RcPo0adS4k3nuANOQrGbFRWla3u0dXih'
                            'PPcmdxphvUfJFEuZlTe4GVIM6WueVaMlitA6Jm6kSYhrWVDYI2pmfa8GuUeXs/41N28WGi2ydSWLK'
                            'wIDAQAB"'})
    # Google Workspace DKIM (added 2026-08-18), separate signing path from
    # Stalwart's own selectors above — this one covers mail actually sent
    # through Gmail's servers (e.g. info@ once dual-delivery routing is set
    # up per the shared-docs runbook), fixed selector name "google" (Workspace
    # doesn't rotate it the way Stalwart's own automatic DKIM does).
    recs.append({"type": "TXT", "name": "google._domainkey",
                 "content": '"v=DKIM1;k=rsa;p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxbt8PRZ7coRRDUyaRJestkKw'
                            '4IPrS5BgnFmYHDWU322SBbU5nv81m/fCZkd/cGLi/hwVihbXJekJMcFrRv7ksXTf+MWrmMg5WmTK9bpOAdo1'
                            'BrcP0D9GGSH8mt3CgwCdrVrLtbRayzG8TmyYoYFd3FbFLnsCV1gJqK724DVZTVdHU6fMmmp/aqm6Fbn2jcyP'
                            'ON9Za/sFMY/rIkSSJd2jTNCZhnNqfYGAPlxBQopj8NQ89WYh8KGow1zEbgpZFD5VB97z+nT6G0fDkp5aIOtX'
                            'NrbjLjGF3Vju14SloDodMskI1RDp+a9xUxX1s/xjV1Yuy0496aZaS8n3vpAecD5EsQIDAQAB"'})
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
    try:
        with urllib.request.urlopen(req) as resp:
            out = json.load(resp)
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:400]
        raise RuntimeError(f"{method} {path} -> HTTP {e.code}: {detail}") from None
    if not out.get("success"):
        raise RuntimeError(f"{method} {path}: {out.get('errors')}")
    return out["result"]

def norm_txt(s):
    return s.strip().strip('"').replace(" ", "")

def create_record(token, zone, body):
    """POST a new record, treating Cloudflare's "identical record already
    exists" (code 81058) as an idempotent no-op instead of a fatal crash.

    Found 2026-08-18: this script's own dedup checks (norm_txt equality,
    the singular-TXT stale lookup) can disagree with Cloudflare's own
    stricter duplicate detection at the API layer — hit live for the
    apex SPF record despite it already being correct and despite the
    "already right" check above having run first. Rather than chase the
    exact matching-logic gap (this script's dedup is advisory; Cloudflare's
    own rejection is authoritative), just trust the API's answer: "already
    exists" means the desired state is already achieved, so treat it as
    success. Re-raises any other error unchanged.
    """
    try:
        return api(token, "POST", f"/zones/{zone}/dns_records", body), True
    except RuntimeError as e:
        if "81058" in str(e):
            return None, False
        raise

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
            if any(norm_txt(r["content"]) == norm_txt(want["content"]) for r in matches):
                ok += 1
                continue

            # SPF and DMARC are singular-per-name by RFC (a second v=spf1 or
            # v=DMARC1 TXT record at the same name is a PermError for
            # receivers) — correct the existing one in place instead of the
            # generic "TXT allows multiple values, just add another" path
            # every other TXT record here uses (google-site-verification etc.
            # genuinely can have several unrelated values, so this must stay
            # opt-in per-prefix, not the default).
            singular_prefixes = ("v=spf1", "v=dmarc1")
            want_norm = norm_txt(want["content"]).lower()
            is_singular = want_norm.startswith(singular_prefixes)
            if is_singular:
                stale = [r for r in matches if norm_txt(r["content"]).lower().startswith(singular_prefixes)]
                if stale:
                    api(token, "PUT", f"/zones/{zone}/dns_records/{stale[0]['id']}",
                        {**want, "name": name})
                    print(f"  ~ TXT {name}: {stale[0]['content'][:60]}... -> {want['content'][:60]}...")
                    updated += 1
                    continue

            _, was_created = create_record(token, zone, {**want, "name": name})
            if was_created:
                print(f"  + TXT {name} {want['content'][:50]}...")
                created += 1
            else:
                print(f"  = TXT {name} {want['content'][:50]}... (already exists, Cloudflare-confirmed)")
                ok += 1
            continue

        # A and CNAME are mutually exclusive per name: treat an existing record
        # of either type at this name as the occupant (the import scan often
        # creates e.g. `www CNAME apex` where we'd write an A record).
        if want["type"] in ("A", "CNAME") and not matches:
            other = "CNAME" if want["type"] == "A" else "A"
            matches = [r for r in existing if r["type"] == other and r["name"].lower() == name.lower()]

        if not matches:
            _, was_created = create_record(token, zone, {**want, "name": name})
            if was_created:
                print(f"  + {want['type']} {name} -> {want['content']}")
                created += 1
            else:
                print(f"  = {want['type']} {name} -> {want['content']} (already exists, Cloudflare-confirmed)")
                ok += 1
            continue

        r = matches[0]
        # A CNAME to the apex is functionally identical to an A record at the
        # origin (and vice versa) — keep the occupant's shape.
        equivalent = (
            r["content"].lower() == want["content"].lower()
            or (r["type"] == "CNAME" and r["content"].lower() == APEX and want.get("content") == ORIGIN)
            or (r["type"] == "A" and r["content"] == ORIGIN and want["type"] == "CNAME" and want["content"].lower() == APEX)
        )
        # Deliberately NEVER touches `proxied` on an existing/equivalent record
        # (fixed 2026-08-17, second occurrence of the same incident — see
        # repo-visibility-private-migration-audit-2026-08-10.md /
        # project_email_hosting_stalwart.md memory). This script's job is
        # content correctness only; live proxied state is `set-proxied.py`'s
        # job and reflects a real, separately-decided cutover state that this
        # script has no way to know about. A prior version forced proxied
        # back to false here whenever a record was already correct-but-proxied,
        # which silently reverted 43-44 production hostnames from orange-cloud
        # to grey-cloud on every re-run — twice.
        if equivalent:
            ok += 1
        else:
            api(token, "PUT", f"/zones/{zone}/dns_records/{r['id']}",
                {**want, "name": name})
            print(f"  ~ {r['type']} {name}: {r['content']}(proxied={r.get('proxied')}) -> {want['type']} {want['content']}(proxied=false)")
            updated += 1

    print(f"done: {created} created, {updated} corrected, {ok} already right")
    print("NOTE: nothing was deleted; records the import scan added beyond this "
          "list were left untouched. New records are created DNS-only (grey); "
          "existing records' proxied state is never modified here — that's "
          "set-proxied.py's job. Run that afterward if hosts need to be re-cloud.")

if __name__ == "__main__":
    main()
