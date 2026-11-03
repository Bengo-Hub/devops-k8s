"""hadiafrica.com: the Hadia Gifting Registry (client domain, zone in the same Cloudflare account).

Only the web hosts served by the cluster ingress are managed here. Mail is NOT managed: the zone's
MX (workplaceproemail.com and .net), SPF, the Private Email DKIM selector and DMARC belong to
Hadia's Namecheap Private Email and must stay as they are. When the @hadiafrica.com transactional
sender is set up (hadia-api docs, platform task N4), its SPF merge, DKIM selector and DMARC change
are added here deliberately, after the user approves the exact records.

Records are created DNS-only so cert-manager can issue TLS certificates; PROXIED_HOSTS is filled in
only after the certificates are issued and the user confirms the proxied flip.
"""

from cflib.cluster import ORIGIN

ZONE_NAME = "hadiafrica.com"
APEX = ZONE_NAME

# hadia-ui (apex, www), hadia-api (api) and the hadia-staging namespace (staging, api.staging).
WEB_HOSTS = ["@", "www", "api", "staging", "api.staging"]

# Guard read by sync-zone.py: this zone's records must never include MX or TXT.
MANAGES_MAIL = False


def desired_records():
    return [{"type": "A", "name": h, "content": ORIGIN, "proxied": False,
             "comment": "hadia (scripts/cloudflare/zones/hadiafrica.py)"} for h in WEB_HOSTS]


# Empty until TLS is issued for every host and the user confirms the flip.
PROXIED_HOSTS = []
PROXIED_CNAMES = []
DNS_ONLY_PERMANENT = set()
