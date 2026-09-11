#!/usr/bin/env bash
# Deploy the Google Online Boutique microservices demo into the meshed namespace,
# with the frontend image swapped and the load profile replaced via a kustomize
# post-renderer.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
load_env
setup_docker_config

step "Online Boutique ${VER_ONLINE_BOUTIQUE}"

log "frontend image: ${FRONTEND_IMAGE_REPO}:${FRONTEND_IMAGE_TAG}"

# The post-renderer reads these from the environment.
export OB_UPSTREAM_IMAGE_REPO FRONTEND_IMAGE_REPO FRONTEND_IMAGE_TAG

# Sanity: the namespace must be marked for injection before pods are created,
# otherwise they come up unmeshed and need a restart.
inject=$(k get namespace "${NS_DEMO}" -o jsonpath='{.metadata.annotations.linkerd\.io/inject}' 2>/dev/null || true)
[[ "${inject}" == "enabled" ]] \
  || die "namespace ${NS_DEMO} is not annotated linkerd.io/inject=enabled (run scripts/10-cluster.sh)"

# ---------------------------------------------------------------------------
# Load profile. The locustfile is shipped as a ConfigMap and mounted over the
# image's built-in one by the post-renderer, which also sets USERS/RATE. The
# file's hash goes on the pod template so an edited profile rolls the pod.
# ---------------------------------------------------------------------------
locustfile="${REPO_ROOT}/manifests/online-boutique/locustfile.py"
log "publishing the load profile (${LOADGEN_USERS} users, spawn rate ${LOADGEN_RATE}/s)"
k -n "${NS_DEMO}" create configmap "${OB_LOADGEN_CONFIGMAP}" \
  --from-file="locustfile.py=${locustfile}" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
OB_LOADGEN_CHECKSUM=$(shasum -a 256 "${locustfile}" | cut -c1-16)
OB_LOADGEN_USERS="${LOADGEN_USERS}"
OB_LOADGEN_RATE="${LOADGEN_RATE}"
export OB_LOADGEN_CONFIGMAP OB_LOADGEN_CHECKSUM OB_LOADGEN_USERS OB_LOADGEN_RATE
ok "ConfigMap ${NS_DEMO}/${OB_LOADGEN_CONFIGMAP} applied"

# The images are amd64-only. On any other node architecture they run under
# QEMU (registered in step 10) and start slowly enough that the chart's probes
# kill them, so have the post-renderer relax every probe.
node_arch=$(k get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}')
OB_RELAX_PROBES=false
if [[ "${node_arch}" != "amd64" ]]; then
  OB_RELAX_PROBES=true
  warn "node is ${node_arch}: amd64 images run under emulation, relaxing probes"
fi
export OB_RELAX_PROBES

# Helm 4 resolves --post-renderer to a plugin name rather than an executable
# path, so expose the repo-local plugin directory for this command only. The
# user's own plugin directory is kept on the path.
user_plugins="$(helm env HELM_PLUGINS 2>/dev/null | tr -d '"')"
export HELM_PLUGINS="${REPO_ROOT}/manifests/helm-plugins${user_plugins:+:${user_plugins}}"

# ---------------------------------------------------------------------------
# ServiceProfiles go in BEFORE the chart. A proxy only picks up the profile
# for a destination when it first resolves it, so pods that predate the
# profile never report per-route metrics until they are restarted.
# ---------------------------------------------------------------------------
log "applying Linkerd ServiceProfiles (frontend routes, productcatalogservice methods)"
k apply -f "${REPO_ROOT}/manifests/online-boutique/serviceprofiles.yaml" >/dev/null
ok "ServiceProfiles applied"

log "installing the onlineboutique chart"
h upgrade --install "${REL_OB}" \
  "oci://us-docker.pkg.dev/online-boutique-ci/charts/onlineboutique" \
  --version "${VER_ONLINE_BOUTIQUE}" \
  --namespace "${NS_DEMO}" \
  --post-renderer ob-frontend-image \
  --set frontend.externalService=true \
  --set frontend.platform=local \
  --set networkPolicies.create=false \
  --set authorizationPolicies.create=false \
  --set sidecars.create=false \
  --set opentelemetryCollector.create=false \
  --set googleCloudOperations.profiler=false \
  --set googleCloudOperations.tracing=false \
  --set googleCloudOperations.metrics=false \
  --wait --timeout 15m

wait_rollout "${NS_DEMO}" 10m

# ---------------------------------------------------------------------------
# Verify the frontend really is the image we asked for, and only the frontend.
# ---------------------------------------------------------------------------
actual_frontend=$(k -n "${NS_DEMO}" get deployment frontend \
  -o jsonpath='{.spec.template.spec.containers[0].image}')
expected="${FRONTEND_IMAGE_REPO}:${FRONTEND_IMAGE_TAG}"

if [[ "${actual_frontend}" == "${expected}" ]]; then
  ok "frontend image = ${actual_frontend}"
else
  die "frontend image mismatch: expected ${expected}, got ${actual_frontend}"
fi

other=$(k -n "${NS_DEMO}" get deployment cartservice \
  -o jsonpath='{.spec.template.spec.containers[0].image}')
ok "cartservice image untouched = ${other}"

lg_users=$(k -n "${NS_DEMO}" get deployment loadgenerator \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="main")].env[?(@.name=="USERS")].value}')
lg_mount=$(k -n "${NS_DEMO}" get deployment loadgenerator \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="main")].volumeMounts[?(@.name=="locustfile")].mountPath}')
if [[ "${lg_users}" == "${LOADGEN_USERS}" && "${lg_mount}" == "/loadgen/locustfile.py" ]]; then
  ok "loadgenerator runs the repo load profile with ${lg_users} users"
else
  die "loadgenerator patch missing: USERS=${lg_users:-?} mount=${lg_mount:-none}"
fi

# ---------------------------------------------------------------------------
# Verify every workload is meshed.
# ---------------------------------------------------------------------------
# The proxy is a native sidecar (an initContainer with restartPolicy: Always),
# so it appears under initContainers, not containers.
log "checking Linkerd sidecar injection"
unmeshed=$(k -n "${NS_DEMO}" get pods \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.initContainers[*].name}{" "}{.spec.containers[*].name}{"\n"}{end}' \
  | awk '$0 !~ /linkerd-proxy/ {print $1}')

if [[ -n "${unmeshed}" ]]; then
  warn "pods without a linkerd-proxy sidecar:"
  printf '       %s\n' ${unmeshed}
  warn "restart them with: kubectl -n ${NS_DEMO} rollout restart deploy"
else
  meshed_count=$(k -n "${NS_DEMO}" get pods --no-headers | wc -l | tr -d ' ')
  ok "all ${meshed_count} pods are meshed"
fi

ok "Online Boutique ready"
