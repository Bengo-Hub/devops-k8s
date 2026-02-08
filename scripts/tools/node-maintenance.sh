#!/bin/bash
# =============================================================================
# Node Maintenance Script
# Cleans zombie processes, prunes container images, rotates logs, frees disk
# Run on the host node (via SSH or crontab), NOT inside a pod
# =============================================================================

set -euo pipefail

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
section() { echo ""; echo -e "${BLUE}====== $1 ======${NC}"; }

DRY_RUN=${DRY_RUN:-false}
DISK_THRESHOLD=${DISK_THRESHOLD:-80}
LOG_MAX_SIZE=${LOG_MAX_SIZE:-50M}

# =============================================================================
# 1. ZOMBIE PROCESS CLEANUP
# =============================================================================
cleanup_zombies() {
  section "Zombie Process Cleanup"

  ZOMBIES=$(ps -eo pid,ppid,stat,comm | awk '$3 ~ /Z/ {print $1, $2, $4}')
  ZOMBIE_COUNT=$(echo "$ZOMBIES" | grep -c '[0-9]' || echo 0)

  if [ "$ZOMBIE_COUNT" -eq 0 ]; then
    success "No zombie processes found"
    return
  fi

  warn "Found $ZOMBIE_COUNT zombie processes"

  # Group zombies by parent PID
  echo "$ZOMBIES" | awk '{print $2}' | sort -u | while read PPID; do
    PARENT_CMD=$(ps -p "$PPID" -o comm= 2>/dev/null || echo "unknown")
    CHILD_COUNT=$(echo "$ZOMBIES" | awk -v ppid="$PPID" '$2 == ppid' | wc -l)
    info "  Parent PID $PPID ($PARENT_CMD) has $CHILD_COUNT zombie children"

    if [ "$DRY_RUN" = "true" ]; then
      info "  [DRY RUN] Would send SIGCHLD to PID $PPID"
    else
      # Send SIGCHLD to parent to trigger waitpid() and reap zombies
      kill -s SIGCHLD "$PPID" 2>/dev/null || true
    fi
  done

  # Wait a moment then check if any remain
  sleep 2
  REMAINING=$(ps -eo stat | grep -c '^Z' || echo 0)
  if [ "$REMAINING" -gt 0 ]; then
    warn "$REMAINING zombies still remain (parent may be stuck)"
    warn "Consider restarting parent processes or the containerd/kubelet service"
  else
    success "All zombie processes reaped"
  fi
}

# =============================================================================
# 2. CONTAINER IMAGE PRUNING
# =============================================================================
prune_images() {
  section "Container Image Pruning"

  # Detect container runtime
  if command -v crictl >/dev/null 2>&1; then
    RUNTIME="crictl"
  elif command -v docker >/dev/null 2>&1; then
    RUNTIME="docker"
  elif command -v nerdctl >/dev/null 2>&1; then
    RUNTIME="nerdctl"
  else
    warn "No container runtime CLI found (crictl/docker/nerdctl)"
    return
  fi

  info "Using container runtime: $RUNTIME"

  if [ "$RUNTIME" = "crictl" ]; then
    # crictl prune removes unused images
    BEFORE=$(crictl images -q 2>/dev/null | wc -l || echo 0)
    if [ "$DRY_RUN" = "true" ]; then
      info "[DRY RUN] Would prune unused container images ($BEFORE total)"
    else
      crictl rmi --prune 2>/dev/null || true
      AFTER=$(crictl images -q 2>/dev/null | wc -l || echo 0)
      success "Pruned $((BEFORE - AFTER)) unused images ($AFTER remaining)"
    fi
  elif [ "$RUNTIME" = "docker" ]; then
    if [ "$DRY_RUN" = "true" ]; then
      RECLAIMABLE=$(docker system df --format '{{.Reclaimable}}' 2>/dev/null | head -1 || echo "unknown")
      info "[DRY RUN] Would prune Docker system (reclaimable: $RECLAIMABLE)"
    else
      # Remove dangling images and stopped containers older than 24h
      docker image prune -f --filter "until=24h" 2>/dev/null || true
      docker container prune -f --filter "until=24h" 2>/dev/null || true
      docker builder prune -f --filter "until=24h" 2>/dev/null || true
      success "Docker image/container/builder prune complete"
    fi
  fi
}

# =============================================================================
# 3. CONTAINER LOG CLEANUP
# =============================================================================
cleanup_logs() {
  section "Container Log Cleanup"

  LOG_DIR="/var/log/containers"
  JOURNAL_DIR="/var/log/journal"

  # Truncate oversized container logs
  if [ -d "$LOG_DIR" ]; then
    LARGE_LOGS=$(find "$LOG_DIR" -name "*.log" -size "+${LOG_MAX_SIZE}" 2>/dev/null | wc -l || echo 0)
    if [ "$LARGE_LOGS" -gt 0 ]; then
      if [ "$DRY_RUN" = "true" ]; then
        info "[DRY RUN] Would truncate $LARGE_LOGS container logs larger than $LOG_MAX_SIZE"
        find "$LOG_DIR" -name "*.log" -size "+${LOG_MAX_SIZE}" -exec ls -lh {} \; 2>/dev/null || true
      else
        find "$LOG_DIR" -name "*.log" -size "+${LOG_MAX_SIZE}" -exec truncate -s 0 {} \; 2>/dev/null || true
        success "Truncated $LARGE_LOGS oversized container logs"
      fi
    else
      success "No oversized container logs found"
    fi
  fi

  # Clean up pod log symlinks for non-existent pods
  POD_LOG_DIR="/var/log/pods"
  if [ -d "$POD_LOG_DIR" ]; then
    STALE_COUNT=0
    find "$POD_LOG_DIR" -maxdepth 1 -type d -mtime +7 2>/dev/null | while read DIR; do
      POD_UID=$(basename "$DIR" | rev | cut -d'_' -f1 | rev)
      # Check if pod UID still exists in kubelet
      if [ ! -d "/var/lib/kubelet/pods/${POD_UID}" ] 2>/dev/null; then
        if [ "$DRY_RUN" = "true" ]; then
          info "[DRY RUN] Would remove stale pod log dir: $DIR"
        else
          rm -rf "$DIR" 2>/dev/null || true
          STALE_COUNT=$((STALE_COUNT + 1))
        fi
      fi
    done
    [ "$STALE_COUNT" -gt 0 ] && success "Removed $STALE_COUNT stale pod log directories"
  fi

  # Vacuum journald logs if they're too large (keep last 500MB)
  if command -v journalctl >/dev/null 2>&1; then
    JOURNAL_SIZE=$(journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+[GMK]' || echo "0")
    info "Journal log size: $JOURNAL_SIZE"
    if [ "$DRY_RUN" = "true" ]; then
      info "[DRY RUN] Would vacuum journal to 500M"
    else
      journalctl --vacuum-size=500M 2>/dev/null || true
      success "Journal vacuumed to 500MB max"
    fi
  fi
}

# =============================================================================
# 4. DISK SPACE RECOVERY
# =============================================================================
check_disk() {
  section "Disk Space Check"

  DISK_USAGE=$(df / --output=pcent | tail -1 | tr -d ' %')
  DISK_AVAIL=$(df -h / --output=avail | tail -1 | tr -d ' ')

  info "Disk usage: ${DISK_USAGE}% (${DISK_AVAIL} available)"

  if [ "$DISK_USAGE" -gt "$DISK_THRESHOLD" ]; then
    warn "Disk usage above ${DISK_THRESHOLD}% threshold!"

    # Clean tmp files older than 7 days
    if [ "$DRY_RUN" = "true" ]; then
      TMP_SIZE=$(find /tmp -type f -mtime +7 -exec du -ch {} + 2>/dev/null | tail -1 || echo "0")
      info "[DRY RUN] Would clean /tmp files older than 7 days ($TMP_SIZE)"
    else
      find /tmp -type f -mtime +7 -delete 2>/dev/null || true
      success "Cleaned /tmp files older than 7 days"
    fi

    # Clean apt cache if available
    if command -v apt-get >/dev/null 2>&1; then
      if [ "$DRY_RUN" = "true" ]; then
        info "[DRY RUN] Would clean apt cache"
      else
        apt-get clean 2>/dev/null || true
        success "apt cache cleaned"
      fi
    fi

    # Report disk after cleanup
    DISK_AFTER=$(df / --output=pcent | tail -1 | tr -d ' %')
    AVAIL_AFTER=$(df -h / --output=avail | tail -1 | tr -d ' ')
    info "Disk after cleanup: ${DISK_AFTER}% (${AVAIL_AFTER} available)"
  else
    success "Disk usage within threshold"
  fi
}

# =============================================================================
# 5. COMPLETED KUBERNETES JOBS CLEANUP
# =============================================================================
cleanup_completed_jobs() {
  section "Completed Kubernetes Jobs Cleanup"

  if ! command -v kubectl >/dev/null 2>&1; then
    warn "kubectl not found — skipping job cleanup"
    return
  fi

  # Clean up completed migration and seed jobs across all namespaces
  NAMESPACES=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

  TOTAL_CLEANED=0
  for NS in $NAMESPACES; do
    # Find completed jobs (status.succeeded > 0) that are migrate or seed jobs
    COMPLETED_JOBS=$(kubectl get jobs -n "$NS" -o json 2>/dev/null | \
      jq -r '.items[] | select(
        (.status.succeeded // 0) > 0 and
        (.metadata.name | test("migrate|seed"))
      ) | .metadata.name' 2>/dev/null || echo "")

    for JOB in $COMPLETED_JOBS; do
      [ -z "$JOB" ] && continue
      if [ "$DRY_RUN" = "true" ]; then
        info "[DRY RUN] Would delete completed job $NS/$JOB"
      else
        kubectl delete job "$JOB" -n "$NS" --grace-period=0 2>/dev/null || true
        TOTAL_CLEANED=$((TOTAL_CLEANED + 1))
      fi
    done

    # Also clean up failed jobs older than 1 hour
    FAILED_JOBS=$(kubectl get jobs -n "$NS" -o json 2>/dev/null | \
      jq -r '.items[] | select(
        (.status.failed // 0) > 0 and
        ((now - (.metadata.creationTimestamp | fromdateiso8601)) > 3600)
      ) | .metadata.name' 2>/dev/null || echo "")

    for JOB in $FAILED_JOBS; do
      [ -z "$JOB" ] && continue
      if [ "$DRY_RUN" = "true" ]; then
        info "[DRY RUN] Would delete failed job $NS/$JOB (>1h old)"
      else
        kubectl delete job "$JOB" -n "$NS" --grace-period=0 2>/dev/null || true
        TOTAL_CLEANED=$((TOTAL_CLEANED + 1))
      fi
    done
  done

  success "Cleaned $TOTAL_CLEANED completed/failed jobs"
}

# =============================================================================
# MAIN
# =============================================================================
section "Node Maintenance — $(hostname) — $(date -Iseconds)"

if [ "$DRY_RUN" = "true" ]; then
  warn "DRY RUN MODE — no changes will be made"
fi

cleanup_zombies
prune_images
cleanup_logs
check_disk
cleanup_completed_jobs

section "Maintenance Complete"
echo ""
info "System summary:"
echo "  Load average : $(cat /proc/loadavg 2>/dev/null | cut -d' ' -f1-3 || echo 'N/A')"
echo "  Memory       : $(free -h 2>/dev/null | awk '/^Mem:/ {printf "%s used / %s total", $3, $2}' || echo 'N/A')"
echo "  Disk         : $(df -h / 2>/dev/null | awk 'NR==2 {printf "%s used / %s total (%s)", $3, $2, $5}' || echo 'N/A')"
echo "  Zombies      : $(ps -eo stat | grep -c '^Z' 2>/dev/null || echo 0)"
echo "  Processes    : $(ps -e --no-headers | wc -l 2>/dev/null || echo 'N/A')"
