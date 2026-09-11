#!/usr/bin/env bash
# Shared helpers. Sourced by every script in scripts/.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# shellcheck source=./versions.sh
source "${REPO_ROOT}/lib/versions.sh"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BLUE=$'\033[34m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
else
  C_RESET=; C_BLUE=; C_GREEN=; C_YELLOW=; C_RED=; C_DIM=; C_BOLD=
fi

log()  { printf '%s==>%s %s\n' "${C_BLUE}" "${C_RESET}" "$*"; }
ok()   { printf '%s  ok%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
warn() { printf '%swarn%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
err()  { printf '%s err%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; }
die()  { err "$*"; exit 1; }
dim()  { printf '%s%s%s\n' "${C_DIM}" "$*" "${C_RESET}"; }

step() {
  printf '\n%s%s%s\n' "${C_BOLD}" "── $* ──────────────────────────────────────────" "${C_RESET}"
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

# ---------------------------------------------------------------------------
# Configuration: .env then defaults
# ---------------------------------------------------------------------------
load_env() {
  if [[ -f "${REPO_ROOT}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/.env"
    set +a
  fi

  : "${MINIKUBE_PROFILE:=holmesgpt-demo}"
  : "${MINIKUBE_DRIVER:=vfkit}"
  : "${MINIKUBE_CPUS:=6}"
  : "${MINIKUBE_MEMORY:=12288}"
  : "${MINIKUBE_DISK:=40g}"
  : "${K8S_VERSION:=}"

  : "${GRAFANA_ADMIN_USER:=admin}"
  : "${GRAFANA_ADMIN_PASSWORD:=admin}"

  : "${HOLMES_MODEL:=openrouter/anthropic/claude-sonnet-4.5}"
  : "${OPENROUTER_API_KEY:=}"
  : "${GITHUB_PAT:=}"

  : "${FRONTEND_IMAGE_REPO:=${OB_UPSTREAM_IMAGE_REPO}/frontend}"
  : "${FRONTEND_IMAGE_TAG:=v${VER_ONLINE_BOUTIQUE#v}}"

  export MINIKUBE_PROFILE MINIKUBE_DRIVER MINIKUBE_CPUS MINIKUBE_MEMORY MINIKUBE_DISK K8S_VERSION
  export GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD
  export HOLMES_MODEL OPENROUTER_API_KEY GITHUB_PAT
  export FRONTEND_IMAGE_REPO FRONTEND_IMAGE_TAG

  STATE_DIR="${REPO_ROOT}/.state"
  CERT_DIR="${REPO_ROOT}/certs"
  mkdir -p "${STATE_DIR}" "${CERT_DIR}"
  export STATE_DIR CERT_DIR
}

# ---------------------------------------------------------------------------
# Docker credential shim.
#
# This machine's ~/.docker/config.json sets "credsStore": "desktop" but
# docker-credential-desktop is not installed, which makes every Helm OCI pull
# fail with an exec error. Helm reads DOCKER_CONFIG, so point it at an empty
# throwaway directory for the duration of the run. All registries used here are
# public, so no credentials are lost.
# ---------------------------------------------------------------------------
setup_docker_config() {
  if [[ -z "${DOCKER_CONFIG:-}" || ! -d "${DOCKER_CONFIG:-}" ]]; then
    DOCKER_CONFIG="${STATE_DIR}/docker-config"
    mkdir -p "${DOCKER_CONFIG}"
    printf '{}\n' > "${DOCKER_CONFIG}/config.json"
    export DOCKER_CONFIG
  fi
}

# ---------------------------------------------------------------------------
# kubectl / helm bound to the demo cluster only
# ---------------------------------------------------------------------------
k() { kubectl --context "${MINIKUBE_PROFILE}" "$@"; }
h() { helm --kube-context "${MINIKUBE_PROFILE}" "$@"; }

# ---------------------------------------------------------------------------
# Waiting helpers
# ---------------------------------------------------------------------------

# retry <attempts> <sleep_seconds> <command...>
retry() {
  local attempts=$1 delay=$2; shift 2
  local i=1
  until "$@"; do
    if (( i >= attempts )); then
      return 1
    fi
    i=$(( i + 1 ))
    sleep "${delay}"
  done
}

ensure_ns() {
  local ns
  for ns in "$@"; do
    k get namespace "${ns}" >/dev/null 2>&1 || k create namespace "${ns}" >/dev/null
  done
}

# Succeeds when a workload's ready replica count matches its desired count.
# Used as a fallback for workloads `kubectl rollout status` refuses to handle,
# e.g. the VictoriaMetrics operator creates its Alertmanager StatefulSet with
# updateStrategy OnDelete, and rollout status only supports RollingUpdate.
workload_ready() {
  local ns=$1 target=$2
  local desired ready
  case "${target}" in
    daemonset/*|ds/*)
      desired=$(k -n "${ns}" get "${target}" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
      ready=$(k -n "${ns}" get "${target}" -o jsonpath='{.status.numberReady}' 2>/dev/null)
      ;;
    *)
      desired=$(k -n "${ns}" get "${target}" -o jsonpath='{.spec.replicas}' 2>/dev/null)
      ready=$(k -n "${ns}" get "${target}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
      ;;
  esac
  [[ -n "${desired}" ]] || return 1
  [[ "${ready:-0}" -ge "${desired}" ]]
}

# wait_rollout <namespace> <timeout> [resource...]
# With no resources, waits on every Deployment, StatefulSet and DaemonSet in ns.
wait_rollout() {
  local ns=$1 timeout=$2; shift 2
  local targets=("$@")

  if (( ${#targets[@]} == 0 )); then
    mapfile -t targets < <(
      k -n "${ns}" get deploy,statefulset,daemonset \
        -o jsonpath='{range .items[*]}{.kind}/{.metadata.name}{"\n"}{end}' 2>/dev/null \
        | tr '[:upper:]' '[:lower:]'
    )
  fi

  local t
  for t in "${targets[@]}"; do
    [[ -n "${t}" ]] || continue
    log "waiting for ${ns}/${t}"

    if k -n "${ns}" rollout status "${t}" --timeout="${timeout}" >/dev/null 2>&1; then
      continue
    fi

    # rollout status refused or timed out; fall back to a readiness poll.
    if retry 60 5 workload_ready "${ns}" "${t}"; then
      continue
    fi

    err "rollout failed: ${ns}/${t}"
    k -n "${ns}" get pods -o wide || true
    return 1
  done
}

# wait_for_crd <name>...
wait_for_crd() {
  local c
  for c in "$@"; do
    retry 60 5 k get crd "${c}" >/dev/null 2>&1 \
      || die "CRD did not appear: ${c}"
  done
}

# Run a throwaway curl pod inside the cluster and echo its stdout.
# Usage: incluster_curl <namespace> <curl args...>
incluster_curl() {
  local ns=$1; shift
  k -n "${ns}" run "curl-$RANDOM" \
    --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.11.1 \
    --command -- curl --silent --show-error --max-time 30 "$@"
}

# Apply stdin to the cluster.
kapply() { k apply -f -; }

# Exported so `bash -c` / xargs subshells can still reach the cluster helpers.
export -f k h incluster_curl retry workload_ready 2>/dev/null || true
