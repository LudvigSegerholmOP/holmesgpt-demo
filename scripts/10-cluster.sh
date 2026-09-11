#!/usr/bin/env bash
# Create the minikube cluster and its namespaces.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
load_env
setup_docker_config

step "Cluster: minikube profile '${MINIKUBE_PROFILE}'"

if minikube status -p "${MINIKUBE_PROFILE}" >/dev/null 2>&1; then
  ok "profile '${MINIKUBE_PROFILE}' already running"
else
  log "starting minikube (driver=${MINIKUBE_DRIVER} cpus=${MINIKUBE_CPUS} memory=${MINIKUBE_MEMORY}MB disk=${MINIKUBE_DISK})"
  args=(
    start
    -p "${MINIKUBE_PROFILE}"
    --driver="${MINIKUBE_DRIVER}"
    --cpus="${MINIKUBE_CPUS}"
    --memory="${MINIKUBE_MEMORY}"
    --disk-size="${MINIKUBE_DISK}"
    # Linkerd's proxy-injector and the VM operator both use admission webhooks;
    # nothing exotic is required of the CNI, so the default is fine.
    --addons=metrics-server
  )
  [[ -n "${K8S_VERSION}" ]] && args+=(--kubernetes-version="${K8S_VERSION}")
  minikube "${args[@]}"
fi

# ---------------------------------------------------------------------------
# amd64 emulation for Apple Silicon.
#
# Every Online Boutique image (upstream and the ghcr.io frontend build) is
# published for linux/amd64 only, so on an arm64 node the app containers die
# with "exec format error". Register QEMU user-mode emulation via binfmt_misc
# so the node's Docker can run them. The kernel in the minikube ISO has
# binfmt_misc built in but does not mount it, and registrations live in kernel
# memory only, so this runs on every start - not just on cluster creation.
# ---------------------------------------------------------------------------
node_arch=$(k get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || true)
if [[ -n "${node_arch}" && "${node_arch}" != "amd64" ]]; then
  if minikube -p "${MINIKUBE_PROFILE}" ssh -- "test -e /proc/sys/fs/binfmt_misc/qemu-x86_64" >/dev/null 2>&1; then
    ok "node is ${node_arch}; amd64 emulation already registered"
  else
    log "node is ${node_arch}; registering QEMU amd64 emulation (binfmt_misc)"
    minikube -p "${MINIKUBE_PROFILE}" ssh -- "
      set -e
      mountpoint -q /proc/sys/fs/binfmt_misc \
        || sudo mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
      docker run --privileged --rm ${BINFMT_IMAGE} --install amd64 >/dev/null 2>&1
      test -e /proc/sys/fs/binfmt_misc/qemu-x86_64
    " || die "failed to register amd64 emulation on the ${node_arch} node"
    ok "amd64 emulation registered (qemu-x86_64)"
  fi
  dim "     amd64 images run under QEMU - expect slow starts; probes are relaxed in step 60"
fi

log "cluster info"
k version -o json 2>/dev/null | python3 -c '
import sys, json
d = json.load(sys.stdin)
print("  server:", d.get("serverVersion", {}).get("gitVersion", "?"))
print("  client:", d.get("clientVersion", {}).get("gitVersion", "?"))
' || true

log "creating namespaces"
# linkerd-viz is intentionally NOT created here. `linkerd check` treats the
# existence of that namespace as "viz is installed" and fails until it is, which
# would make step 20's health check misleading. Step 50 creates it.
ensure_ns "${NS_MONITORING}" "${NS_LINKERD}" "${NS_DEMO}" "${NS_HOLMES}"

# Linkerd requires these on its own namespaces so the proxy-injector does not
# try to inject the control plane into itself.
k label namespace "${NS_LINKERD}"     linkerd.io/is-control-plane=true --overwrite >/dev/null
k annotate namespace "${NS_LINKERD}"  linkerd.io/inject=disabled --overwrite >/dev/null

# Everything deployed into the demo namespace gets a Linkerd sidecar.
k annotate namespace "${NS_DEMO}" linkerd.io/inject=enabled --overwrite >/dev/null
ok "namespace ${NS_DEMO} annotated linkerd.io/inject=enabled"

ok "cluster ready"
