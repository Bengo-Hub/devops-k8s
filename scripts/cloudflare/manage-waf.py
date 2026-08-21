#!/usr/bin/env python3
"""Enable Cloudflare's managed WAF rulesets for a zone, via the Rulesets API.

Closes the WAF/DDoS gap documented in shared-docs' internal gap-analysis
(2026-08-21 decision: Cloudflare's managed ruleset, not a self-hosted WAF).
Deploys whatever managed WAF ruleset(s) the zone's actual Cloudflare plan
provides (see MANAGED_RULESET_NAMES below — codevertexafrica.com is on the
Free plan, so this is "Cloudflare Managed Free Ruleset" only, not the
paid-tier "Cloudflare Managed Ruleset"/"OWASP Core Ruleset") onto the zone's
http_request_firewall_managed entry point.

SAFE TO RE-RUN, staged rollout by design:
  - Default mode is --mode log: every rule in the deployed ruleset(s) is
    forced (via an `overrides.action` on the deployed rule) to log-only, matching the
    runbook's "watch for false positives before blocking real traffic" step.
    In this mode NOTHING is ever blocked — it only produces entries under
    Security > Events in the dashboard.
  - --mode block removes the blanket log override, so each rule falls back to
    its own Cloudflare-assigned default action (typically block or
    managed_challenge, rule-by-rule) — run this only after the log-mode
    observation period in the runbook has passed clean.
  - Re-running in the same mode is a no-op if the ruleset is already deployed
    with that override state (the script checks before writing).

Does NOT touch DNS records, page rules, or anything set-proxied.py/
populate-zone.py manage — this only touches the WAF entry point ruleset.

Usage:
    CF_API_TOKEN=<token> ./manage-waf.py <ZONE_ID> --mode log
    CF_API_TOKEN=<token> ./manage-waf.py <ZONE_ID> --mode block

Stdlib only (urllib) — no pip dependencies.
"""

import json
import os
import sys
import urllib.request

API = "https://api.cloudflare.com/client/v4"
PHASE = "http_request_firewall_managed"

# Names as shown in the Cloudflare dashboard under Security > WAF > Managed
# rules — looked up by name via the account's ruleset list rather than a
# hardcoded ID, since account-scoped managed-ruleset IDs can differ from the
# commonly-cited "well-known" ones depending on plan/account provisioning.
#
# codevertexafrica.com is on Cloudflare's Free plan (confirmed live 2026-08-21
# via GET /zones/{zone}/rulesets, which only listed "Cloudflare Normalization
# Ruleset", "Cloudflare Managed Free Ruleset", and "DDoS L7 ruleset" — the
# paid-tier "Cloudflare Managed Ruleset" (full) and "Cloudflare OWASP Core
# Ruleset" this script originally targeted don't exist on this plan). Only
# the Free-tier managed ruleset is deployed here. Normalization and DDoS L7
# are Cloudflare-operated defaults already active regardless of plan/entry
# point config — not something this script needs to (or can) deploy.
MANAGED_RULESET_NAMES = [
    "Cloudflare Managed Free Ruleset",
]


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
        detail = e.read().decode(errors="replace")[:600]
        raise RuntimeError(f"{method} {path} -> HTTP {e.code}: {detail}") from None
    if not out.get("success"):
        raise RuntimeError(f"{method} {path}: {out.get('errors')}")
    return out["result"]


def find_managed_ruleset_ids(token, zone):
    """Look up the zone-visible managed rulesets by name (kind=managed). The bare
    /rulesets endpoint is account-scoped and needs an account ID this script doesn't
    have; /zones/{zone}/rulesets lists everything visible to the zone, including
    Cloudflare's own managed rulesets, without needing one."""
    all_rulesets = api(token, "GET", f"/zones/{zone}/rulesets")
    found = {}
    for rs in all_rulesets:
        if rs.get("kind") == "managed" and rs.get("name") in MANAGED_RULESET_NAMES:
            found[rs["name"]] = rs["id"]
    missing = [n for n in MANAGED_RULESET_NAMES if n not in found]
    if missing:
        raise RuntimeError(
            f"Could not find managed ruleset(s) by name: {missing}. "
            f"Available managed rulesets: "
            f"{[rs['name'] for rs in all_rulesets if rs.get('kind') == 'managed']}"
        )
    return found


def get_entrypoint(token, zone):
    """Current entry-point ruleset for this phase, or None if never deployed."""
    try:
        return api(token, "GET", f"/zones/{zone}/rulesets/phases/{PHASE}/entrypoint")
    except RuntimeError as e:
        if "HTTP 404" in str(e):
            return None
        raise


def desired_rules(ruleset_ids, mode):
    rules = []
    for name, rid in ruleset_ids.items():
        rule = {
            "action": "execute",
            "action_parameters": {"id": rid},
            "expression": "true",
            "description": f"Deploy {name} ({'log-only' if mode == 'log' else 'default actions'})",
            "enabled": True,
        }
        if mode == "log":
            # Force every rule inside the managed ruleset to log instead of its own
            # default action — the whole point of the log-then-block rollout.
            rule["action_parameters"]["overrides"] = {"action": "log"}
        rules.append(rule)
    return rules


def rules_already_match(existing_rules, wanted_rules):
    if len(existing_rules) != len(wanted_rules):
        return False
    for existing, wanted in zip(existing_rules, wanted_rules):
        if existing.get("action_parameters", {}).get("id") != wanted["action_parameters"]["id"]:
            return False
        existing_override = existing.get("action_parameters", {}).get("overrides", {}).get("action")
        wanted_override = wanted["action_parameters"].get("overrides", {}).get("action")
        if existing_override != wanted_override:
            return False
    return True


def main():
    token = os.environ.get("CF_API_TOKEN", "") or os.environ.get("CF_WAF_API_TOKEN", "")
    args = sys.argv[1:]
    mode = "log"
    if "--mode" in args:
        mode = args[args.index("--mode") + 1]
        del args[args.index("--mode"):args.index("--mode") + 2]
    if mode not in ("log", "block"):
        print(f"--mode must be 'log' or 'block', got: {mode}", file=sys.stderr)
        sys.exit(1)
    if not token or len(args) != 1:
        print("Usage: CF_API_TOKEN=<token> manage-waf.py <ZONE_ID> [--mode log|block]", file=sys.stderr)
        sys.exit(1)
    zone = args[0]

    print(f"looking up managed ruleset IDs...")
    ruleset_ids = find_managed_ruleset_ids(token, zone)
    for name, rid in ruleset_ids.items():
        print(f"  {name}: {rid}")

    wanted = desired_rules(ruleset_ids, mode)
    current = get_entrypoint(token, zone)

    if current is not None and rules_already_match(current.get("rules", []), wanted):
        print(f"entry point already deployed in --mode {mode} - no change needed")
        return

    result = api(token, "PUT", f"/zones/{zone}/rulesets/phases/{PHASE}/entrypoint", {"rules": wanted})
    print(f"deployed {len(result.get('rules', []))} rule(s) to the {PHASE} entry point, mode={mode}")
    if mode == "log":
        print("LOG MODE: nothing is being blocked yet. Watch Security > Events in the "
              "dashboard for false positives before re-running with --mode block. "
              "See shared-docs/internal/operations/cloudflare-waf-rollout.md.")
    else:
        print("BLOCK MODE: managed rulesets are now enforcing their default actions "
              "(block/managed_challenge per rule). To roll back instantly: re-run with "
              "--mode log, or delete the entry point ruleset via the dashboard.")


if __name__ == "__main__":
    main()
