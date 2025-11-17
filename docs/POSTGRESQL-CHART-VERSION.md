# PostgreSQL Chart Version Selection

## Current Version: 16.7.27 (PostgreSQL 17.6.0)

### Why This Version?

After thorough analysis of available Bitnami PostgreSQL chart versions, we selected **16.7.27** as our production standard for the following reasons:

#### 1. **Stability Over Bleeding Edge**
- **PostgreSQL 17.6.0** is a mature, well-tested version
- Avoids the **18.x series** (PostgreSQL 18.0.0) which is too new for production
- PostgreSQL 18.0.0 was released very recently and lacks extensive production battle-testing

#### 2. **Bug-Free FIPS Handling**
- **Version 15.5.26** had a critical FIPS validation bug causing template rendering errors
- **Version 16.7.27** handles FIPS configuration gracefully without validation issues
- No template errors at `statefulset.yaml:224:24`

#### 3. **Latest Stable in Production Series**
- **16.7.27** is the latest in the stable 16.x series
- Includes all security patches and bug fixes
- Maintained and actively supported by Bitnami

#### 4. **Production-Ready Features**
- Comprehensive monitoring with Prometheus/Grafana integration
- Robust health checks and readiness probes
- Efficient resource management
- Proper persistent volume handling

---

## Version History & Migration

### Timeline

| Date | Chart Version | PostgreSQL Version | Status | Notes |
|------|--------------|-------------------|--------|-------|
| 2024-11 | 15.5.26 | 16.x | ❌ Failed | FIPS validation bug |
| 2024-11 | 15.5.20 | 16.x | ⚠️ Workaround | Temporary fix |
| 2024-11 | **16.7.27** | **17.6.0** | ✅ **Current** | **Stable production** |

### Breaking Changes from 15.x to 16.x

1. **FIPS Configuration**
   - Now optional and handled gracefully
   - We still set it explicitly for compatibility: `global.defaultFips=false` and `fips.openssl=false`

2. **Helm Annotations**
   - Stricter validation of resource ownership
   - Orphaned resources must be cleaned up before installation

3. **PostgreSQL Version**
   - Upgraded from 16.x to 17.6.0
   - Minor version upgrade, no breaking changes in PostgreSQL itself

---

## Installation Configuration

### Chart Version Specification

All installations now explicitly specify the chart version:

```bash
helm install postgresql bitnami/postgresql \
  --version 16.7.27 \
  -n infra \
  --set global.defaultFips=false \
  --set fips.openssl=false \
  -f values.yaml
```

### ArgoCD Configuration

```yaml
spec:
  source:
    repoURL: https://charts.bitnami.com/bitnami
    chart: postgresql
    targetRevision: 16.7.27  # Explicit version pinning
```

---

## Orphaned Resource Handling

### The Problem

When upgrading from older installations, orphaned resources (NetworkPolicy, ConfigMap) can prevent Helm from managing the release:

```
Error: INSTALLATION FAILED: Unable to continue with install: NetworkPolicy "postgresql" 
in namespace "infra" exists and cannot be imported into the current release: 
invalid ownership metadata
```

### The Solution

Our installation script now automatically detects and cleans up orphaned resources:

```bash
# Check for orphaned resources
kubectl get networkpolicy,configmap,service,secret \
  -n infra \
  -l app.kubernetes.io/name=postgresql

# Clean up orphaned resources (except secrets)
kubectl delete networkpolicy -n infra -l app.kubernetes.io/name=postgresql
kubectl delete configmap -n infra -l app.kubernetes.io/name=postgresql
```

**Note**: Secrets are preserved to maintain password consistency.

---

## Future Upgrade Path

### When to Upgrade

Consider upgrading when:
1. Critical security vulnerabilities are patched
2. New features are needed
3. Bug fixes address specific issues you're facing
4. After 6+ months to get latest improvements

### How to Upgrade

1. **Test in non-production first**
   ```bash
   helm upgrade postgresql bitnami/postgresql \
     --version <new-version> \
     -n infra \
     --dry-run
   ```

2. **Backup databases**
   ```bash
   kubectl exec -n infra postgresql-0 -- \
     pg_dumpall -U postgres > backup-$(date +%Y%m%d).sql
   ```

3. **Perform upgrade**
   ```bash
   helm upgrade postgresql bitnami/postgresql \
     --version <new-version> \
     -n infra \
     --reuse-values
   ```

4. **Verify health**
   ```bash
   kubectl get pods -n infra | grep postgresql
   kubectl logs -n infra postgresql-0
   ```

### Monitoring New Releases

Check for new versions:
```bash
helm search repo bitnami/postgresql --versions | head -20
```

Review changelog:
```bash
helm show readme bitnami/postgresql --version <version>
```

---

## Troubleshooting

### Issue: FIPS Validation Error

**Symptom:**
```
Error: execution error at (postgresql/templates/primary/statefulset.yaml:224:24): 
Please configure a value for 'fips.openssl' or 'global.defaultFips'
```

**Solution:**
- Ensure chart version is 16.7.27 or later
- Verify FIPS flags are set in Helm arguments
- Check values file includes FIPS configuration

### Issue: Orphaned Resources

**Symptom:**
```
Error: Unable to continue with install: NetworkPolicy "postgresql" exists 
and cannot be imported into the current release
```

**Solution:**
- Run the cleanup script in `install-databases.sh`
- Or manually delete orphaned resources (except secrets)

### Issue: Version Mismatch

**Symptom:**
Pod fails to start after upgrade

**Solution:**
1. Check pod logs: `kubectl logs -n infra postgresql-0`
2. Verify PVC is healthy: `kubectl get pvc -n infra`
3. Rollback if needed: `helm rollback postgresql -n infra`

---

## References

- [Bitnami PostgreSQL Chart](https://github.com/bitnami/charts/tree/main/bitnami/postgresql)
- [PostgreSQL 17 Release Notes](https://www.postgresql.org/docs/17/release-17.html)
- [Helm Chart Best Practices](https://helm.sh/docs/chart_best_practices/)

---

**Last Updated:** November 2024  
**Maintained By:** DevOps Team  
**Review Frequency:** Quarterly

