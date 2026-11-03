"""Cluster facts shared by every zone.

ORIGIN is the mss-prod ingress address that every cluster-hosted hostname points at. It is defined
here once; zone modules import it.
"""

ORIGIN = "77.237.232.66"        # mss-prod ingress
