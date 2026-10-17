#!/usr/bin/env bash
# Give the cluster's own system components resource REQUESTS (2026-10-17).
#
# These were installed by plain `kubectl apply` / kubeadm / the Calico operator, so ArgoCD
# does not manage them and they shipped with no requests at all. A container with no
# requests is BestEffort: lowest CPU weight (shares=2), first to be evicted or OOM-killed
# under node pressure. On this single node that put calico-node, kube-proxy, nats and
# ArgoCD behind every ordinary app when the node got busy, which matches the brief probe
# timeouts seen on the node. Requests only, deliberately NO limits: these are control
# plane style components and throttling them is worse than letting them burst.
#
# Idempotent, safe to re-run. kube-proxy is kubeadm-owned and is reset by `kubeadm upgrade`,
# re-run this script after any upgrade. Calico pods are owned by the tigera operator, so
# they are set through the Installation resource instead of on the workloads.
#
# Usage: scripts/cluster/set-system-resource-requests.sh [--dry-run]
set -euo pipefail

DRY=""
[ "${1:-}" = "--dry-run" ] && DRY="--dry-run=server"

set_req() { # namespace kind name container cpu mem
  echo "-> $1/$2/$3 [$4] cpu=$5 mem=$6"
  kubectl set resources "$2" "$3" -n "$1" -c "$4" --requests="cpu=$5,memory=$6" $DRY >/dev/null
}

# ArgoCD (usage at time of writing: controller 252Mi, repo-server 116Mi, rest under 50Mi)
set_req argocd statefulset argocd-application-controller argocd-application-controller 100m 384Mi
set_req argocd deployment  argocd-repo-server            argocd-repo-server            50m  160Mi
set_req argocd deployment  argocd-applicationset-controller argocd-applicationset-controller 10m 48Mi
set_req argocd deployment  argocd-dex-server             dex                           10m  48Mi
set_req argocd deployment  argocd-notifications-controller argocd-notifications-controller 10m 64Mi
set_req argocd deployment  argocd-redis                  redis                         20m  64Mi

# cert-manager
set_req cert-manager deployment cert-manager            cert-manager-controller 25m 96Mi
set_req cert-manager deployment cert-manager-cainjector cert-manager-cainjector 25m 96Mi
set_req cert-manager deployment cert-manager-webhook    cert-manager-webhook    10m 64Mi

# kube-proxy (kubeadm DaemonSet), local-path provisioner, tigera operator
set_req kube-system         daemonset  kube-proxy               kube-proxy             50m 96Mi
set_req local-path-storage  deployment local-path-provisioner   local-path-provisioner 10m 64Mi
set_req tigera-operator     deployment tigera-operator          tigera-operator        25m 128Mi

# Calico data plane, via the operator (calico-node used ~75m / 213Mi at time of writing)
echo "-> Installation/default componentResources"
kubectl patch installation default --type merge $DRY -p '{
  "spec": {"componentResources": [
    {"componentName": "Node",            "resourceRequirements": {"requests": {"cpu": "100m", "memory": "256Mi"}}},
    {"componentName": "Typha",           "resourceRequirements": {"requests": {"cpu": "25m",  "memory": "96Mi"}}},
    {"componentName": "KubeControllers", "resourceRequirements": {"requests": {"cpu": "25m",  "memory": "96Mi"}}}
  ]}}' >/dev/null

echo "done${DRY:+ (dry run, nothing changed)}"
