# Mail ports, PROXY protocol and Stalwart's block list

Applies to the Stalwart mail server in the `email` namespace and the shared ingress-nginx.

## How mail traffic reaches Stalwart

ingress-nginx runs on the host network and forwards the raw TCP mail ports from the
`tcp-services` ConfigMap (`manifests/nats-tcp-services.yaml`) to `email/stalwart-mail`:
25, 465, 587, 993, 995 and 4190. It does not understand these protocols, so it only relays bytes.

## The problem this solves

Without extra information Stalwart sees every mail connection as coming from the node's own
public address. That breaks everything that depends on the sender address: SPF, reverse DNS
checks, DNSBL lookups and per-sender rate limits. It also made Stalwart's port-scan detector ban
the node address itself. Ingress and the kubelet probes share that address, so the ban cut off
the admin UI and produced the recurring 502 on `mail-admin.codevertexafrica.com` (2026-08-11,
2026-08-18 and 2026-08-20).

## The setup

- The six mail entries carry the `::PROXY` suffix, for example `"25": "email/stalwart-mail:25::PROXY"`.
  ingress-nginx then sends a PROXY protocol header with the real client address.
- Stalwart trusts the node address `77.237.232.66/32` for PROXY headers on the `smtp`,
  `submissions`, `imaps`, `pop3s` and `sieve` listeners (NetworkListener
  `overrideProxyTrustedNetworks`). The `http` and `https` listeners are not set up for it.
- Stalwart's allowed-IP list (`x:AllowedIp`) exempts the node address, the pod network
  `192.168.0.0/16` and the service network `10.96.0.0/12` from blocking.
- Clients inside the cluster (notifications-api, mail-ui, email-provisioner) connect straight to
  the Service and send no header. That works because their addresses are not in the trusted list.

## Order of changes matters

A trusted address that sends no header is refused. So:

1. Apply the `::PROXY` ConfigMap and the Stalwart trust setting together. Stalwart reads listener
   settings at start, so restart `statefulset/stalwart-mail` after changing trust.
2. If only one side is in place, mail ports fail until the other side is set. Verify right after.
3. Rollback: remove `::PROXY` from the file, `kubectl apply -f manifests/nats-tcp-services.yaml`,
   and clear `overrideProxyTrustedNetworks` on the listeners before restarting Stalwart.

The ConfigMap is applied with `kubectl apply` (see `scripts/infrastructure/configure-ingress-controller.sh`),
not by ArgoCD.

## Checks

- A test message from outside to `info@codevertexafrica.com` must show the sender's real address in
  its `Received` header and an `iprev` result for that address in `Authentication-Results`.
- `smtplib`, `imaplib` and an `openssl s_client` handshake against `mx1.codevertexafrica.com` on 25, 465
  and 993 must complete with a banner, not only a TLS handshake.

## If mail-admin returns 502 again

1. ingress-nginx logs show `recv() failed (104: Connection reset by peer)` from the Stalwart pod while
   `curl` inside the pod answers 200.
2. Query `x:BlockedIp/query` through the JMAP admin API. Any entry for the node address, the pod
   network or the service network is the cause.
3. Destroy the entry, make sure the allowed-IP entries above exist, and restart the StatefulSet.
