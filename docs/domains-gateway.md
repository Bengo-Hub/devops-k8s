# Domains, Certificates, and API Gateway

## Overview

This guide covers domain configuration, TLS certificate management, and ingress/API gateway setup for applications deployed in the Kubernetes cluster.

## Prerequisites

- cert-manager installed with a ClusterIssuer `letsencrypt-prod`
- NGINX Ingress Controller installed
- DNS access to configure domain records

---

## Certificates and TLS

### cert-manager Setup

We assume cert-manager with a ClusterIssuer `letsencrypt-prod` is installed in the cluster. The chart templates set annotations for cert-manager and expect per-app TLS secrets names in values.

### Automatic Certificate Provisioning

When an Ingress resource is created with cert-manager annotations, certificates are automatically provisioned:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app-ingress
  namespace: my-namespace
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - myapp.masterspace.co.ke
      secretName: myapp-masterspace-tls
  rules:
    - host: myapp.masterspace.co.ke
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
```

### Certificate Management

**Check Certificate Status:**
```bash
# List all certificates
kubectl get certificates --all-namespaces

# Check certificate details
kubectl describe certificate myapp-masterspace-tls -n my-namespace

# Check certificate readiness
kubectl get certificates -n my-namespace -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}'
```

**Renew Certificates Manually:**
```bash
# Force certificate renewal if needed
kubectl annotate certificate myapp-masterspace-tls -n my-namespace \
  cert-manager.io/issue-temporary-certificate="true"
```

**Troubleshooting Certificates:**
```bash
# Check cert-manager logs
kubectl logs -n cert-manager deployment/cert-manager

# Check certificate order status
kubectl get certificateorders --all-namespaces

# Check certificate challenges (for Let's Encrypt)
kubectl get challenges --all-namespaces
```

---

## Domains Configuration

### Current Production Domains

- **ERP API**: `erpapi.masterspace.co.ke`
- **ERP UI**: `erp.masterspace.co.ke`
- **Argo CD**: `argocd.masterspace.co.ke`
- **Grafana**: `grafana.masterspace.co.ke`

### DNS Configuration

Point all domains to your ingress controller load balancer IP:

**VPS IP:** `77.237.232.66`

**DNS Records:**
```
A Record: erpapi.masterspace.co.ke → 77.237.232.66
A Record: erp.masterspace.co.ke → 77.237.232.66
A Record: argocd.masterspace.co.ke → 77.237.232.66
A Record: grafana.masterspace.co.ke → 77.237.232.66
```

### Adding a New Domain

1. **Create DNS Record:**
   - Add A record pointing to VPS IP: `77.237.232.66`

2. **Update Ingress Configuration:**
   ```yaml
   # In your app's values.yaml
   ingress:
     enabled: true
     className: nginx
     hosts:
       - host: myapp.masterspace.co.ke
         paths:
           - path: /
             pathType: Prefix
     tls:
       - hosts:
           - myapp.masterspace.co.ke
         secretName: myapp-masterspace-tls
   ```

3. **Verify DNS Propagation:**
   ```bash
   # Check DNS resolution
   dig myapp.masterspace.co.ke
   nslookup myapp.masterspace.co.ke
   ```

---

## Ingress and API Gateway

### NGINX Ingress Controller

The generic chart provisions an Ingress per app. For centralized API gateway (e.g., NGINX Ingress or Kong), point DNS to the gateway and let per-app Ingress rules handle routing via hostnames.

### Ingress Configuration

**Basic Ingress:**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app-ingress
  namespace: my-namespace
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - myapp.masterspace.co.ke
      secretName: myapp-masterspace-tls
  rules:
    - host: myapp.masterspace.co.ke
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
```

### Custom Annotations

If you need custom annotations (CORS, timeouts, client body size), add them under `.metadata.annotations` in `templates/ingress.yaml` or expose extra annotations via values:

**Common Annotations:**
```yaml
annotations:
  # CORS
  nginx.ingress.kubernetes.io/enable-cors: "true"
  nginx.ingress.kubernetes.io/cors-allow-origin: "*"
  nginx.ingress.kubernetes.io/cors-allow-methods: "GET, POST, PUT, DELETE, OPTIONS"
  
  # Timeouts
  nginx.ingress.kubernetes.io/proxy-connect-timeout: "60"
  nginx.ingress.kubernetes.io/proxy-send-timeout: "60"
  nginx.ingress.kubernetes.io/proxy-read-timeout: "60"
  
  # Client body size
  nginx.ingress.kubernetes.io/proxy-body-size: "10m"
  
  # Rate limiting
  nginx.ingress.kubernetes.io/limit-rps: "100"
  
  # SSL/TLS
  cert-manager.io/cluster-issuer: letsencrypt-prod
  nginx.ingress.kubernetes.io/ssl-redirect: "true"
```

### Ingress Troubleshooting

**Check Ingress Status:**
```bash
# List all ingresses
kubectl get ingress --all-namespaces

# Describe ingress
kubectl describe ingress my-app-ingress -n my-namespace

# Check ingress controller logs
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller
```

**Common Issues:**

1. **Certificate Not Issued:**
   ```bash
   # Check certificate status
   kubectl get certificate -n my-namespace
   kubectl describe certificate myapp-masterspace-tls -n my-namespace
   
   # Check cert-manager logs
   kubectl logs -n cert-manager deployment/cert-manager
   ```

2. **DNS Not Resolving:**
   ```bash
   # Verify DNS records
   dig myapp.masterspace.co.ke
   
   # Check if DNS points to correct IP
   nslookup myapp.masterspace.co.ke
   ```

3. **Ingress Not Routing:**
   ```bash
   # Check ingress controller is running
   kubectl get pods -n ingress-nginx
   
   # Check ingress configuration
   kubectl get ingress my-app-ingress -n my-namespace -o yaml
   
   # Test connectivity
   curl -H "Host: myapp.masterspace.co.ke" http://77.237.232.66
   ```

---

## Service-Specific TLS Secrets

The ingress template references service-specific TLS secrets:

- **ERP API**: secret `erpapi-masterspace-tls`
- **ERP UI**: secret `erp-masterspace-tls`
- **Argo CD**: secret `argocd-tls`
- **Grafana**: secret `grafana-tls`

cert-manager provisions these automatically when Ingress is created.

---

## Best Practices

1. **Use cert-manager for Automatic Certificates**: Let cert-manager handle certificate provisioning and renewal
2. **Centralize DNS**: Point all domains to the ingress controller IP
3. **Use Descriptive Secret Names**: Follow pattern `{app}-{domain}-tls`
4. **Enable SSL Redirect**: Always redirect HTTP to HTTPS
5. **Monitor Certificate Expiry**: Set up alerts for certificate expiration
6. **Use Wildcard Certificates**: For multiple subdomains, consider wildcard certificates
7. **Test DNS Before Deployment**: Verify DNS propagation before deploying applications

---

## Related Documentation

- **[Provisioning Guide](./provisioning.md)** - Infrastructure provisioning including ingress controller
- **[Onboarding Guide](./onboarding.md)** - Adding new applications with domain configuration
- **[Operations Runbook](./OPERATIONS-RUNBOOK.md)** - Troubleshooting and maintenance procedures
