#!/usr/bin/env bash
# Put the node's own systemd maintenance timers into the nightly window (2026-11-07).
#
# Owner decision: all nightly work is finished by 02:00 EAT, leaving hours to fix
# anything before the morning. The Ubuntu defaults ran the OS package upgrade at a
# random time around 06:00 UTC, which is 09:00 EAT, in business hours.
#
# Full nightly order: docs/OPERATIONS-RUNBOOK.md. The node is on UTC, EAT is UTC+3.
#   21:15 UTC  00:15 EAT  apt-daily          download package lists and updates
#   21:30 UTC  00:30 EAT  apt-daily-upgrade  install them (may request a reboot)
#   21:50 UTC  00:50 EAT  cluster-daily-cleanup CronJob removes the leftovers
#   22:00 UTC  01:00 EAT  kured reboot window opens, if a reboot was requested
#   Mon 00:20 EAT         fstrim             weekly, disk trim
#   Sun 00:40 EAT         e2scrub_all        weekly, filesystem check
#
# Also sets unattended-upgrades to remove unused kernels and dependencies itself, and
# snapd to keep two revisions (running plus one fallback).
#
# Update policy (owner decision 2026-11-07): routine updates install automatically in
# the nightly window, not only security fixes. unattended-upgrades also takes Ubuntu
# noble-updates and the Docker repo; a kernel update creates the reboot sentinel and
# kured reboots in its 01:00-02:00 EAT window. Two things stay deliberate:
#   - kubeadm, kubelet, kubectl are held (apt-mark hold); a Kubernetes upgrade is a
#     planned kubeadm procedure, never an automatic package update.
#   - containerd.io and Docker are pinned to their current series (CONTAINERD_SERIES,
#     DOCKER_SERIES below). Patch releases flow automatically; a new containerd minor or
#     Docker major is a reviewed change: test it, then move the series here and re-run.
#     Rolling back: apt-get install containerd.io=<previous version> after widening the pin.
CONTAINERD_SERIES="2.4.*"
DOCKER_SERIES="5:29.*"
#
# Idempotent, safe to re-run, and must be re-run on a rebuilt node.
# Usage (on the node as root): scripts/cluster/set-node-maintenance-schedule.sh [--dry-run]
set -euo pipefail

DRY=false
[ "${1:-}" = "--dry-run" ] && DRY=true

timer() { # unit, OnCalendar value
  local unit="$1" when="$2" dir="/etc/systemd/system/$1.timer.d"
  echo "-> $unit: $when UTC"
  $DRY && return 0
  mkdir -p "$dir"
  # The empty OnCalendar= clears the packaged schedule; a zero delay keeps the order exact.
  cat > "$dir/nightly-window.conf" <<EOF
[Timer]
OnCalendar=
OnCalendar=$when
RandomizedDelaySec=0
EOF
}

timer apt-daily         "*-*-* 21:15:00"
timer apt-daily-upgrade "*-*-* 21:30:00"
timer fstrim            "Sun *-*-* 21:20:00"   # Monday 00:20 EAT
timer e2scrub_all       "Sat *-*-* 21:40:00"   # Sunday 00:40 EAT

APT_CONF=/etc/apt/apt.conf.d/52codevertex-cleanup
echo "-> $APT_CONF: remove unused kernels and dependencies after upgrades"
if ! $DRY; then
  cat > "$APT_CONF" <<'EOF'
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
fi

ORIGINS_CONF=/etc/apt/apt.conf.d/53codevertex-routine-updates
echo "-> $ORIGINS_CONF: also install noble-updates and Docker repo updates nightly"
if ! $DRY; then
  # Appends to the Allowed-Origins list in 50unattended-upgrades (apt merges lists).
  cat > "$ORIGINS_CONF" <<'EOF'
Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}-updates";
        "Docker:${distro_codename}";
};
// The reboot is kured's job, inside its window, after draining the node.
Unattended-Upgrade::Automatic-Reboot "false";
EOF
fi

PIN_FILE=/etc/apt/preferences.d/codevertex-runtime-series
echo "-> $PIN_FILE: containerd.io $CONTAINERD_SERIES, docker $DOCKER_SERIES"
if ! $DRY; then
  # First matching record wins for a version: allowed series 990, anything else -1.
  cat > "$PIN_FILE" <<EOF
Package: containerd.io
Pin: version $CONTAINERD_SERIES
Pin-Priority: 990

Package: containerd.io
Pin: release o=Docker
Pin-Priority: -1

Package: docker-ce docker-ce-cli docker-ce-rootless-extras
Pin: version $DOCKER_SERIES
Pin-Priority: 990

Package: docker-ce docker-ce-cli docker-ce-rootless-extras
Pin: release o=Docker
Pin-Priority: -1
EOF
fi

echo "-> holds: $(apt-mark showhold 2>/dev/null | tr '\n' ' ')"
for p in kubeadm kubelet kubectl; do
  apt-mark showhold 2>/dev/null | grep -qx "$p" || { echo "   $p was not held"; $DRY || apt-mark hold "$p" >/dev/null; }
done

echo "-> snapd: refresh.retain=2"
$DRY || snap set system refresh.retain=2

if $DRY; then
  echo "done (dry run, nothing changed)"
  exit 0
fi

unattended-upgrade --dry-run 2>&1 | grep -iE 'packages that will be upgraded|No packages found' | head -1

# daemon-reload alone re-arms the timers with the new OnCalendar. Do NOT restart them:
# a restart makes systemd fire a catch-up run straight away (Persistent=true), which on
# 2026-11-07 ran an upgrade at 01:02 UTC, and apt then skipped that night's planned run
# because apt.systemd.daily allows one run per calendar date.
systemctl daemon-reload
systemctl list-timers --all --no-pager | grep -E 'NEXT|apt-daily|fstrim|e2scrub_all'
