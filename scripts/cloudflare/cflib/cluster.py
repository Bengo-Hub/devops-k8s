"""Cluster facts shared by every zone.

ORIGIN is the mss-prod ingress address that every cluster-hosted hostname points at. It is defined
here once; zone modules import it.
"""

import os

# The address is kept out of this public repo: set CF_ORIGIN_IP (a repo secret in the
# cloudflare-sync-dns workflow). sync_records refuses to run without it.
ORIGIN = os.environ.get("CF_ORIGIN_IP", "").strip()        # mss-prod ingress
