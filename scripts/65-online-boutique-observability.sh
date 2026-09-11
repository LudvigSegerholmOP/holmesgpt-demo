#!/usr/bin/env bash
# Application-level observability for Online Boutique: the "Frontend release
# impact" Grafana dashboard, plus a check that the per-route metrics it relies
# on are flowing. The Linkerd ServiceProfiles behind those metrics are applied
# by scripts/60-online-boutique.sh, before the pods exist (a proxy only reads a
# profile when it first resolves the destination).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
load_env

step "Online Boutique observability"

# ---------------------------------------------------------------------------
# Dashboard, published the same way as the Linkerd ones: a labelled
#    ConfigMap the Grafana sidecar picks up, filed under its own folder.
# ---------------------------------------------------------------------------
dashboard="${REPO_ROOT}/manifests/grafana/online-boutique-release-impact.json"
dash_uid=$(python3 -c 'import sys,json;print(json.load(open(sys.argv[1]))["uid"])' "${dashboard}")
[[ "${dash_uid}" == "${OB_DASHBOARD_UID}" ]] \
  || die "dashboard uid '${dash_uid}' does not match OB_DASHBOARD_UID '${OB_DASHBOARD_UID}'"

log "publishing the release-impact dashboard (folder: ${OB_DASHBOARD_FOLDER})"
k -n "${NS_MONITORING}" create configmap "ob-dashboard-frontend-release-impact" \
  --from-file="${OB_DASHBOARD_UID}.json=${dashboard}" \
  --dry-run=client -o yaml \
| python3 -c '
import sys, yaml
d = yaml.safe_load(sys.stdin)
d["metadata"]["labels"] = {"grafana_dashboard": "1"}
d["metadata"]["annotations"] = {"grafana_folder": sys.argv[1]}
print(yaml.safe_dump(d))
' "${OB_DASHBOARD_FOLDER}" | k apply -f - >/dev/null
ok "dashboard ConfigMap applied"

# ---------------------------------------------------------------------------
# Verify: route metrics flowing, dashboard registered.
# ---------------------------------------------------------------------------
log "waiting for per-route metrics from the frontend proxy"
have_route_metrics() {
  incluster_curl "${NS_MONITORING}" \
    -G "${URL_VMSINGLE}/api/v1/query" \
    --data-urlencode "query=count(route_request_total{namespace=\"${NS_DEMO}\",deployment=\"frontend\",direction=\"inbound\",rt_route!=\"\"})" 2>/dev/null \
  | python3 -c '
import sys, json
try:
    r = json.load(sys.stdin)["data"]["result"]
    sys.exit(0 if r and float(r[0]["value"][1]) > 0 else 1)
except Exception:
    sys.exit(1)
'
}
if retry 30 10 have_route_metrics; then
  ok "route_request_total present for the frontend"
else
  warn "no per-route metrics: the pods predate the ServiceProfiles. Restart them:"
  warn "  kubectl --context ${MINIKUBE_PROFILE} -n ${NS_DEMO} rollout restart deploy"
fi

log "waiting for Grafana to load the dashboard"
dashboard_loaded() {
  incluster_curl "${NS_MONITORING}" -o /dev/null -w '%{http_code}' \
    "${URL_GRAFANA}/api/dashboards/uid/${OB_DASHBOARD_UID}" 2>/dev/null | grep -q '^200$'
}
if retry 24 5 dashboard_loaded; then
  ok "dashboard '${OB_DASHBOARD_UID}' registered in Grafana"
else
  die "Grafana never registered dashboard ${OB_DASHBOARD_UID}; check the dashboard sidecar logs"
fi

ok "Online Boutique observability ready"
