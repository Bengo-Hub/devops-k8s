# CodeVertex WireGuard VPN overlay (`vpn` namespace)

Outbound WireGuard tunnel that lets the ISP-billing cloud backend reach NAT'd
MikroTik routers (direct RouterOS API + remote Winbox). Routers dial the server
outbound; each router keeps its **own** private key.

## Architecture

- **Server**: `wg0 = 10.8.0.1/16`, UDP `51820` exposed on the node via `hostPort`
  at `vpn.codevertexitsolutions.com:51820`. Runs in ns `vpn`, `NET_ADMIN` +
  `SYS_MODULE`, `/dev/net/tun`, `net.ipv4.ip_forward=1`.
- **Server keypair**: created **once** by `setup.sh` into Secret
  `vpn/wg-server-keys` (`privatekey`, `publickey`, `WG_PEER_SYNC_TOKEN`). The
  private key **never** leaves this Secret and is **not** in git.
- **Per-router peers (dynamic)**: the backend allocates a tunnel IP and hands the
  router the server pubkey + endpoint during bootstrap. RouterOS auto-generates
  the router's private key; the router POSTs its **public** key to
  `POST /api/v1/provisioning/bootstrap/wg-register`.
- **Reconcile loop** (in the WG pod): every 30s it `GET`s
  `/api/v1/vpn/peers` (auth: `WG_PEER_SYNC_TOKEN`) and converges `wg` peers +
  per-router Winbox DNAT (`vpn:<winbox_port> -> 10.8.0.<n>:8291`) via iptables.
  No kube-exec / API-server access required.

## First-time deploy

1. **DNS** (already done): `vpn.codevertexitsolutions.com A -> 77.237.232.66`.
2. **Open UDP 51820** to the node at the host firewall / cloud SG.
3. **Run setup** (idempotent — generates keys, syncs backend Secret):
   ```sh
   ./apps/wireguard/setup.sh
   kubectl -n isp-billing rollout restart deploy/isp-billing-backend
   ```
4. **Commit + let ArgoCD sync** the `wireguard` Application (this directory), OR
   `APPLY_MANIFESTS=true ./apps/wireguard/setup.sh`.
5. Bootstrap a router as usual — the bootstrap script now includes the WG block.

## Verify

```sh
kubectl -n vpn get pods
kubectl -n vpn exec deploy/wireguard -- wg show
kubectl -n vpn exec deploy/wireguard -- iptables -t nat -nL WG_WINBOX_DNAT
curl -H "Authorization: Bearer <WG_PEER_SYNC_TOKEN>" \
  https://ispbillingapi.codevertexitsolutions.com/api/v1/vpn/peers
```

## Notes / caveats

- **Single node**: `hostPort` UDP 51820 + `wg0` are node-singletons → `replicas: 1`,
  `strategy: Recreate`. Do not scale.
- **Backend→tunnel routing**: the backend pod reaches `10.8.0.0/16` via the node
  running the WG interface; on single-node k3s this works because the route to
  `10.8.0.0/16` is on the same node (the WG pod owns `wg0`). The reconcile loop
  MASQUERADEs return traffic onto `wg0`. Verify pod→`10.8.0.<n>:8728` reachability
  after the first router enrolls; if the backend pod is on a different node in a
  future multi-node setup, add a route / run WG as a DaemonSet on the API node.
- **Key rotation**: `setup.sh` never rotates the server key silently. To rotate,
  delete `vpn/wg-server-keys`, re-run setup, restart backend, and re-bootstrap
  every router (their peer to the old pubkey becomes invalid).
