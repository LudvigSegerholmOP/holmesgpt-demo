#!/usr/bin/env bash
# Install the VictoriaMetrics k8s stack (VM operator, VMSingle, VMAgent, Grafana 13).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
load_env
setup_docker_config

step "VictoriaMetrics stack ${VER_VM_K8S_STACK} + Grafana ${GRAFANA_IMAGE_TAG}"

log "installing victoria-metrics-k8s-stack"
h upgrade --install "${REL_VM}" victoria-metrics/victoria-metrics-k8s-stack \
  --version "${VER_VM_K8S_STACK}" \
  --namespace "${NS_MONITORING}" \
  --values "${REPO_ROOT}/values/victoria-metrics-k8s-stack.yaml" \
  --set "grafana.adminUser=${GRAFANA_ADMIN_USER}" \
  --set "grafana.adminPassword=${GRAFANA_ADMIN_PASSWORD}" \
  --set "grafana.image.tag=${GRAFANA_IMAGE_TAG}" \
  --wait --timeout 15m

# The operator reconciles the CRs into workloads after Helm returns.
# Note: VMSingle produces a Deployment (backed by a PVC), not a StatefulSet.
log "waiting for operator-managed workloads"
retry 60 5 k -n "${NS_MONITORING}" get deployment "vmsingle-${REL_VM}" >/dev/null 2>&1 \
  || die "VMSingle Deployment was never created by the operator"
retry 60 5 k -n "${NS_MONITORING}" get deployment "vmagent-${REL_VM}" >/dev/null 2>&1 \
  || die "VMAgent Deployment was never created by the operator"

wait_rollout "${NS_MONITORING}" 10m

# ---------------------------------------------------------------------------
# Prove the pieces actually work rather than merely exist.
# ---------------------------------------------------------------------------
log "verifying VictoriaMetrics query API"
if incluster_curl "${NS_MONITORING}" "${URL_VMSINGLE}/api/v1/query?query=up" \
    | grep -q '"status":"success"'; then
  ok "vmsingle answering PromQL at ${URL_VMSINGLE}"
else
  die "vmsingle did not answer a PromQL query"
fi

log "verifying Grafana version"
gf_version=$(incluster_curl "${NS_MONITORING}" \
  "${URL_GRAFANA}/api/health" 2>/dev/null \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("version","?"))' 2>/dev/null || echo "?")

case "${gf_version}" in
  13.*) ok "Grafana ${gf_version}" ;;
  ?)    warn "could not read Grafana version yet (it may still be installing plugins)" ;;
  *)    die "expected Grafana 13.x, got ${gf_version}" ;;
esac

ok "VictoriaMetrics stack ready"
