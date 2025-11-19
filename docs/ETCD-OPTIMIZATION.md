# etcd Space Optimization Guide

## Overview

This guide covers etcd database space management to prevent the `etcdserver: mvcc: database space exceeded` error that can occur in Kubernetes clusters.

## Understanding the Error

The `etcdserver: mvcc: database space exceeded` error occurs when:
- etcd's database reaches its storage quota
- Old revisions accumulate without compaction
- Database fragmentation reduces available space

## Prevention Strategies

### 1. Automatic Compaction (Recommended)

Configure etcd with automatic compaction to prevent space issues:

#### For kubeadm Clusters

Edit `/etc/kubernetes/manifests/etcd.yaml` on the master node:

```bash
# SSH into your VPS
ssh root@YOUR_VPS_IP

# Backup original manifest
cp /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/manifests/etcd.yaml.backup

# Edit etcd manifest
vim /etc/kubernetes/manifests/etcd.yaml
```

Add these flags to the etcd container command:

```yaml
spec:
  containers:
  - command:
    - etcd
    - --auto-compaction-mode=revision
    - --auto-compaction-retention=1000  # Keep last 1000 revisions
    - --quota-backend-bytes=8589934592  # 8GB quota (adjust based on disk size)
```

**Note:** The manifest is managed by kubelet. Changes will be automatically applied.

#### Verification

```bash
# Check etcd status
kubectl exec -n kube-system etcd-$(hostname) -- \
  ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --write-out=table
```

### 2. Periodic Maintenance

Run periodic maintenance scripts to check and optimize etcd:

```bash
# Check etcd space (non-destructive)
./scripts/cluster/check-etcd-space.sh

# Fix etcd space if needed (compacts and defragments)
./scripts/cluster/fix-etcd-space.sh
```

### 3. Resource Cleanup

Regularly clean up unused resources:

```bash
# Delete completed jobs
kubectl delete jobs --field-selector status.successful=1 --all-namespaces

# Delete old replicasets
kubectl delete replicasets --all-namespaces --field-selector status.replicas=0

# Clean up old events (older than 1 hour)
kubectl delete events --all --all-namespaces --field-selector lastTimestamp<$(date -d '1 hour ago' -Iseconds)
```

## Recovery Procedures

### Immediate Recovery

If you encounter the error:

1. **Run automatic fix script:**
   ```bash
   ./scripts/cluster/fix-etcd-space.sh
   ```

2. **Or manually compact and defragment:**
   ```bash
   # Get current revision
   REVISION=$(kubectl exec -n kube-system etcd-$(hostname) -- \
     ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     endpoint status --write-out=json | jq -r '.Header.revision')
   
   # Compact to current revision
   kubectl exec -n kube-system etcd-$(hostname) -- \
     ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     compact $REVISION
   
   # Defragment
   kubectl exec -n kube-system etcd-$(hostname) -- \
     ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     defrag --cluster
   
   # Disarm alarm
   kubectl exec -n kube-system etcd-$(hostname) -- \
     ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     alarm disarm
   ```

## Automated Prevention in Workflows

The provisioning workflow (`provision.yml`) automatically:
1. Checks etcd space before provisioning
2. Runs preventive maintenance if needed
3. Warns if space is low

## Monitoring

### Check etcd Space Regularly

```bash
# Weekly check (add to cron)
0 2 * * 0 /path/to/scripts/cluster/check-etcd-space.sh
```

### Set Up Alerts

Monitor etcd alarms in Prometheus/Grafana:

```yaml
# Example alert rule
- alert: EtcdSpaceExceeded
  expr: etcd_server_quota_backend_bytes{job="etcd"} - etcd_server_quota_backend_bytes_used{job="etcd"} < 1073741824
  for: 5m
  annotations:
    summary: "etcd database space is low"
```

## Best Practices

1. **Enable auto-compaction** during initial cluster setup
2. **Set appropriate quota** based on disk size (recommended: 8GB for 48GB VPS)
3. **Run periodic maintenance** (weekly/monthly)
4. **Clean up unused resources** regularly
5. **Monitor etcd metrics** in Grafana
6. **Set up alerts** for space warnings

## Quota Recommendations

| VPS Disk Size | Recommended etcd Quota | Auto-compaction Retention |
|---------------|----------------------|---------------------------|
| 48GB          | 8GB                  | 1000 revisions           |
| 100GB         | 16GB                 | 2000 revisions           |
| 200GB+        | 32GB                 | 5000 revisions           |

## Troubleshooting

### Issue: Compaction doesn't free space

**Solution:** Run defragmentation after compaction:
```bash
./scripts/cluster/fix-etcd-space.sh
```

### Issue: Alarm persists after compaction

**Solution:** Disarm alarm explicitly:
```bash
kubectl exec -n kube-system etcd-$(hostname) -- \
  ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  alarm disarm
```

### Issue: Cannot connect to etcd

**Solution:** Check etcd pod status:
```bash
kubectl get pods -n kube-system -l component=etcd
kubectl logs -n kube-system etcd-$(hostname)
```

## Related Documentation

- [Provisioning Guide](./provisioning.md)
- [Kubeadm Setup](./contabo-setup-kubeadm.md)
- [Operations Runbook](./OPERATIONS-RUNBOOK.md)

