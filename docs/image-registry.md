Image Registry and SBOM
-----------------------

- Use a private registry (e.g., `registry.masterspace.co.ke`).
- Authenticate with REGISTRY_USERNAME/REGISTRY_PASSWORD in GitHub Secrets.
- Images are tagged with short SHA; latest is not used for deploys.
- Trivy generates vulnerability reports; integrate with registry scanning when available.


