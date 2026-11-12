{{- define "app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "app.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "app.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" -}}
{{- end -}}

{{- define "app.labels" -}}
helm.sh/chart: {{ include "app.chart" . }}
{{ include "app.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Container image for the main workload. image.digest (optional) pins an exact build for
third-party images that only publish a moving tag; CI-built services keep using image.tag.
*/}}
{{- define "app.image" -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- else -}}
{{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- end -}}
{{- end -}}

{{/*
wait-for-deps init container (opt-in through .Values.startupDependencies).
After a node reboot every pod starts at once; this holds the app container back until
each listed dependency answers, so a service does not exit on its first auth or database
call and sit in CrashLoopBackOff. Each entry is {name, url} for an HTTP GET that must
return 2xx, or {name, tcp: "host:port"} for a plain TCP connect. All entries share one
total budget (startupWait.timeoutSeconds, 600 by default). When the budget runs out the
container logs which dependency never answered and exits 0, so the app still starts and
a dependency that stays down can never block a rollout for good.
Runbook: docs/STARTUP-ORDER.md.
*/}}
{{- define "app.waitForDepsContainer" -}}
{{- $wait := .Values.startupWait | default dict -}}
- name: wait-for-deps
  image: {{ $wait.image | default "busybox:1.36" | quote }}
  imagePullPolicy: IfNotPresent
  env:
    - name: WAIT_TIMEOUT_SECONDS
      value: {{ $wait.timeoutSeconds | default 600 | quote }}
    - name: WAIT_INTERVAL_SECONDS
      value: {{ $wait.intervalSeconds | default 5 | quote }}
    - name: STARTUP_DEPS
      value: |
        {{- range .Values.startupDependencies }}
        {{- if .url }}
        {{ required "startupDependencies[].name is required" .name }} http {{ .url }}
        {{- else if .tcp }}
        {{ required "startupDependencies[].name is required" .name }} tcp {{ .tcp }}
        {{- else }}
        {{- fail (printf "startupDependencies entry %q needs url or tcp" (.name | default "")) }}
        {{- end }}
        {{- end }}
  command: ["sh", "-c"]
  args:
    - |
      deadline=$(( $(date +%s) + WAIT_TIMEOUT_SECONDS ))
      tcp_ok=1
      if ! nc 2>&1 | grep -q -- '-z'; then
        tcp_ok=0
        echo "wait-for-deps: this nc has no -z option, tcp checks are skipped"
      fi
      check() {
        case "$1" in
          http) wget -q -T 3 -O /dev/null "$2" ;;
          tcp) [ "$tcp_ok" = 1 ] || return 0; nc -z -w 3 "${2%:*}" "${2##*:}" ;;
          *) return 0 ;;
        esac
      }
      echo "$STARTUP_DEPS" | while read -r name kind target; do
        [ -n "$name" ] || continue
        start=$(date +%s)
        until check "$kind" "$target"; do
          if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "wait-for-deps: $name ($target) still not answering when the ${WAIT_TIMEOUT_SECONDS}s budget ran out, starting anyway"
            continue 2
          fi
          sleep "$WAIT_INTERVAL_SECONDS"
        done
        echo "wait-for-deps: $name ready after $(( $(date +%s) - start ))s"
      done
      exit 0
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop: ["ALL"]
    seccompProfile:
      type: RuntimeDefault
  resources:
    requests:
      cpu: 5m
      memory: 8Mi
    limits:
      cpu: 50m
      memory: 32Mi
{{- end -}}
