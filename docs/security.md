Security
--------

- Trivy FS and Image scans run on each pipeline.
- Use private image registries; set REGISTRY_USERNAME/PASSWORD.
- Store sensitive values only in Kubernetes Secrets; never commit plaintext.
- Use GitHub Environments with protection rules for production.
- Restrict Argo CD repo access to read-only deploy key.
- Rotate `KUBE_CONFIG` tokens periodically.


