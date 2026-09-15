#!/usr/bin/env bash
# Roll a different frontend image into the running Online Boutique.
#
#   ./deploy-frontend.sh sha-3a75a95           tag on FRONTEND_IMAGE_REPO (.env)
#   ./deploy-frontend.sh ghcr.io/o/frontend:v1 any repo:tag
#   ./deploy-frontend.sh --rollback            back to what .env says
#   ./deploy-frontend.sh --list                tags available on FRONTEND_IMAGE_REPO
#   ./deploy-frontend.sh --status              image the cluster is running now
#
# Nothing here is written to .env: this is the "push a release, watch the
# agent" lever, and --rollback (or ./setup.sh --only 60) undoes it. The actual
# rollout is step 60 with FRONTEND_IMAGE_REPO/_TAG overridden, so the pull
# secret, post-renderer and image checks are the same as a fresh install.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${REPO_ROOT}/lib/common.sh"
load_env

usage() {
  sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

current_image() {
  k -n "${NS_DEMO}" get deployment frontend \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true
}

(( $# == 1 )) || usage 1

repo="${FRONTEND_IMAGE_REPO}"
tag="${FRONTEND_IMAGE_TAG}"
case "$1" in
  -h|--help) usage 0 ;;
  --status)
    printf '%s\n' "$(current_image)"; exit 0 ;;
  --list)
    [[ "${repo}" == ghcr.io/* ]] || die "--list only knows how to talk to ghcr.io (FRONTEND_IMAGE_REPO=${repo})"
    ghcr_list_tags "${repo}" || { ghcr_access_hint "${repo}"; die "cannot list tags for ${repo}"; }
    exit 0 ;;
  --rollback)
    ;;                                   # .env values as loaded
  --*) err "unknown flag: $1"; usage 1 ;;
  */*:*)                                 # full image reference
    repo="${1%:*}"; tag="${1##*:}" ;;
  *:*|*/*) die "'$1' is neither a bare tag nor a repo:tag image reference" ;;
  *) tag="$1" ;;                         # bare tag on the configured repo
esac

image="${repo}:${tag}"
before="$(current_image)"
[[ -n "${before}" ]] || die "no frontend Deployment in ${NS_DEMO}; run ./setup.sh first"

step "Frontend rollout"
log "current: ${before}"
log "target:  ${image}"
if [[ "${before}" == "${image}" ]]; then
  ok "already running ${image}; re-running step 60 anyway to reconcile"
fi

started_at=$(date +%s)
FRONTEND_IMAGE_REPO="${repo}" FRONTEND_IMAGE_TAG="${tag}" \
  "${REPO_ROOT}/scripts/60-online-boutique.sh"

after="$(current_image)"
[[ "${after}" == "${image}" ]] || die "cluster reports ${after}, expected ${image}"

elapsed=$(( $(date +%s) - started_at ))
printf '\n%sfrontend %s -> %s in %dm%02ds%s\n' "${C_GREEN}${C_BOLD}" "${before##*:}" "${after##*:}" \
  $(( elapsed / 60 )) $(( elapsed % 60 )) "${C_RESET}"
dim "the previous release was ${before}; ./deploy-frontend.sh --rollback returns to .env"
