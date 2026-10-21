#!/bin/bash
# Read-only audit of secret references in cluster deployments. Prints names and presence only,
# never values.
#
# Usage (one "<namespace> <deployment>" per line on stdin):
#   printf 'pos pos-api\ntreasury treasury-api\n' | scripts/tools/audit-secret-refs.sh
#
# Reports secrets a deployment references that do not exist, and keys missing from existing ones.
# A reference marked optional fails silently at runtime, so a missing optional key is a quiet outage
# (for example an empty service key makes a gate fail open or a verifier fail closed).
set -u

while read -r ns dep; do
  [ -z "${ns:-}" ] && continue
  refs=$(kubectl get deploy -n "$ns" "$dep" -o jsonpath='{range .spec.template.spec.containers[*].env[?(@.valueFrom.secretKeyRef)]}{.name}{"|"}{.valueFrom.secretKeyRef.name}{"|"}{.valueFrom.secretKeyRef.key}{"|"}{.valueFrom.secretKeyRef.optional}{"\n"}{end}' 2>/dev/null)
  envfrom=$(kubectl get deploy -n "$ns" "$dep" -o jsonpath='{range .spec.template.spec.containers[*].envFrom[*]}{.secretRef.name}{" "}{end}' 2>/dev/null)
  echo "== $ns/$dep envFrom: ${envfrom:-none}"

  declare -A keys_of=()
  for s in $(echo "$refs" | cut -d'|' -f2 | sort -u) $envfrom; do
    [ -z "$s" ] && continue
    if ! have=$(kubectl get secret -n "$ns" "$s" -o go-template='{{range $k,$v := .data}}{{$k}} {{end}}' 2>/dev/null); then
      echo "   MISSING SECRET $s"
      continue
    fi
    keys_of[$s]="$have"
  done

  echo "$refs" | while IFS='|' read -r name sec key opt; do
    [ -z "$name" ] && continue
    case " ${keys_of[$sec]:-} " in
      *" $key "*) ;;
      *) echo "   MISSING KEY $name -> $sec/$key (optional=$opt)" ;;
    esac
  done
  unset keys_of
done
