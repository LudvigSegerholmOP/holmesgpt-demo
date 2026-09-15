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
  # These may be overridden on the command line for a single run, e.g.
  #   FRONTEND_IMAGE_TAG=v2 ./setup.sh --only 60
  # Sourcing .env would otherwise clobber them, so remember and restore.
  local -a overridable=(FRONTEND_IMAGE_REPO FRONTEND_IMAGE_TAG LOADGEN_USERS LOADGEN_RATE)
  local -A preset=()
  local v
  for v in "${overridable[@]}"; do
    [[ -n "${!v+x}" ]] && preset[$v]="${!v}"
  done

  if [[ -f "${REPO_ROOT}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/.env"
    set +a
  fi

  for v in "${!preset[@]}"; do
    printf -v "$v" '%s' "${preset[$v]}"
  done

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

  # Token for pulling the frontend from ghcr.io. GHCR only accepts classic
  # PATs with read:packages, so a fine-grained GITHUB_PAT (the kind the GitHub
  # MCP wants) cannot be reused here. Falls back to GITHUB_PAT for a classic
  # token that covers both; empty means "the package must be public".
  : "${GHCR_PAT:=${GITHUB_PAT}}"

  : "${FRONTEND_IMAGE_REPO:=${OB_UPSTREAM_IMAGE_REPO}/frontend}"
  : "${FRONTEND_IMAGE_TAG:=v${VER_ONLINE_BOUTIQUE#v}}"

  # Username for the ghcr.io pull secret. GHCR only checks the token, but the
  # package owner is the natural default: ghcr.io/<owner>/<image> -> <owner>.
  if [[ -z "${GITHUB_USER:-}" && "${FRONTEND_IMAGE_REPO}" == ghcr.io/* ]]; then
    GITHUB_USER="${FRONTEND_IMAGE_REPO#ghcr.io/}"
    GITHUB_USER="${GITHUB_USER%%/*}"
  fi
  : "${GITHUB_USER:=}"

  # Load generator: simulated users and spawn rate (users/second). The upstream
  # chart hardcodes 10 and 1; see manifests/online-boutique/locustfile.py.
  : "${LOADGEN_USERS:=20}"
  : "${LOADGEN_RATE:=2}"

  # Domain the Ingress hostnames hang off (step 80). Empty means
  # "<minikube ip>.nip.io", resolved when the step runs, since the node IP is
  # only known once the cluster exists.
  : "${INGRESS_DOMAIN:=}"

  export MINIKUBE_PROFILE MINIKUBE_DRIVER MINIKUBE_CPUS MINIKUBE_MEMORY MINIKUBE_DISK K8S_VERSION
  export GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD
  export HOLMES_MODEL OPENROUTER_API_KEY GITHUB_PAT GHCR_PAT GITHUB_USER
  export FRONTEND_IMAGE_REPO FRONTEND_IMAGE_TAG
  export LOADGEN_USERS LOADGEN_RATE
  export INGRESS_DOMAIN

  STATE_DIR="${REPO_ROOT}/.state"
  CERT_DIR="${REPO_ROOT}/certs"
  # Volume backups written by teardown.sh / backup.sh and restored by step 75.
  # Not under .state/, which teardown.sh wipes.
  BACKUP_DIR="${REPO_ROOT}/backups"
  mkdir -p "${STATE_DIR}" "${CERT_DIR}"
  export STATE_DIR CERT_DIR BACKUP_DIR
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
# ghcr.io access checks. Run before handing an image to the cluster, where a
# bad token only shows up as ImagePullBackOff after the Helm --wait times out.
# ---------------------------------------------------------------------------

# ghcr_token <ghcr.io/owner/image> [actions]
# Prints a registry bearer token for the image, authenticating with
# GITHUB_USER/GHCR_PAT when set and anonymously otherwise. Fails on DENIED.
ghcr_token() {
  local repo=${1#ghcr.io/} actions=${2:-pull}
  local -a auth=()
  [[ -n "${GHCR_PAT}" ]] && auth=(-u "${GITHUB_USER}:${GHCR_PAT}")
  curl -fs "${auth[@]}" "https://ghcr.io/token?scope=repository:${repo}:${actions}" 2>/dev/null \
    | python3 -c 'import sys,json; t=json.load(sys.stdin).get("token",""); print(t) if t else sys.exit(1)' 2>/dev/null
}

# ghcr_image_pullable <ghcr.io/owner/image> <tag>
# Succeeds when the manifest can be fetched with the credentials step 60 will
# put in the pull secret; prints the HTTP status on stderr when it cannot.
ghcr_image_pullable() {
  local repo=$1 tag=$2 token status
  token=$(ghcr_token "${repo}" pull) || { err "ghcr.io refused to issue a token for ${repo}"; return 1; }
  status=$(curl -sS -o /dev/null -w '%{http_code}' -I \
    -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://ghcr.io/v2/${repo#ghcr.io/}/manifests/${tag}")
  [[ "${status}" == 200 ]] && return 0
  err "ghcr.io returned HTTP ${status} for ${repo}:${tag}"
  return 1
}

# ghcr_list_tags <ghcr.io/owner/image>   one tag per line
ghcr_list_tags() {
  local repo=$1 token
  token=$(ghcr_token "${repo}" pull) || return 1
  curl -fs -H "Authorization: Bearer ${token}" "https://ghcr.io/v2/${repo#ghcr.io/}/tags/list" 2>/dev/null \
    | python3 -c 'import sys,json; print("\n".join(sorted(json.load(sys.stdin).get("tags") or [])))' 2>/dev/null
}

# Explains the two ways out of a failed ghcr.io check.
ghcr_access_hint() {
  local repo=$1
  err "either make the package public (github.com -> Packages -> ${repo#ghcr.io/} -> Package settings -> Change visibility)"
  err "or set GHCR_PAT in .env to a CLASSIC PAT with read:packages that has been granted the package;"
  err "fine-grained tokens are rejected by ghcr.io regardless of their permissions."
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

# The domain the Ingress hostnames live under: INGRESS_DOMAIN from .env, or
# <node ip>.nip.io. Empty when the cluster is not running.
ingress_domain() {
  if [[ -n "${INGRESS_DOMAIN}" ]]; then
    printf '%s' "${INGRESS_DOMAIN}"
    return
  fi
  local ip
  ip=$(minikube -p "${MINIKUBE_PROFILE}" ip 2>/dev/null) || return 1
  [[ -n "${ip}" ]] && printf '%s.nip.io' "${ip}"
}

# ---------------------------------------------------------------------------
# Volume backup / restore.
#
# `minikube delete` takes every PersistentVolume with it, so the SQLite
# databases behind Open WebUI (chats, settings) and holmes-bridge (Holmes
# conversation history, keyed on the same chat ids) would be gone after every
# teardown. These helpers tar a PVC to backups/ on this machine and unpack it
# into a new cluster's volume.
#
# The copy is made from a throwaway pod with the PVC mounted, never from the
# application container: the bridge image is distroless (no tar, no shell)
# and Open WebUI runs SQLite in WAL mode, so a copy of webui.db taken while
# the app is running would miss everything still in webui.db-wal. The owning
# workload is scaled to zero around the copy so the database is closed and
# checkpointed, and the volume (ReadWriteOnce) is free.
# ---------------------------------------------------------------------------

# workload_selector <namespace> <kind/name>   -> "k1=v1,k2=v2"
workload_selector() {
  k -n "$1" get "$2" -o json | python3 -c '
import sys, json
sel = json.load(sys.stdin)["spec"]["selector"]["matchLabels"]
print(",".join(f"{k}={v}" for k, v in sel.items()))'
}

# workload_scale <namespace> <kind/name> <replicas>
# Scaling to zero waits until the pods are actually gone (not just
# terminating); scaling up returns at once - callers wait_rollout if they care.
workload_scale() {
  local ns=$1 target=$2 n=$3
  k -n "${ns}" scale "${target}" --replicas="${n}" >/dev/null
  if (( n == 0 )); then
    k -n "${ns}" wait --for=delete pod -l "$(workload_selector "${ns}" "${target}")" --timeout=3m >/dev/null 2>&1 \
      || { err "pods of ${ns}/${target} did not terminate"; return 1; }
  fi
}

# volume_pod_run <namespace> <pvc> <command...>
# Runs a command in a throwaway pod with the PVC mounted at /data. stdin and
# stdout go through `kubectl exec`, which carries binary streams intact
# (`kubectl run -i` falls back to logs when a short command finishes before
# the attach, and logs are line-oriented).
volume_pod_run() {
  local ns=$1 pvc=$2; shift 2
  local pod="volume-$RANDOM" rc=0
  k -n "${ns}" run "${pod}" --restart=Never --image="${VOLUME_HELPER_IMAGE}" \
    --overrides="$(cat <<JSON
{"apiVersion": "v1", "spec": {
  "restartPolicy": "Never",
  "terminationGracePeriodSeconds": 1,
  "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "${pvc}"}}],
  "containers": [{
    "name": "volume", "image": "${VOLUME_HELPER_IMAGE}",
    "command": ["sleep", "3600"],
    "volumeMounts": [{"name": "data", "mountPath": "/data"}]
  }]
}}
JSON
)" >/dev/null
  if k -n "${ns}" wait --for=condition=Ready "pod/${pod}" --timeout=2m >/dev/null 2>&1; then
    k -n "${ns}" exec -i "${pod}" -- "$@" || rc=$?
  else
    err "helper pod ${ns}/${pod} did not become ready"
    k -n "${ns}" describe pod "${pod}" 2>/dev/null | tail -n 15 >&2 || true
    rc=1
  fi
  k -n "${ns}" delete pod "${pod}" --wait=false >/dev/null 2>&1 || true
  return "${rc}"
}

# volume_backup <namespace> <kind/name> <pvc> <file> [tar --exclude=... ]
# Writes a gzipped tar of the volume's contents to <file>. The previous file
# is only replaced once the new one is complete.
volume_backup() {
  local ns=$1 target=$2 pvc=$3 file=$4; shift 4
  local rc=0 replicas
  if ! k -n "${ns}" get pvc "${pvc}" >/dev/null 2>&1; then
    warn "no PVC ${ns}/${pvc}; nothing to back up"
    return 0
  fi
  replicas=$(k -n "${ns}" get "${target}" -o jsonpath='{.spec.replicas}')
  log "backing up ${ns}/${pvc} -> ${file#"${REPO_ROOT}/"}"
  mkdir -p "$(dirname "${file}")"
  workload_scale "${ns}" "${target}" 0
  volume_pod_run "${ns}" "${pvc}" tar czf - -C /data "$@" . > "${file}.partial" || rc=$?
  workload_scale "${ns}" "${target}" "${replicas:-1}"
  if (( rc != 0 )); then
    rm -f "${file}.partial"
    err "backup of ${ns}/${pvc} failed"
    return 1
  fi
  mv -f "${file}.partial" "${file}"
  ok "backed up ${ns}/${pvc} ($(du -h "${file}" | cut -f1 | tr -d ' '))"
}

# volume_restore <namespace> <kind/name> <pvc> <file>
# Replaces the volume's contents with the archive, then scales the workload
# back to what it was. Callers wait_rollout afterwards.
volume_restore() {
  local ns=$1 target=$2 pvc=$3 file=$4
  local rc=0 replicas
  [[ -s "${file}" ]] || { err "no backup at ${file}"; return 1; }
  gzip -t "${file}" 2>/dev/null || { err "backup is not a valid gzip archive: ${file}"; return 1; }
  k -n "${ns}" get pvc "${pvc}" >/dev/null 2>&1 || { err "no PVC ${ns}/${pvc} to restore into"; return 1; }
  replicas=$(k -n "${ns}" get "${target}" -o jsonpath='{.spec.replicas}')
  log "restoring ${file#"${REPO_ROOT}/"} -> ${ns}/${pvc}"
  workload_scale "${ns}" "${target}" 0
  volume_pod_run "${ns}" "${pvc}" \
    sh -c 'find /data -mindepth 1 -delete && tar xzf - -C /data' < "${file}" || rc=$?
  workload_scale "${ns}" "${target}" "${replicas:-1}"
  if (( rc != 0 )); then
    err "restore into ${ns}/${pvc} failed"
    return 1
  fi
  ok "restored ${ns}/${pvc}"
}

# Exported so `bash -c` / xargs subshells can still reach the cluster helpers.
export -f k h incluster_curl retry workload_ready 2>/dev/null || true
