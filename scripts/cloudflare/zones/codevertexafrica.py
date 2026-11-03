"""codevertexafrica.com: the platform's own zone (moved unchanged from populate-zone.py).

Mirrors the authoritative DNS as audited from the cloudoon nameservers on 2026-07-13, plus every
host and mail record added since. This module only DESCRIBES the zone; the sync rules (create
missing, correct mismatched content on records it owns, never delete, never touch proxied) live in
cflib/sync.py.
"""

from cflib.cluster import ORIGIN

ZONE_NAME = "codevertexafrica.com"
APEX = ZONE_NAME
TRUEHOST = "102.212.247.163"    # das112b.superfasthost01.cloud (legacy shared host)

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
    "maskani", "maskaniapp", "maskaniapi",
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
    # Inbound mail goes straight to Stalwart (decided 2026-10-20). The apex used to point at
    # Google Workspace, which has no mailbox for info@ or the Reply-To addresses, so replies
    # from Gmail, Zoho and Microsoft bounced. mx1 is DNS-only and must never be proxied.
    recs.append({"type": "MX", "name": "@", "content": f"mx1.{APEX}", "priority": 10})
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
    # MTA-STS (2026-10-20): Stalwart already serves the policy at
    # mta-sts.<apex>/.well-known/mta-sts.txt in testing mode (x:MtaSts). This record is what
    # tells sending servers to fetch it. Change the id whenever the policy changes, and move
    # the policy to enforce only after TLS-RPT reports show clean TLS delivery.
    recs.append({"type": "TXT", "name": "_mta-sts", "content": '"v=STSv1; id=20261020"'})
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
    "maskani", "maskaniapp", "maskaniapi",
    "projectsapi", "ticketing", "ticketingapi", "webmail",
]
PROXIED_CNAMES = ["mail"]

DNS_ONLY_PERMANENT = {"nats", "argocd"}
