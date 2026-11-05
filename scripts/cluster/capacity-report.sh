#!/usr/bin/env bash
# Read-only capacity report for the single prod node (2026-11-06).
#
# Shows what is reserved against what is really used, so right-sizing decisions are made
# from live numbers instead of guesses. There is no Prometheus on this cluster (see
# reference_observability_no_prometheus), so this reads metrics-server, the kernel cgroup
# counters and the ingress access logs directly. It changes nothing.
#
# Sections:
#   1. node      requests and limits vs real use, CPU pressure (PSI)
#   2. pods      per pod requests vs current use, sorted by idle reservation
#   3. throttle  containers whose CFS quota throttled them in >=1% of periods since start
#   4. hpa       autoscaler status (watch memory or cpu above target with no room to scale)
#   5. traffic   ingress requests and p95 latency per upstream, from all retained log files
#   6. nats      JetStream streams, consumers, replica spread and unbound (orphan-like) durables
#
# Run on the node as root. From a Windows workstation (PowerShell), strip the BOM and CRLF that
# PowerShell adds to piped stdin on the far side:
#   Get-Content scripts/cluster/capacity-report.sh -Raw | ssh mss-prod "sed '1s/^\xEF\xBB\xBF//' | tr -d '\r' | bash -s -- pods"
# Optional first argument picks one section: node|pods|throttle|hpa|traffic|nats
set -uo pipefail

ONLY="${1:-all}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
want() { [ "$ONLY" = "all" ] || [ "$ONLY" = "$1" ]; }

if want node; then
  echo "=== 1. node"
  kubectl top nodes
  kubectl describe nodes | sed -n '/Allocated resources/,/Events/p' | grep -E 'cpu|memory'
  echo "pods: $(kubectl get pods -A --no-headers --field-selector=status.phase=Running | wc -l) running, cap $(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.pods}')"
  echo "cpu pressure: $(head -1 /proc/pressure/cpu)"
  free -m | head -2
fi

if want pods; then
  echo "=== 2. pods (requests vs use; cpu in m, memory in Mi)"
  kubectl get pods -A --field-selector=status.phase=Running -o json > "$TMP/pods.json"
  kubectl top pods -A --no-headers > "$TMP/top.txt"
  python3 - "$TMP" <<'PY'
import json, re, sys
d = sys.argv[1]
def cpu(v):
    if not v: return 0.0
    return float(v[:-1]) if v.endswith('m') else float(v) * 1000
def mem(v):
    if not v: return 0.0
    m = re.match(r'([\d.]+)(\w*)', v); n = float(m.group(1))
    return n * {'Ki': 1/1024, 'Mi': 1, 'Gi': 1024, 'K': 1/1024, 'M': 1, 'G': 1000}.get(m.group(2), 1/1048576)
use = {}
for l in open(d + '/top.txt'):
    ns, p, c, m = l.split()[:4]; use[(ns, p)] = (cpu(c), mem(m))
rows = []
for it in json.load(open(d + '/pods.json'))['items']:
    ns, p = it['metadata']['namespace'], it['metadata']['name']
    rc = rm = lc = lm = 0.0
    for c in it['spec']['containers']:
        r = c.get('resources', {}); rq = r.get('requests', {}); li = r.get('limits', {})
        rc += cpu(rq.get('cpu')); rm += mem(rq.get('memory')); lc += cpu(li.get('cpu')); lm += mem(li.get('memory'))
    u = use.get((ns, p), (0, 0))
    rows.append((ns, p, rc, u[0], rm, u[1], lc, lm))
print("TOTAL running pods %d | cpu req %.0fm use %.0fm | mem req %.0fMi use %.0fMi" % (
    len(rows), sum(r[2] for r in rows), sum(r[3] for r in rows), sum(r[4] for r in rows), sum(r[5] for r in rows)))
print("%-14s %-58s %7s %7s %7s %7s %7s %7s" % ('ns', 'pod', 'reqCPU', 'useCPU', 'reqMem', 'useMem', 'limCPU', 'limMem'))
for r in sorted(rows, key=lambda r: -(r[2] - r[3])):
    flag = '  <-- over request' if r[3] > r[2] > 0 or (r[4] > 0 and r[5] > r[4]) else ''
    print("%-14s %-58s %7.0f %7.0f %7.0f %7.0f %7.0f %7.0f%s" % (r + (flag,)))
PY
fi

if want throttle; then
  echo "=== 3. throttle (share of CFS periods throttled since container start, >=1%)"
  for f in $(find /sys/fs/cgroup/kubepods.slice -name cpu.stat -path '*cri-containerd*' 2>/dev/null); do
    np=$(awk '/^nr_periods/{print $2}' "$f"); nt=$(awk '/^nr_throttled/{print $2}' "$f"); ts=$(awk '/^throttled_usec/{print $2}' "$f")
    [ "${np:-0}" -gt 1000 ] || continue
    pct=$(( nt * 100 / np )); [ "$pct" -ge 1 ] || continue
    cid=$(basename "$(dirname "$f")" | sed 's/cri-containerd-//; s/\.scope//')
    name=$(crictl inspect -o go-template --template '{{index .status.labels "io.kubernetes.pod.namespace"}}/{{index .status.labels "io.kubernetes.pod.name"}}/{{.status.metadata.name}}' "$cid" 2>/dev/null)
    echo "$pct% throttled_s=$(( ts / 1000000 )) $name"
  done | sort -rn | head -40
fi

if want hpa; then
  echo "=== 4. hpa"
  kubectl get hpa -A --no-headers
fi

if want traffic; then
  echo "=== 5. traffic (all retained ingress log files)"
  D=$(ls -d /var/log/pods/ingress-nginx_ingress-nginx-controller-* 2>/dev/null | tail -1)
  python3 - "$D" <<'PY'
import collections, glob, gzip, re, sys
rx = re.compile(r'\[(\d+/\w+/\d+):(\d\d):\d\d:\d\d [^\]]*\] "[^"]*" (\d{3}) .*? ([\d.]+) \[([^\]]*)\]')
lat = collections.defaultdict(list); err = collections.Counter(); hours = collections.Counter(); days = collections.Counter()
for f in glob.glob(sys.argv[1] + '/controller/*'):
    op = gzip.open if f.endswith('.gz') else open
    for l in op(f, 'rt', errors='ignore'):
        m = rx.search(l)
        if not m: continue
        day, hr, st, rt, up = m.groups()
        lat[up or '(none)'].append(float(rt)); days[day] += 1; hours[(day, hr)] += 1
        if st.startswith('5'): err[up] += 1
print('days covered:', sorted(days.items()))
print('busiest hours (UTC):', hours.most_common(5))
print('%8s %8s %8s %6s  %s' % ('requests', 'p95_s', 'max_s', '5xx', 'upstream'))
for up, v in sorted(lat.items(), key=lambda x: -len(x[1]))[:30]:
    v.sort(); print('%8d %8.3f %8.2f %6d  %s' % (len(v), v[max(0, int(len(v) * .95) - 1)], v[-1], err[up], up))
PY
fi

if want nats; then
  echo "=== 6. nats"
  kubectl -n messaging exec nats-0 -c nats -- sh -c 'wget -qO- "localhost:8222/jsz?streams=1&consumers=1&config=1"' > "$TMP/jsz.json" 2>/dev/null
  kubectl -n messaging exec nats-0 -c nats -- sh -c 'wget -qO- localhost:8222/routez' > "$TMP/routez.json" 2>/dev/null
  python3 - "$TMP" <<'PY'
import collections, json, sys
d = json.load(open(sys.argv[1] + '/jsz.json'))
r = json.load(open(sys.argv[1] + '/routez.json'))
print('route msgs in/out since start:', [(x.get('in_msgs'), x.get('out_msgs')) for x in r.get('routes', [])])
streams = []; reps = collections.Counter(); orphans = []
for a in d.get('account_details', []):
    for s in a.get('stream_detail', []):
        streams.append((s['name'], s['config'].get('num_replicas'), s['state']['messages']))
        for c in s.get('consumer_detail', []) or []:
            cfg = c.get('config', {})
            # num_replicas 0 means "inherit the stream's replica count"
            reps[cfg.get('num_replicas') or s['config'].get('num_replicas')] += 1
            if cfg.get('deliver_subject') and not c.get('push_bound', False):
                orphans.append((s['name'], c['name'], c.get('num_pending')))
print('streams (name, replicas, msgs):', streams)
print('consumers by effective replicas:', dict(reps), 'total', sum(reps.values()))
print('unbound push durables (stream, consumer, pending):')
for o in sorted(orphans): print('  ', *o)
PY
fi
