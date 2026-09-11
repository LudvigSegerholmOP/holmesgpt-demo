#!/usr/bin/env bash
# Install VictoriaLogs + Vector, and register it as a Grafana datasource.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
load_env
setup_docker_config

step "VictoriaLogs ${VER_VM_LOGS_SINGLE}"

log "installing victoria-logs-single (+ vector agent)"
h upgrade --install "${REL_VLOGS}" victoria-metrics/victoria-logs-single \
  --version "${VER_VM_LOGS_SINGLE}" \
  --namespace "${NS_MONITORING}" \
  --values "${REPO_ROOT}/values/victoria-logs-single.yaml" \
  --wait --timeout 10m

wait_rollout "${NS_MONITORING}" 5m \
  statefulset/victorialogs \
  "daemonset/${REL_VLOGS}-vector"

# ---------------------------------------------------------------------------
# Grafana datasource.
#
# Delivered as a labelled ConfigMap so the Grafana sidecar picks it up; this
# keeps it decoupled from the victoria-metrics-k8s-stack release.
# ---------------------------------------------------------------------------
log "registering the VictoriaLogs Grafana datasource"
k -n "${NS_MONITORING}" apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasource-victorialogs
  namespace: ${NS_MONITORING}
  labels:
    grafana_datasource: "1"
data:
  victorialogs-datasource.yaml: |
    apiVersion: 1
    datasources:
      - name: ${GRAFANA_VL_DATASOURCE}
        type: victoriametrics-logs-datasource
        uid: ${GRAFANA_VL_DATASOURCE}
        access: proxy
        url: ${URL_VICTORIALOGS}
        isDefault: false
        jsonData:
          maxLines: 1000
EOF
ok "datasource ConfigMap applied"

# ---------------------------------------------------------------------------
# Confirm logs are actually arriving.
# ---------------------------------------------------------------------------
log "waiting for the first logs to land in VictoriaLogs"
check_logs() {
  incluster_curl "${NS_MONITORING}" \
    -G "${URL_VICTORIALOGS}/select/logsql/query" \
    --data-urlencode 'query=*' \
    --data-urlencode 'limit=1' 2>/dev/null \
  | grep -q '_msg'
}

if retry 30 10 check_logs; then
  ok "VictoriaLogs is ingesting pod logs"
else
  warn "no logs observed in VictoriaLogs yet; vector may still be starting"
fi

ok "VictoriaLogs ready"
