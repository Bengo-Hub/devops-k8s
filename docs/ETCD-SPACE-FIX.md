# Fixing etcd Database Space Exceeded Issue

## Problem

Error: `etcdserver: mvcc: database space exceeded`

This means the Kubernetes etcd database has run out of space and cannot accept new writes.

## Symptoms

- Cannot create new pods, services, or any Kubernetes resources
- Deployments fail with "database space exceeded" error
- Helm installations fail immediately
- Cluster appears unhealthy

## Root Causes

1. **Accumulated History**: etcd keeps revision history that grows over time
2. **Failed Deployments**: Many failed deployments create orphaned objects
3. **No Automatic Compaction**: etcd not configured to auto-compact
4. **Small Disk**: etcd disk allocation too small
5. **Too Many Objects**: Cluster has too many resources

## Quick Fix (Automated)

Run the automated fix script:

```bash
cd devops-k8s
./scripts/fix-etcd-space.sh
```

This script will:
1. Find the etcd pod
2. Compact etcd history
3. Defragment etcd database
4. Disarm space alarms
5. Verify recovery

## Manual Fix (If Script Fails)

### Step 1: SSH to Your Kubernetes Master Node

```bash
ssh user@your-k8s-master-node
```

### Step 2: Check etcd Status

```bash
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --write-out=table
```

You'll see output like:
```
+------------------+------------------+---------+---------+-----------+------------+
|    ENDPOINT      |       ID         | VERSION | DB SIZE |  LEADER   | RAFT TERM  |
+------------------+------------------+---------+---------+-----------+------------+
| 127.0.0.1:2379   | 8e9e05c52164694d |  3.5.0  | 2.1 GB  | true      |         2  |
+------------------+------------------+---------+---------+-----------+------------+
```

Note the **revision** number (not shown in table, but captured below).

### Step 3: Get Current Revision

```bash
REV=$(ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --write-out=json | jq '.[0].Status.header.revision')

echo "Current revision: $REV"
```

### Step 4: Compact etcd

```bash
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  compact $REV
```

**Expected output:** `compacted revision <number>`

### Step 5: Defragment etcd

```bash
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  defrag --cluster
```

**Expected output:** `Finished defragmenting etcd member`

This will reclaim space immediately.

### Step 6: Disarm Space Alarms

```bash
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  alarm disarm
```

### Step 7: Verify Recovery

```bash
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --write-out=table
```

DB SIZE should be significantly smaller now.

## Verification

After fixing, verify cluster is healthy:

```bash
# Check nodes
kubectl get nodes

# Check if you can create resources
kubectl run test-pod --image=nginx --restart=Never
kubectl delete pod test-pod

# Check for Pending pods
kubectl get pods -A | grep Pending
```

## Long-Term Prevention

### 1. Enable Automatic Compaction

Add to etcd configuration (`/etc/kubernetes/manifests/etcd.yaml`):

```yaml
spec:
  containers:
  - command:
    - etcd
    - --auto-compaction-retention=1h  # Compact hourly
    - --quota-backend-bytes=8589934592  # 8GB quota
```

### 2. Schedule Regular Maintenance

Add this to your cron (run weekly):

```bash
# /etc/cron.weekly/etcd-compact.sh
#!/bin/bash
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  compact $(etcdctl endpoint status --write-out=json | jq '.[0].Status.header.revision')

ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  defrag --cluster
```

### 3. Clean Up Old Resources

```bash
# Delete old failed pods
kubectl delete pods --field-selector=status.phase=Failed -A

# Delete old completed jobs
kubectl delete jobs --field-selector=status.successful=1 -A

# Delete old replica sets
kubectl get rs -A | grep ' 0         0         0' | awk '{print $1, $2}' | \
  while read ns rs; do kubectl delete rs $rs -n $ns; done
```

### 4. Increase etcd Disk Size

If your cluster is large, consider increasing etcd disk allocation:

1. Backup etcd data
2. Increase persistent volume size
3. Increase quota: `--quota-backend-bytes=16000000000` (16GB)

## Monitoring

Set up alerts for etcd space usage:

```bash
# Check etcd size regularly
kubectl exec -n kube-system etcd-<node> -- sh -c \
  "ETCDCTL_API=3 etcdctl endpoint status --write-out=json" | \
  jq '.[0].Status.dbSize'
```

Alert when size exceeds 80% of quota (default 2GB).

## Common Issues

### Issue: "etcdctl: command not found"

**Solution:** etcdctl is inside the etcd pod. Use kubectl exec:

```bash
kubectl exec -n kube-system <etcd-pod-name> -- etcdctl ...
```

### Issue: "certificate signed by unknown authority"

**Solution:** Use correct certificate paths:
- CA: `/etc/kubernetes/pki/etcd/ca.crt`
- Cert: `/etc/kubernetes/pki/etcd/server.crt`
- Key: `/etc/kubernetes/pki/etcd/server.key`

### Issue: Still getting space exceeded after compaction

**Solutions:**
1. Run defrag again
2. Delete unnecessary resources
3. Increase etcd quota
4. Check disk space: `df -h /var/lib/etcd`

## References

- [etcd Maintenance Guide](https://etcd.io/docs/latest/op-guide/maintenance/)
- [Kubernetes etcd](https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/)
- [etcd Space Quota](https://etcd.io/docs/latest/op-guide/maintenance/#space-quota)

