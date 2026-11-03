#!/usr/bin/env python3
"""One entry point for every zone's DNS sync.

Usage:
    CF_API_TOKEN=<token> ./sync-zone.py <domain> [--action records|proxied] [--mode list|plan|apply]

  <domain>   a zone in zones/__init__.py (codevertexafrica.com, hadiafrica.com)
  --action   records (default): create missing records, correct mismatched owned content
             proxied: set proxied=true on the zone's PROXIED_HOSTS
  --mode     plan (default): print what would change, change nothing
             list: print every record in the zone
             apply: make the change

The zone is resolved from the domain's own module by name and checked against Cloudflare, so one
domain's records can never be written into another zone. Nothing is ever deleted.
"""

import argparse
import sys

from cflib.runner import run


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("domain")
    p.add_argument("--action", choices=["records", "proxied"], default="records")
    p.add_argument("--mode", choices=["list", "plan", "apply"], default="plan")
    a = p.parse_args()
    run(a.domain.strip().lower(), a.action, a.mode)


if __name__ == "__main__":
    sys.exit(main())
