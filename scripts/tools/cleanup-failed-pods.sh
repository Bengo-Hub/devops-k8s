#!/bin/bash
# Cleanup script for failed/degraded pods to prevent pod limit exhaustion
# Run as pre-deploy hook or on-demand when cluster hits pod limit

set -euo pipefail

echo "🧹 Starting pod cleanup..."

# Define namespaces to scan (exclude kube-system for safety)
NAMESPACES=$(kubectl get namespaces -o jsonpath='{.items[?(@.metadata.name!="kube-system")].metadata.name}')

# Track cleanup statistics
TOTAL_DELETED=0

# Function to delete pods by status phase
cleanup_by_phase() {
  local PHASE=$1
  echo "🔍 Scanning for pods in $PHASE state..."
  
  for NS in $NAMESPACES; do
    PODS=$(kubectl get pods -n "$NS" --field-selector=status.phase="$PHASE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    if [ -n "$PODS" ]; then
      echo "  📦 Deleting $PHASE pods in namespace $NS: $PODS"
      kubectl delete pods -n "$NS" --field-selector=status.phase="$PHASE" --grace-period=0 --force 2>/dev/null || true
      COUNT=$(echo "$PODS" | wc -w)
      TOTAL_DELETED=$((TOTAL_DELETED + COUNT))
    fi
  done
}

# Function to delete pods by image pull errors
cleanup_image_errors() {
  echo "🔍 Scanning for ImagePullBackOff/ErrImagePull pods..."
  
  for NS in $NAMESPACES; do
    PODS=$(kubectl get pods -n "$NS" -o jsonpath='{.items[?(@.status.containerStatuses[*].state.waiting.reason=="ImagePullBackOff")].metadata.name}' 2>/dev/null || echo "")
    
    if [ -n "$PODS" ]; then
      echo "  📦 Deleting ImagePullBackOff pods in namespace $NS: $PODS"
      for POD in $PODS; do
        kubectl delete pod -n "$NS" "$POD" --grace-period=0 --force 2>/dev/null || true
        TOTAL_DELETED=$((TOTAL_DELETED + 1))
      done
    fi
    
    PODS=$(kubectl get pods -n "$NS" -o jsonpath='{.items[?(@.status.containerStatuses[*].state.waiting.reason=="ErrImagePull")].metadata.name}' 2>/dev/null || echo "")
    
    if [ -n "$PODS" ]; then
      echo "  📦 Deleting ErrImagePull pods in namespace $NS: $PODS"
      for POD in $PODS; do
        kubectl delete pod -n "$NS" "$POD" --grace-period=0 --force 2>/dev/null || true
        TOTAL_DELETED=$((TOTAL_DELETED + 1))
      done
    fi
  done
}

# Function to delete stale ACME solver pods (older than 10 minutes)
cleanup_acme_solvers() {
  echo "🔍 Scanning for stale ACME HTTP solver pods..."
  
  ACME_PODS=$(kubectl get pods --all-namespaces -l acme.cert-manager.io/http01-solver=true \
    -o json | jq -r '.items[] | select((.status.phase == "Running" or .status.phase == "Pending") and ((now - (.metadata.creationTimestamp | fromdateiso8601)) > 600)) | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null || echo "")
  
  if [ -n "$ACME_PODS" ]; then
    echo "  📦 Deleting stale ACME solver pods (>10min old):"
    for POD_PATH in $ACME_PODS; do
      NS=$(echo "$POD_PATH" | cut -d'/' -f1)
      POD=$(echo "$POD_PATH" | cut -d'/' -f2)
      echo "    - $NS/$POD"
      kubectl delete pod -n "$NS" "$POD" --grace-period=0 --force 2>/dev/null || true
      TOTAL_DELETED=$((TOTAL_DELETED + 1))
    done
  fi
}

# Function to detect and remove duplicate pods (same deployment, multiple pods pending/failing)
cleanup_duplicates() {
  echo "🔍 Scanning for duplicate pods from failed rollouts..."
  
  for NS in $NAMESPACES; do
    # Get deployments with multiple replicasets (indicates rollout issues)
    DEPLOYMENTS=$(kubectl get deployments -n "$NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    for DEPLOY in $DEPLOYMENTS; do
      # Count replicasets for this deployment
      RS_COUNT=$(kubectl get rs -n "$NS" -l "app=$DEPLOY" -o json | jq '[.items[] | select(.status.replicas > 0)] | length' 2>/dev/null || echo "0")
      
      if [ "$RS_COUNT" -gt 1 ]; then
        echo "  ⚠️  Found $RS_COUNT active replicasets for deployment $NS/$DEPLOY"
        # Delete pods from old replicasets (not the latest)
        OLD_RS=$(kubectl get rs -n "$NS" -l "app=$DEPLOY" --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[:-1].metadata.name}' 2>/dev/null || echo "")
        
        for RS in $OLD_RS; do
          PODS=$(kubectl get pods -n "$NS" -l "pod-template-hash=${RS#*-}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
          if [ -n "$PODS" ]; then
            echo "    📦 Deleting pods from old replicaset $RS: $PODS"
            for POD in $PODS; do
              kubectl delete pod -n "$NS" "$POD" --grace-period=0 --force 2>/dev/null || true
              TOTAL_DELETED=$((TOTAL_DELETED + 1))
            done
          fi
        done
      fi
    done
  done
}

# Run cleanup phases
cleanup_by_phase "Failed"
cleanup_by_phase "Unknown"
cleanup_by_phase "Pending" # Only if older than 10 minutes (handled by kubectl timeout)
cleanup_image_errors
cleanup_acme_solvers
cleanup_duplicates

# Show final pod count
TOTAL_PODS=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l)
RUNNING_PODS=$(kubectl get pods --all-namespaces --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)

echo ""
echo "✅ Cleanup complete!"
echo "  🗑️  Deleted: $TOTAL_DELETED pods"
echo "  📊 Total pods: $TOTAL_PODS (running: $RUNNING_PODS)"
echo ""

# Check if still at limit
NODE_PODS=$(kubectl describe nodes | grep -E "^\s+Pods:" | awk '{print $2}' | tr -d '()' || echo "0/110")
echo "  🖥️  Node pod usage: $NODE_PODS"

if [[ "$NODE_PODS" == *"/110" ]] && [[ "${NODE_PODS%%/*}" -ge 105 ]]; then
  echo "  ⚠️  WARNING: Still near pod limit! Consider scaling down non-critical services."
  exit 1
fi
