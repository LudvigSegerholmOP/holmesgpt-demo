#!/usr/bin/env bash
# Destroy the demo cluster.
#
#   ./teardown.sh          delete the minikube profile
#   ./teardown.sh --certs  also delete the generated Linkerd certificates
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_env

DROP_CERTS=false
[[ "${1:-}" == "--certs" ]] && DROP_CERTS=true

step "Teardown"

if minikube profile list -o json 2>/dev/null | grep -q "\"Name\":\"${MINIKUBE_PROFILE}\""; then
  log "deleting minikube profile '${MINIKUBE_PROFILE}'"
  minikube delete -p "${MINIKUBE_PROFILE}"
  ok "cluster deleted"
else
  warn "no minikube profile named '${MINIKUBE_PROFILE}'"
fi

rm -rf "${REPO_ROOT}/.state"
ok "cleared .state/"

if ${DROP_CERTS}; then
  rm -rf "${REPO_ROOT}/certs"
  ok "cleared certs/"
else
  dim "     kept certs/ (pass --certs to remove)"
fi
