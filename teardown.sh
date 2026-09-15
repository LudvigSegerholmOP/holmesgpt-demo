#!/usr/bin/env bash
# Destroy the demo cluster.
#
#   ./teardown.sh              back up the chat volumes to backups/, then delete the minikube profile
#   ./teardown.sh --no-backup  skip the backup (backups/ is left as it was)
#   ./teardown.sh --certs      also delete the generated Linkerd certificates
#
# The next ./setup.sh restores backups/ into the fresh cluster (step 75).
# Delete backups/ to start with empty chats instead.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_env

DROP_CERTS=false
DO_BACKUP=true
for arg in "$@"; do
  case "${arg}" in
    --certs) DROP_CERTS=true ;;
    --no-backup) DO_BACKUP=false ;;
    -h|--help) sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: ${arg}" ;;
  esac
done

step "Teardown"

if minikube profile list -o json 2>/dev/null | grep -q "\"Name\":\"${MINIKUBE_PROFILE}\""; then
  if ${DO_BACKUP}; then
    if k --request-timeout=10s get namespace "${NS_HOLMES}" >/dev/null 2>&1; then
      "${REPO_ROOT}/backup.sh"
    else
      warn "cluster not reachable or ${NS_HOLMES} namespace missing; skipping the backup"
    fi
  else
    dim "     --no-backup: not saving the chat volumes"
  fi

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

if [[ -d "${BACKUP_DIR}" ]] && ls "${BACKUP_DIR}"/*.tar.gz >/dev/null 2>&1; then
  dim "     kept ${BACKUP_DIR#"${REPO_ROOT}/"}/ - the next ./setup.sh restores it (rm -rf backups/ to start clean)"
fi
