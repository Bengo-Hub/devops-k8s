Domains and API Gateway
-----------------------

Ingress
-------
The generic chart provisions an Ingress per app. For centralized API gateway (e.g., NGINX Ingress or Kong), point DNS to the gateway and let per-app Ingress rules handle routing via hostnames.

Domains
-------
- ERP API: `erpapi.masterspace.co.ke`
- ERP UI: `erp.masterspace.co.ke`

Headers/Timeouts
----------------
If you need custom annotations (CORS, timeouts, client body size), add them under `.metadata.annotations` in `templates/ingress.yaml` or expose extra annotations via values.


