#!/usr/bin/env bash
# Save or restore the chat data that would otherwise die with the cluster.
#
#   ./backup.sh            tar the Open WebUI and holmes-bridge volumes to backups/
#   ./backup.sh --restore  unpack backups/ into the running cluster's volumes
#
# teardown.sh runs the backup for you before `minikube delete`, and step 75
# restores into any volume it has just created, so ./teardown.sh && ./setup.sh
# keeps your chats. Use this directly for a snapshot without tearing down, or
# to roll a running cluster back to the last backup. Each workload is scaled to
# zero for the few seconds the copy takes (see volume_backup in lib/common.sh).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${REPO_ROOT}/lib/common.sh"
load_env

usage() {
  sed -n '2,5p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

MODE=backup
case "${1:-}" in
  "") ;;
  --restore) MODE=restore ;;
  -h|--help) usage 0 ;;
  *) err "unknown argument: $1"; usage 1 ;;
esac

k --request-timeout=10s get namespace "${NS_HOLMES}" >/dev/null 2>&1 \
  || die "cluster '${MINIKUBE_PROFILE}' is not reachable or has no ${NS_HOLMES} namespace"

if [[ "${MODE}" == backup ]]; then
  step "Backup -> ${BACKUP_DIR#"${REPO_ROOT}/"}/"
  # Open WebUI's cache/ only holds downloaded models and thumbnails.
  volume_backup "${NS_HOLMES}" "statefulset/${OPENWEBUI_FULLNAME}" "${PVC_OPENWEBUI}" \
    "${BACKUP_DIR}/${BACKUP_FILE_OPENWEBUI}" --exclude='./cache'
  volume_backup "${NS_HOLMES}" "deployment/${BRIDGE_NAME}" "${PVC_HOLMES_BRIDGE}" \
    "${BACKUP_DIR}/${BACKUP_FILE_HOLMES_BRIDGE}"
else
  step "Restore <- ${BACKUP_DIR#"${REPO_ROOT}/"}/"
  volume_restore "${NS_HOLMES}" "statefulset/${OPENWEBUI_FULLNAME}" "${PVC_OPENWEBUI}" \
    "${BACKUP_DIR}/${BACKUP_FILE_OPENWEBUI}"
  volume_restore "${NS_HOLMES}" "deployment/${BRIDGE_NAME}" "${PVC_HOLMES_BRIDGE}" \
    "${BACKUP_DIR}/${BACKUP_FILE_HOLMES_BRIDGE}"
  wait_rollout "${NS_HOLMES}" 5m "statefulset/${OPENWEBUI_FULLNAME}" "deployment/${BRIDGE_NAME}"
  ok "restored; Open WebUI and holmes-bridge are back up"
fi
