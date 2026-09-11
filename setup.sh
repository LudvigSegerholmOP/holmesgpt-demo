#!/usr/bin/env bash
# HolmesGPT SRE demo cluster - top-level entrypoint.
#
#   ./setup.sh                run every step in order
#   ./setup.sh --from 30      resume from step 30
#   ./setup.sh --only 50      run one step
#   ./setup.sh --list         show the steps
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${REPO_ROOT}/lib/common.sh"

STEPS=(
  00-preflight
  10-cluster
  20-linkerd
  30-victoria-metrics
  40-victoria-logs
  50-linkerd-observability
  60-online-boutique
  70-holmesgpt
  99-verify
)

usage() {
  sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

FROM=""; ONLY=""
while (( $# )); do
  case "$1" in
    --from) FROM="${2:?--from needs a step prefix}"; shift 2 ;;
    --only) ONLY="${2:?--only needs a step prefix}"; shift 2 ;;
    --list)
      printf '%s\n' "${STEPS[@]}"; exit 0 ;;
    -h|--help) usage 0 ;;
    *) err "unknown argument: $1"; usage 1 ;;
  esac
done

selected=()
if [[ -n "${ONLY}" ]]; then
  for s in "${STEPS[@]}"; do
    [[ "${s}" == "${ONLY}"* ]] && selected+=("${s}")
  done
  (( ${#selected[@]} )) || die "no step matches '${ONLY}'"
elif [[ -n "${FROM}" ]]; then
  started=false
  for s in "${STEPS[@]}"; do
    [[ "${s}" == "${FROM}"* ]] && started=true
    ${started} && selected+=("${s}")
  done
  ${started} || die "no step matches '${FROM}'"
else
  selected=("${STEPS[@]}")
fi

started_at=$(date +%s)

printf '%s\n' "${C_BOLD}HolmesGPT SRE demo${C_RESET}"
dim "steps: ${selected[*]}"

for s in "${selected[@]}"; do
  script="${REPO_ROOT}/scripts/${s}.sh"
  [[ -x "${script}" ]] || chmod +x "${script}"
  "${script}"
done

elapsed=$(( $(date +%s) - started_at ))
printf '\n%sdone in %dm%02ds%s\n' "${C_GREEN}${C_BOLD}" $(( elapsed / 60 )) $(( elapsed % 60 )) "${C_RESET}"
