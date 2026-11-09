"""The two sync operations, shared by every zone (moved from populate-zone.py and set-proxied.py).

sync_records: creates missing records and corrects mismatched content on records the zone module
owns. It never deletes anything and NEVER changes `proxied` on an existing record: a previous
version forced proxied back to false and silently reverted 43 to 44 production hostnames to
DNS-only, twice (memory `repo-visibility-private-migration-audit-2026-08-10.md`). New records are
created DNS-only.

set_proxied: sets proxied=true on the zone's listed web hosts, deliberately and separately.

Both take a mode: "plan" prints what would change and changes nothing; "apply" makes the change.
"""

from cflib.cloudflare import create_record, norm_txt, update_record

# SPF and DMARC are singular per name (a second v=spf1 or v=DMARC1 TXT record at the same name is
# a PermError for receivers), so they are corrected in place; other TXT values may coexist.
SINGULAR_TXT_PREFIXES = ("v=spf1", "v=dmarc1")


def _fqdn(apex, name):
    return apex if name == "@" else f"{name}.{apex}"


def sync_records(token, zone, existing, zmod, mode):
    """Brings the zone's owned records to zmod.desired_records(). Returns (created, updated, ok)."""
    apply = mode == "apply"
    apex, origin = zmod.APEX, zmod.ORIGIN
    if not origin:
        raise SystemExit("CF_ORIGIN_IP is not set; refusing to sync (records would point nowhere)")
    blank = [w["name"] for w in zmod.desired_records() if w["type"] in ("A", "AAAA") and not w["content"]]
    if blank:
        raise SystemExit(f"address records with no content: {blank}; set the matching CF_*_IP variable")
    created = updated = ok = 0
    for want in zmod.desired_records():
        name = _fqdn(apex, want["name"])
        matches = [r for r in existing if r["type"] == want["type"] and r["name"].lower() == name.lower()]

        if want["type"] == "TXT":
            if any(norm_txt(r["content"]) == norm_txt(want["content"]) for r in matches):
                ok += 1
                continue
            want_norm = norm_txt(want["content"]).lower()
            if want_norm.startswith(SINGULAR_TXT_PREFIXES):
                stale = [r for r in matches if norm_txt(r["content"]).lower().startswith(SINGULAR_TXT_PREFIXES)]
                if stale:
                    print(f"  ~ TXT {name}: {stale[0]['content'][:60]}... -> {want['content'][:60]}...")
                    if apply:
                        update_record(token, zone, stale[0]["id"], {**want, "name": name})
                    updated += 1
                    continue
            if apply and not create_record(token, zone, {**want, "name": name}):
                print(f"  = TXT {name} {want['content'][:50]}... (already exists, Cloudflare-confirmed)")
                ok += 1
            else:
                print(f"  + TXT {name} {want['content'][:50]}...")
                created += 1
            continue

        # A and CNAME are mutually exclusive per name: an existing record of either type at this
        # name is the occupant (the import scan often creates `www CNAME apex` where we write A).
        if want["type"] in ("A", "CNAME") and not matches:
            other = "CNAME" if want["type"] == "A" else "A"
            matches = [r for r in existing if r["type"] == other and r["name"].lower() == name.lower()]

        if not matches:
            if apply and not create_record(token, zone, {**want, "name": name}):
                print(f"  = {want['type']} {name} -> {want['content']} (already exists, Cloudflare-confirmed)")
                ok += 1
            else:
                print(f"  + {want['type']} {name} -> {want['content']}")
                created += 1
            continue

        r = matches[0]
        # A CNAME to the apex is equivalent to an A record at the origin (and the other way round);
        # keep the occupant's shape.
        equivalent = (
            r["content"].lower() == want["content"].lower()
            or (r["type"] == "CNAME" and r["content"].lower() == apex and want.get("content") == origin)
            or (r["type"] == "A" and r["content"] == origin and want["type"] == "CNAME" and want["content"].lower() == apex)
        )
        if equivalent:
            ok += 1
        else:
            print(f"  ~ {r['type']} {name}: {r['content']}(proxied={r.get('proxied')}) -> {want['type']} {want['content']}(proxied=false)")
            if apply:
                update_record(token, zone, r["id"], {**want, "name": name})
            updated += 1

    verb = "done" if apply else "plan (no changes made)"
    print(f"{verb}: {created} created, {updated} corrected, {ok} already right")
    print("NOTE: nothing is ever deleted; records beyond this list are left untouched. New records "
          "are DNS-only; existing records' proxied state is never modified here (use --action proxied).")
    return created, updated, ok


def set_proxied(token, zone, existing, zmod, mode):
    """Sets proxied=true on zmod.PROXIED_HOSTS (A) and PROXIED_CNAMES, skipping DNS_ONLY_PERMANENT."""
    apply = mode == "apply"
    apex = zmod.APEX
    keep_dns_only = getattr(zmod, "DNS_ONLY_PERMANENT", set())
    wanted = [(h, "A") for h in getattr(zmod, "PROXIED_HOSTS", []) if h not in keep_dns_only] + \
             [(h, "CNAME") for h in getattr(zmod, "PROXIED_CNAMES", [])]
    updated = ok = skipped = 0
    for host, rtype in wanted:
        name = _fqdn(apex, host)
        matches = [r for r in existing if r["type"] == rtype and r["name"].lower() == name.lower()]
        if not matches:
            print(f"  ? {rtype} {name} not found, skipping")
            skipped += 1
            continue
        r = matches[0]
        if r.get("proxied", False):
            ok += 1
            continue
        print(f"  ~ {rtype} {name}: proxied=false -> proxied=true")
        if apply:
            update_record(token, zone, r["id"],
                          {"type": r["type"], "name": name, "content": r["content"], "proxied": True,
                           **({"priority": r["priority"]} if r.get("priority") is not None else {})})
        updated += 1
    verb = "done" if apply else "plan (no changes made)"
    print(f"{verb}: {updated} to proxied, {ok} already proxied, {skipped} not found")
    print(f"kept DNS-only permanently: {sorted(keep_dns_only)}")
    return updated, ok, skipped
