# Cloudflare cutover — codevertexitsolutions.com

Goal: put Cloudflare's edge (Nairobi PoP) in front of all
`*.codevertexitsolutions.com` traffic to cut the ~150–200 ms Kenya↔Contabo
RTT out of TLS handshakes and static-asset loads. Origin: `77.237.232.66`.

## Cluster-side prep (done, 2026-07-13)

- `manifests/cert-manager-clusterissuer.yaml` — DNS-01 (Cloudflare) solver
  scoped to `codevertexitsolutions.com`; HTTP-01 fallback kept for
  masterspace.co.ke / kura.go.ke / theurbanloftcafe.com (not proxied).
  ACME contact: codevertexitsolutions@gmail.com.
  **Not applied until the API token exists** — activation is one command
  (below). HTTP-01 breaks behind the proxy because Cloudflare intercepts
  `/.well-known/acme-challenge`; that is why this must land with the cutover.
- `manifests/ingress-nginx-configmap.yaml` — trusts Cloudflare's published
  IP ranges and restores real client IPs from `CF-Connecting-IP`. Applied
  live in advance (inert for direct traffic).

## Cutover order (zero-downtime)

1. Cloudflare dashboard: add zone `codevertexitsolutions.com` (Free plan),
   import/verify all DNS records **DNS-only (grey cloud)**, including MX/TXT.
   Every web host is A → 77.237.232.66.
2. Registrar: switch nameservers from cloudoon → the two assigned Cloudflare
   nameservers. Grey-cloud records mean nothing changes for traffic. Wait for
   the zone to show **Active**.
3. Create an API token: My Profile → API Tokens → "Edit zone DNS" template,
   scoped to this zone only.
4. On the node: `./scripts/cloudflare/activate-dns01.sh <TOKEN>`
   (creates the cert-manager secret + applies the issuers).
5. Dashboard: SSL/TLS → **Full (strict)**.
6. Flip to **Proxied (orange)** gradually: `accounts` + `sso` first → verify
   SSO login end-to-end → then all remaining web hosts.
   **Keep `nats` and `argocd` DNS-only permanently** (non-HTTP / admin).
7. Speed: enable Brotli, HTTP/3, 0-RTT, Early Hints, Tiered Cache.
   Caching: cache rule for `/_next/static/*` + `*.js,*.css,*.woff2,*.svg,*.png`;
   bypass cache on `*api*` hostnames and HTML.

## Rollback

Flip records back to DNS-only (grey). Traffic goes direct again; HTTP-01
fallback still exists in the issuer, nothing else to undo.

## Notes

- Existing LE certs stay valid throughout; renewal has ~30 days of slack
  past each cert's `renewalTime`, so token/NS timing is not critical.
- Optional later: Argo Smart Routing (paid) to speed the cache-miss path;
  measure first. Other zones (masterspace.co.ke, theurbanloftcafe.com) can
  follow the same recipe with their own zone + selector entry.
