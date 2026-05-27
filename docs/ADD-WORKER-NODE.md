# Add a Worker Node to mss-prod

Adds a second (or third, …) Contabo VPS as a Kubernetes worker, eliminating the single-node failure scenario where a master reboot takes down all workloads.

---

## Why this matters

The current cluster is a single node (`mss-prod-master`, 48 GB / 12 cores, `77.237.232.66`).
When that VPS reboots — planned maintenance, kernel update, or power cycle — every pod restarts simultaneously.
Some pods (e.g. `argocd-repo-server`) hit edge-case bugs during restart (stale init-container symlinks) and require manual intervention.

Adding even one worker node means:
- Workload pods can be scheduled on the worker; only kube-system / etcd stay on the master.
- A master reboot no longer drops ArgoCD, databases, or application traffic.
- The master's 48 GB RAM is freed from running application pods.

> **Note:** This does **not** make the control plane itself HA (that requires 3 masters + external etcd).
> It solves the most common outage: a single node restart disrupting all workloads.

---

## Prerequisites

| Requirement | Detail |
|---|---|
| New Contabo VPS | Ubuntu 24.04 LTS, minimum 8 GB RAM / 4 cores recommended |
| Root SSH access | To the new worker VPS |
| Root SSH access | To `mss-prod-master` (77.237.232.66) |
| Network reachability | Worker VPS must reach master on port **6443** |
| devops-k8s repo | Cloned on the new worker VPS (or copy the `scripts/cluster/` folder) |

---

## Step-by-step

### 1 — Provision a new Contabo VPS

Log in to the Contabo console and create a new VPS:
- **OS:** Ubuntu 24.04 LTS
- **Size:** Cloud VPS 20 NVMe or larger (8 GB RAM / 4 cores minimum)
- **Region:** EU 2 (same as master to minimise latency)
- Note the new VPS public IP — referred to as `<WORKER_IP>` below.

### 2 — Generate a join token on the master

SSH into `mss-prod-master` and run:

```bash
ssh root@77.237.232.66
cd /path/to/devops-k8s   # or wherever the repo is cloned
bash scripts/cluster/generate-join-token.sh
```

The script prints something like:

```
MASTER_IP=77.237.232.66
JOIN_TOKEN=abcdef.0123456789abcdef
CA_CERT_HASH=sha256:abc123...
```

Copy all three values — the token is valid for **24 hours**.

### 3 — Clone the repo on the worker VPS

```bash
ssh root@<WORKER_IP>
git clone https://github.com/YOUR_ORG/devops-k8s.git
cd devops-k8s
```

Or, if you only want to copy the scripts folder:

```bash
scp -r root@77.237.232.66:/path/to/devops-k8s/scripts/cluster/ /tmp/cluster-scripts/
```

### 4 — Run the worker setup script

```bash
export CLUSTER_NAME=mss-prod
export WORKER_NUMBER=1          # use 2, 3, … for subsequent workers
export MASTER_IP=77.237.232.66
export JOIN_TOKEN=<token from step 2>
export CA_CERT_HASH=sha256:<hash from step 2>

bash scripts/cluster/setup-worker-node.sh
```

The script:
1. Runs `setup-vps.sh` — sets hostname to `mss-prod-worker-1`, configures swap/kernel/sysctl/firewall (worker ports only: 22, 10250, 30000-32767)
2. Runs `setup-containerd.sh` — installs and configures containerd
3. Installs `kubelet` + `kubeadm` at v1.30, holds versions
4. Runs `kubeadm join` to register the node with the cluster

### 5 — Verify on the master

```bash
kubectl get nodes
```

Expected output (allow 1-2 minutes for Ready status):

```
NAME                STATUS   ROLES           AGE   VERSION
mss-prod-master     Ready    control-plane   Xd    v1.30.x
mss-prod-worker-1   Ready    <none>          2m    v1.30.x
```

---

## Move workloads off the master (optional but recommended)

Once the worker is Ready, re-taint the master so only system/infra pods run on it and all application pods migrate to workers:

```bash
# Add control-plane taint back
kubectl taint nodes mss-prod-master node-role.kubernetes.io/control-plane:NoSchedule

# Verify pods reschedule to the worker
kubectl get pods -A -o wide
```

> **ArgoCD and monitoring** run in `argocd` and `infra` namespaces. If you want them on the worker too, add a `tolerations: []` override or simply leave the master un-tainted — ArgoCD is low-resource.

---

## Adding a second worker

Repeat steps 1–5 with `WORKER_NUMBER=2`. The new node will be named `mss-prod-worker-2`.

---

## Removing a worker node

```bash
# Drain the node (reschedules all pods)
kubectl drain mss-prod-worker-1 --ignore-daemonsets --delete-emptydir-data

# Delete it from the cluster
kubectl delete node mss-prod-worker-1

# On the worker VPS itself, reset kubeadm state
ssh root@<WORKER_IP> "kubeadm reset -f && rm -rf /etc/kubernetes /var/lib/kubelet"
```

---

## Firewall reference

| Port | Master | Worker |
|---|---|---|
| 22/tcp | ✓ SSH | ✓ SSH |
| 80/tcp | ✓ HTTP (ingress) | – |
| 443/tcp | ✓ HTTPS (ingress) | – |
| 6443/tcp | ✓ Kubernetes API | – |
| 2379-2380/tcp | ✓ etcd | – |
| 10250/tcp | ✓ Kubelet | ✓ Kubelet |
| 10251/tcp | ✓ kube-scheduler | – |
| 10252/tcp | ✓ kube-controller | – |
| 30000-32767/tcp | – | ✓ NodePort |
