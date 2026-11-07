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

echo "-> snapd: refresh.retain=2"
$DRY || snap set system refresh.retain=2

if $DRY; then
  echo "done (dry run, nothing changed)"
  exit 0
fi

systemctl daemon-reload
systemctl restart apt-daily.timer apt-daily-upgrade.timer fstrim.timer e2scrub_all.timer
systemctl list-timers --all --no-pager | grep -E 'NEXT|apt-daily|fstrim|e2scrub_all'
