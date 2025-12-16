This folder contains ArgoCD config that must be applied to the `argocd` namespace.

Files:
- argocd-cm.yaml — authoritative `argocd-cm` (health customizations, ignore rules, exclusions).

Guidelines:
- Always update `apps/argocd/argocd-cm.yaml` when changing ArgoCD health assessments.
- Open a PR and include a brief description of the keys being changed. The repository includes a validation workflow (`.github/workflows/validate-argocd-cm.yaml`) which checks that essential keys are still present.
- Avoid applying ad-hoc `kubectl apply -f` changes directly to the cluster; prefer making changes in the repo so the `root` ArgoCD Application can ensure those resources are managed.
