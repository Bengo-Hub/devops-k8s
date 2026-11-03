"""The zone sync runner used by sync-zone.py.

The zone is resolved from the domain's own module by name and checked against Cloudflare, so one
domain's records can never be written into another zone.
"""

from cflib.cloudflare import list_records, resolve_zone, token_from_env
from cflib.sync import set_proxied, sync_records
from zones import ZONES


def run(domain, action="records", mode="plan"):
    zmod = ZONES.get(domain)
    if zmod is None:
        raise SystemExit(f"unknown zone {domain!r}; known: {', '.join(sorted(ZONES))}")
    if zmod.ZONE_NAME != domain or zmod.APEX != domain:
        raise SystemExit(f"zone module mismatch for {domain}")
    if not getattr(zmod, "MANAGES_MAIL", True):
        bad = [r for r in zmod.desired_records() if r["type"] in ("MX", "TXT")]
        if bad:
            raise SystemExit(f"{domain} must not manage mail records, found {len(bad)}")

    token = token_from_env()
    zone = resolve_zone(token, zmod.ZONE_NAME)
    existing = list_records(token, zone)
    print(f"zone {domain}: {len(existing)} records; action {action}; mode {mode}")

    if mode == "list":
        for r in sorted(existing, key=lambda r: (r["name"], r["type"])):
            extra = f" priority={r['priority']}" if r.get("priority") is not None else ""
            print(f"  {r['type']:6} {r['name']:40} {r['content'][:90]}{extra} proxied={r.get('proxied')}")
        return
    if action == "records":
        sync_records(token, zone, existing, zmod, mode)
    else:
        set_proxied(token, zone, existing, zmod, mode)
