#!/usr/bin/env bash
# End-to-end verification. Every check hits a live endpoint; nothing is assumed
# from "helm install succeeded".
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
load_env
setup_docker_config

step "Verification"

PASS=0
FAIL=0

check() {
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then
    printf '  %s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "${name}"
    PASS=$(( PASS + 1 ))
  else
    printf '  %s✗%s %s\n' "${C_RED}" "${C_RESET}" "${name}"
    FAIL=$(( FAIL + 1 ))
  fi
}

report() { printf '  %s·%s %s: %s\n' "${C_DIM}" "${C_RESET}" "$1" "$2"; }

# promql <query> - succeeds when the query returns a scalar > 0
promql() {
  incluster_curl "${NS_MONITORING}" -G "${URL_VMSINGLE}/api/v1/query" \
    --data-urlencode "query=$1" 2>/dev/null \
  | python3 -c '
import sys, json
try:
    r = json.load(sys.stdin)["data"]["result"]
except Exception:
    sys.exit(1)
sys.exit(0 if r and float(r[0]["value"][1]) > 0 else 1)
'
}

promql_value() {
  incluster_curl "${NS_MONITORING}" -G "${URL_VMSINGLE}/api/v1/query" \
    --data-urlencode "query=$1" 2>/dev/null \
  | python3 -c '
import sys, json
try:
    r = json.load(sys.stdin)["data"]["result"]
    print(int(float(r[0]["value"][1])) if r else 0)
except Exception:
    print("?")
' 2>/dev/null || echo "?"
}

# ---------------------------------------------------------------------------
printf '\n%sCluster%s\n' "${C_BOLD}" "${C_RESET}"

minikube_running() { minikube status -p "${MINIKUBE_PROFILE}" >/dev/null 2>&1; }
nodes_ready() {
  k get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
    | grep -q True
}
no_bad_pods() {
  local bad
  bad=$(k get pods -A --no-headers 2>/dev/null \
        | awk '$4!="Running" && $4!="Completed" && $4!="Succeeded"' | wc -l | tr -d ' ')
  [[ "${bad}" -eq 0 ]]
}

check "minikube profile '${MINIKUBE_PROFILE}' running" minikube_running
check "all nodes Ready" nodes_ready
check "no pods in a bad state" no_bad_pods
no_bad_pods || k get pods -A --no-headers | awk '$4!="Running" && $4!="Completed" && $4!="Succeeded" {printf "      %s\n", $0}'

# ---------------------------------------------------------------------------
printf '\n%sVictoriaMetrics%s\n' "${C_BOLD}" "${C_RESET}"
check "vmsingle answers PromQL" promql 'vm_app_version'
check "kube-state-metrics scraped" promql 'count(kube_pod_info)'
check "node-exporter scraped" promql 'count(node_cpu_seconds_total)'
check "cAdvisor container metrics" promql 'count(container_memory_working_set_bytes)'
report "active time series" "$(promql_value 'vm_cache_entries{type="storage/hour_metric_ids"}')"
report "scrape targets up" "$(promql_value 'count(up==1)')"

# ---------------------------------------------------------------------------
printf '\n%sVictoriaLogs%s\n' "${C_BOLD}" "${C_RESET}"

vl_healthy() {
  incluster_curl "${NS_MONITORING}" "${URL_VICTORIALOGS}/health" 2>/dev/null | grep -qi ok
}
# vl_has <logsql query> - succeeds when at least one log line matches
vl_has() {
  incluster_curl "${NS_MONITORING}" -G "${URL_VICTORIALOGS}/select/logsql/query" \
    --data-urlencode "query=$1" --data-urlencode "limit=1" 2>/dev/null | grep -q '_msg'
}

check "VictoriaLogs is up" vl_healthy
check "logs ingested from the demo namespace" vl_has "kubernetes.pod_namespace:${NS_DEMO}"
check "logs ingested from the frontend" vl_has "kubernetes.pod_namespace:${NS_DEMO} kubernetes.container_name:server"
check "logs ingested from linkerd proxies" vl_has "kubernetes.container_name:linkerd-proxy"

# ---------------------------------------------------------------------------
printf '\n%sGrafana%s\n' "${C_BOLD}" "${C_RESET}"
gf_auth="${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}"

gf_version=$(incluster_curl "${NS_MONITORING}" "${URL_GRAFANA}/api/health" 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("version","?"))' 2>/dev/null || echo "?")
report "version" "${gf_version}"

is_grafana_13() { [[ "${gf_version}" == 13.* ]]; }
check "Grafana is version 13.x" is_grafana_13

# /api/datasources/uid/<uid>/health proxies a real query to the backend, so this
# fails if the datasource is merely defined but unreachable.
ds_healthy() {
  incluster_curl "${NS_MONITORING}" -u "${gf_auth}" \
    "${URL_GRAFANA}/api/datasources/uid/$1/health" 2>/dev/null \
  | grep -q '"status":"OK"'
}
check "VictoriaMetrics datasource healthy" ds_healthy "${GRAFANA_VM_DATASOURCE}"
check "VictoriaLogs datasource healthy" ds_healthy "${GRAFANA_VL_DATASOURCE}"

gf_search() {
  incluster_curl "${NS_MONITORING}" -u "${gf_auth}" \
    "${URL_GRAFANA}/api/search?type=dash-db&limit=500$1" 2>/dev/null \
  | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0
}
dash_total=$(gf_search "")
dash_linkerd=$(gf_search "&query=Linkerd")
report "dashboards provisioned" "${dash_total}"
report "Linkerd dashboards" "${dash_linkerd}"

has_linkerd_dashboards() { [[ "${dash_linkerd}" -gt 0 ]]; }
check "Linkerd dashboards imported" has_linkerd_dashboards

# ---------------------------------------------------------------------------
printf '\n%sLinkerd%s\n' "${C_BOLD}" "${C_RESET}"

cp_ready() { k -n "${NS_LINKERD}" get deploy linkerd-destination linkerd-identity linkerd-proxy-injector >/dev/null 2>&1; }
viz_ready() { k -n "${NS_LINKERD_VIZ}" get deploy metrics-api >/dev/null 2>&1; }
viz_has_no_prometheus() { ! k -n "${NS_LINKERD_VIZ}" get deploy prometheus >/dev/null 2>&1; }
all_meshed() {
  local unmeshed
  unmeshed=$(k -n "${NS_DEMO}" get pods \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.initContainers[*].name}{" "}{.spec.containers[*].name}{"\n"}{end}' 2>/dev/null \
    | grep -v 'linkerd-proxy' | grep -c . || true)
  [[ "${unmeshed}" -eq 0 ]]
}

check "control plane deployments exist" cp_ready
check "every demo pod has a linkerd-proxy" all_meshed
check "linkerd-viz metrics-api present" viz_ready
check "linkerd-viz bundled Prometheus disabled" viz_has_no_prometheus
check "Linkerd proxy metrics in VictoriaMetrics" promql 'count(request_total)'
check "mTLS traffic observed" promql 'count(request_total{tls="true"})'
report "meshed request rate" "$(promql_value "round(sum(rate(request_total{namespace=\"${NS_DEMO}\"}[5m])))") req/s"

if command -v linkerd >/dev/null 2>&1; then
  linkerd_proxy_check() {
    linkerd check --proxy --context "${MINIKUBE_PROFILE}" --namespace "${NS_DEMO}" --wait 1m
  }
  check "linkerd check --proxy" linkerd_proxy_check
fi

# ---------------------------------------------------------------------------
printf '\n%sOnline Boutique%s\n' "${C_BOLD}" "${C_RESET}"

fe_image=$(k -n "${NS_DEMO}" get deploy frontend \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "?")
other_image=$(k -n "${NS_DEMO}" get deploy cartservice \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "?")
report "frontend image" "${fe_image}"
report "cartservice image" "${other_image}"

frontend_image_ok() { [[ "${fe_image}" == "${FRONTEND_IMAGE_REPO}:${FRONTEND_IMAGE_TAG}" ]]; }
other_image_untouched() { [[ "${other_image}" == "${OB_UPSTREAM_IMAGE_REPO}/"* ]]; }
workloads_available() {
  local n
  n=$(k -n "${NS_DEMO}" get deploy \
      -o jsonpath='{range .items[*]}{.status.availableReplicas}{"\n"}{end}' 2>/dev/null \
      | grep -c '^[1-9]' || true)
  [[ "${n}" -ge 11 ]]
}
frontend_serves() {
  incluster_curl "${NS_DEMO}" -o /dev/null -w '%{http_code}' \
    "http://frontend.${NS_DEMO}.svc.cluster.local:80/" 2>/dev/null | grep -q 200
}

loadgen_profile_mounted() {
  k -n "${NS_DEMO}" get deploy loadgenerator \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="main")].volumeMounts[?(@.name=="locustfile")].mountPath}' 2>/dev/null \
    | grep -q '^/loadgen/locustfile.py$'
}
serviceprofiles_present() {
  k -n "${NS_DEMO}" get serviceprofile \
    "frontend.${NS_DEMO}.svc.cluster.local" \
    "productcatalogservice.${NS_DEMO}.svc.cluster.local" >/dev/null 2>&1
}
release_dashboard_loaded() {
  incluster_curl "${NS_MONITORING}" -o /dev/null -w '%{http_code}' \
    "${URL_GRAFANA}/api/dashboards/uid/${OB_DASHBOARD_UID}" 2>/dev/null | grep -q '^200$'
}

check "frontend image matches configuration" frontend_image_ok
check "other services still on the upstream image" other_image_untouched
check "all workloads available" workloads_available
check "frontend serves HTTP 200" frontend_serves
check "load generator runs the repo load profile" loadgen_profile_mounted
check "ServiceProfiles for frontend and productcatalogservice" serviceprofiles_present
check "per-route metrics from the frontend proxy" promql "count(route_request_total{namespace=\"${NS_DEMO}\",deployment=\"frontend\",direction=\"inbound\"})"
check "release-impact dashboard in Grafana" release_dashboard_loaded
report "frontend p95" "$(promql_value "histogram_quantile(0.95, sum by (le) (rate(response_latency_ms_bucket{namespace=\"${NS_DEMO}\",deployment=\"frontend\",direction=\"inbound\"}[5m])))") ms"
report "catalog RPCs per frontend request" "$(promql_value "sum(rate(request_total{namespace=\"${NS_DEMO}\",deployment=\"frontend\",direction=\"outbound\",dst_deployment=\"productcatalogservice\"}[5m])) / sum(rate(request_total{namespace=\"${NS_DEMO}\",deployment=\"frontend\",direction=\"inbound\"}[5m]))")"

# ---------------------------------------------------------------------------
printf '\n%sHolmesGPT%s\n' "${C_BOLD}" "${C_RESET}"
holmes_ready() {
  k -n "${NS_HOLMES}" get deploy "${HOLMES_FULLNAME}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '^[1-9]'
}
check "Holmes pod ready" holmes_ready

model_json=$(incluster_curl "${NS_HOLMES}" "${URL_HOLMES}/api/model" 2>/dev/null || true)
report "models" "$(printf '%s' "${model_json}" | head -c 140)"
holmes_api_up() { [[ -n "${model_json}" ]]; }
check "Holmes API answers" holmes_api_up

# Holmes self-reports, per toolset, whether it actually reached its backend.
# This is the meaningful integration check. Holmes 0.40 has no /api/toolsets
# endpoint: /api/info carries only the counts, and the per-toolset verdicts are
# logged by the server ("✅ Toolset <name>" / "❌ Toolset <name>: <reason>")
# when it (re)checks them, which the /api/info call above triggers.
info_json=$(incluster_curl "${NS_HOLMES}" "${URL_HOLMES}/api/info" 2>/dev/null || true)
summary=$(printf '%s' "${info_json}" | python3 -c "$(cat <<'PY'
import sys, json
try:
    s = json.load(sys.stdin)["toolsets_summary"]
    print("%d enabled, %d failed, %d disabled of %d"
          % (s["enabled"], s["failed"], s["disabled"], s["total"]))
except Exception:
    pass
PY
)" 2>/dev/null || true)
[[ -n "${summary}" ]] && report "toolsets" "${summary}"

toolset_log=$(k -n "${NS_HOLMES}" logs "deploy/${HOLMES_FULLNAME}" 2>/dev/null \
  | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'Toolset [a-z0-9/_-]+' || true)
if [[ -n "${toolset_log}" ]]; then
  printf '%s\n' "${toolset_log}" | python3 -c "$(cat <<'PY'
import re, sys
want = [
    ("kubernetes/core",    "Kubernetes"),
    ("prometheus/metrics", "VictoriaMetrics"),
    ("victorialogs",       "VictoriaLogs"),
    ("grafana/dashboards", "Grafana"),
    ("github",             "GitHub"),
]
# Keep the most recent verdict per toolset; the server rechecks periodically.
seen = {}
for line in sys.stdin:
    m = re.search(r"(✅|❌)\s+Toolset\s+([a-z0-9/_-]+)(?::\s*(.*))?$", line.strip())
    if m:
        seen[m.group(2)] = (m.group(1) == "✅", (m.group(3) or "").strip())
for name, label in want:
    if name not in seen:
        print("  \033[2m·\033[0m %s: not configured" % label)
        continue
    good, msg = seen[name]
    mark = "\033[32m✓\033[0m" if good else "\033[33m!\033[0m"
    print("  %s %s: %s" % (mark, label, "enabled" if good else "failed - " + msg[:90]))
PY
)"
else
  warn "no toolset verdicts in the Holmes log yet; inspect with:"
  warn "  kubectl --context ${MINIKUBE_PROFILE} -n ${NS_HOLMES} logs deploy/${HOLMES_FULLNAME}"
fi

# ---------------------------------------------------------------------------
printf '\n%sSummary%s\n' "${C_BOLD}" "${C_RESET}"
if (( FAIL > 0 )); then
  printf '  %s%d passed%s, %s%d failed%s\n' "${C_GREEN}" "${PASS}" "${C_RESET}" "${C_RED}" "${FAIL}" "${C_RESET}"
else
  printf '  %s%d passed%s\n' "${C_GREEN}" "${PASS}" "${C_RESET}"
fi

cat <<EOF

${C_BOLD}Access${C_RESET}
  Grafana          kubectl --context ${MINIKUBE_PROFILE} -n ${NS_MONITORING} port-forward svc/${REL_VM}-grafana 3000:80
                   http://localhost:3000  (${GRAFANA_ADMIN_USER} / ${GRAFANA_ADMIN_PASSWORD})
                   release impact: http://localhost:3000/d/${OB_DASHBOARD_UID}
  Online Boutique  minikube -p ${MINIKUBE_PROFILE} service -n ${NS_DEMO} frontend-external
  Linkerd viz      linkerd viz dashboard --context ${MINIKUBE_PROFILE}
  VictoriaLogs     kubectl --context ${MINIKUBE_PROFILE} -n ${NS_MONITORING} port-forward svc/victorialogs 9428:9428
  HolmesGPT        kubectl --context ${MINIKUBE_PROFILE} -n ${NS_HOLMES} port-forward svc/${HOLMES_FULLNAME} 5050:80

${C_BOLD}Ask HolmesGPT something${C_RESET}
  curl -s localhost:5050/api/chat \\
    -H 'Content-Type: application/json' \\
    -d '{"ask":"Why is the frontend slow? Check Linkerd latency metrics and recent commits."}'
EOF

(( FAIL == 0 ))
