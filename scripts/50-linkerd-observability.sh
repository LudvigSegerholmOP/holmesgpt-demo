#!/usr/bin/env bash
# Wire Linkerd's telemetry into the VictoriaMetrics/Grafana stack:
#   1. VMScrapeConfigs so vmagent scrapes the control plane and every proxy
#   2. Linkerd's official Grafana dashboards, repointed at VictoriaMetrics
#   3. linkerd-viz, with its own Prometheus disabled
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
load_env
setup_docker_config

step "Linkerd observability"

# ---------------------------------------------------------------------------
# 1. Scrape configuration
#
# This is Linkerd's documented "bring your own Prometheus" configuration,
# translated to VMScrapeConfig. The relabelling is not cosmetic: the labelmap
# chain is what turns linkerd.io/proxy-deployment pod labels into the
# `deployment`, `namespace` and `pod` labels that every Linkerd dashboard and
# `linkerd viz stat` query filters on. Simplifying it silently breaks both.
# ---------------------------------------------------------------------------
log "applying VMScrapeConfigs for the Linkerd control plane and proxies"
k apply -f - <<EOF
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMScrapeConfig
metadata:
  name: linkerd-controller
  namespace: ${NS_MONITORING}
spec:
  scrape_interval: 10s
  kubernetesSDConfigs:
    - role: pod
      namespaces:
        names:
          - ${NS_LINKERD}
          - ${NS_LINKERD_VIZ}
  relabelConfigs:
    - source_labels: [__meta_kubernetes_pod_container_port_name]
      action: keep
      regex: admin-http
    - source_labels: [__meta_kubernetes_pod_container_name]
      action: replace
      target_label: component
---
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMScrapeConfig
metadata:
  name: linkerd-proxy
  namespace: ${NS_MONITORING}
spec:
  scrape_interval: 10s
  kubernetesSDConfigs:
    - role: pod
  relabelConfigs:
    - source_labels:
        - __meta_kubernetes_pod_container_name
        - __meta_kubernetes_pod_container_port_name
        - __meta_kubernetes_pod_label_linkerd_io_control_plane_ns
      action: keep
      regex: ^linkerd-proxy;linkerd-admin;${NS_LINKERD}\$
    - source_labels: [__meta_kubernetes_namespace]
      action: replace
      target_label: namespace
    - source_labels: [__meta_kubernetes_pod_name]
      action: replace
      target_label: pod
    # Special-case the k8s "job" label so it does not collide with Prometheus'
    # own "job" label.
    - source_labels: [__meta_kubernetes_pod_label_linkerd_io_proxy_job]
      action: replace
      target_label: k8s_job
    - action: labeldrop
      regex: __meta_kubernetes_pod_label_linkerd_io_proxy_job
    # linkerd.io/proxy-deployment=foo -> deployment=foo (and the same for
    # daemonset, statefulset, job, replicationcontroller, cronjob).
    - action: labelmap
      regex: __meta_kubernetes_pod_label_linkerd_io_proxy_(.+)
    - action: labeldrop
      regex: __meta_kubernetes_pod_label_linkerd_io_proxy_(.+)
    - action: labelmap
      regex: __meta_kubernetes_pod_label_linkerd_io_(.+)
    # Copy all pod labels aside, strip the linkerd_io_ prefix, copy back.
    - action: labelmap
      regex: __meta_kubernetes_pod_label_(.+)
      replacement: __tmp_pod_label_\$1
    - action: labelmap
      regex: __tmp_pod_label_linkerd_io_(.+)
      replacement: __tmp_pod_label_\$1
    - action: labeldrop
      regex: __tmp_pod_label_linkerd_io_(.+)
    - action: labelmap
      regex: __tmp_pod_label_(.+)
EOF
ok "VMScrapeConfigs applied"

# ---------------------------------------------------------------------------
# 2. Grafana dashboards
#
# Fetched from the linkerd2 repo at the pinned ref and rewritten so Grafana can
# provision them from disk: the __inputs/__requires import prompts are stripped
# and the datasource template variable is bound to our VictoriaMetrics
# datasource.
# ---------------------------------------------------------------------------
DASHBOARDS=(
  top-line health namespace deployment pod service
  route authority daemonset statefulset cronjob job replicaset
)

DASH_DIR="${STATE_DIR}/linkerd-dashboards"
mkdir -p "${DASH_DIR}"

log "fetching ${#DASHBOARDS[@]} Linkerd dashboards @ ${LINKERD_DASHBOARD_REF}"
for d in "${DASHBOARDS[@]}"; do
  if [[ ! -s "${DASH_DIR}/${d}.json" ]]; then
    curl -fsSL \
      "https://raw.githubusercontent.com/linkerd/linkerd2/${LINKERD_DASHBOARD_REF}/grafana/dashboards/${d}.json" \
      -o "${DASH_DIR}/${d}.json" \
      || die "could not fetch Linkerd dashboard '${d}'"
  fi
done
ok "dashboards downloaded"

log "rewriting dashboards for the ${GRAFANA_VM_DATASOURCE} datasource"
python3 - "${DASH_DIR}" "${GRAFANA_VM_DATASOURCE}" <<'PY'
import json, pathlib, sys

dash_dir = pathlib.Path(sys.argv[1])
ds = sys.argv[2]

for path in sorted(dash_dir.glob("*.json")):
    if path.name.endswith(".patched.json"):
        continue
    d = json.loads(path.read_text())

    # Provisioned dashboards must not carry import prompts.
    d.pop("__inputs", None)
    d.pop("__requires", None)

    # Grafana assigns its own numeric id; a stale one causes a provisioning
    # conflict. The uid is what our folder/link references rely on.
    d["id"] = None
    d.setdefault("uid", f"linkerd-{path.stem}")
    d["title"] = d.get("title", path.stem)

    # Bind the `datasource` template variable to VictoriaMetrics so every
    # "${datasource}" reference in the panels resolves without user input.
    for var in d.get("templating", {}).get("list", []):
        if var.get("type") == "datasource":
            var["current"] = {"selected": True, "text": ds, "value": ds}
            var["query"] = "prometheus"

    path.with_suffix(".patched.json").write_text(json.dumps(d, separators=(",", ":")))
    print(f"  {path.stem}")
PY

log "creating dashboard ConfigMaps"
for d in "${DASHBOARDS[@]}"; do
  k -n "${NS_MONITORING}" create configmap "linkerd-dashboard-${d}" \
    --from-file="linkerd-${d}.json=${DASH_DIR}/${d}.patched.json" \
    --dry-run=client -o yaml \
  | python3 -c '
import sys, yaml
d = yaml.safe_load(sys.stdin)
d["metadata"]["labels"] = {"grafana_dashboard": "1"}
d["metadata"]["annotations"] = {"grafana_folder": "Linkerd"}
print(yaml.safe_dump(d))
' | k apply -f - >/dev/null
done
ok "${#DASHBOARDS[@]} Linkerd dashboards published to Grafana (folder: Linkerd)"

# ---------------------------------------------------------------------------
# 3. linkerd-viz, backed by VictoriaMetrics
# ---------------------------------------------------------------------------
log "installing linkerd-viz (bundled Prometheus disabled)"
ensure_ns "${NS_LINKERD_VIZ}"
k label namespace "${NS_LINKERD_VIZ}" linkerd.io/extension=viz --overwrite >/dev/null

h upgrade --install "${REL_LINKERD_VIZ}" linkerd-edge/linkerd-viz \
  --version "${VER_LINKERD}" \
  --namespace "${NS_LINKERD_VIZ}" \
  --values "${REPO_ROOT}/values/linkerd-viz.yaml" \
  --set "prometheusUrl=${URL_VMSINGLE}" \
  --wait --timeout 10m

wait_rollout "${NS_LINKERD_VIZ}" 5m

# ---------------------------------------------------------------------------
# Verify the pipeline end to end: proxies -> vmagent -> vmsingle
# ---------------------------------------------------------------------------
log "waiting for Linkerd proxy metrics to reach VictoriaMetrics"
have_linkerd_metrics() {
  incluster_curl "${NS_MONITORING}" \
    -G "${URL_VMSINGLE}/api/v1/query" \
    --data-urlencode 'query=count(request_total)' 2>/dev/null \
  | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    r = d["data"]["result"]
    sys.exit(0 if r and float(r[0]["value"][1]) > 0 else 1)
except Exception:
    sys.exit(1)
'
}

if retry 30 10 have_linkerd_metrics; then
  ok "Linkerd request_total series present in VictoriaMetrics"
else
  warn "no Linkerd proxy metrics yet - expected until meshed workloads receive traffic"
fi

ok "Linkerd observability ready"
