Certificates and Domains
------------------------

We assume cert-manager with a ClusterIssuer `letsencrypt-prod` is installed in the cluster. The chart templates set annotations for cert-manager and expect per-app TLS secrets names in values.

DNS
---
Point `erpapi.masterspace.co.ke` and `erp.masterspace.co.ke` to your ingress controller load balancer.

TLS
---
The ingress template references:
- erpapi: secret `erpapi-masterspace-tls`
- erp-ui: secret `erp-masterspace-tls`
cert-manager provisions them automatically when Ingress is created.


