#!/usr/bin/env bash
# Preflight: verify tooling, load configuration, prepare Helm repositories.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

step "Preflight"

# The scripts use mapfile/associative arrays. macOS ships bash 3.2 at /bin/bash.
if (( BASH_VERSINFO[0] < 4 )); then
  die "bash >= 4 required, running ${BASH_VERSION}. Install with: brew install bash"
fi

require_cmd minikube helm kubectl openssl curl python3 awk sed
ok "core tooling present"

if ! command -v linkerd >/dev/null 2>&1; then
  warn "linkerd CLI not found; 'linkerd check' verification will be skipped"
  warn "install with: brew install linkerd"
else
  ok "linkerd CLI $(linkerd version --client --short 2>/dev/null || echo '(version unknown)')"
fi

python3 -c 'import yaml' 2>/dev/null || die "python3 module 'yaml' required. Install with: python3 -m pip install pyyaml"
ok "python3 + pyyaml present"

load_env
setup_docker_config
ok "DOCKER_CONFIG=${DOCKER_CONFIG} (bypasses the broken docker-credential-desktop credsStore)"

# ---------------------------------------------------------------------------
# Required configuration
# ---------------------------------------------------------------------------
if [[ ! -f "${REPO_ROOT}/.env" ]]; then
  warn "no .env found. Copy .env.example to .env and fill it in."
fi

[[ -n "${OPENROUTER_API_KEY}" ]] \
  || die "OPENROUTER_API_KEY is not set. HolmesGPT has no LLM backend without it. See .env.example"
ok "OpenRouter API key present, model=${HOLMES_MODEL}"

if [[ -z "${GITHUB_PAT}" ]]; then
  warn "GITHUB_PAT unset - the GitHub MCP integration will be SKIPPED"
else
  ok "GitHub PAT present"
fi

log "frontend image: ${FRONTEND_IMAGE_REPO}:${FRONTEND_IMAGE_TAG}"
if [[ "${FRONTEND_IMAGE_REPO}" == "${OB_UPSTREAM_IMAGE_REPO}/frontend" ]]; then
  dim "     (upstream default - set FRONTEND_IMAGE_REPO/_TAG in .env to use your own build)"
elif [[ "${FRONTEND_IMAGE_REPO}" == ghcr.io/* ]]; then
  if [[ -n "${GITHUB_PAT}" ]]; then
    ok "ghcr.io frontend: will pull as ${GITHUB_USER} with GITHUB_PAT (needs read:packages)"
  else
    warn "ghcr.io frontend with GITHUB_PAT unset: the package must be public or the pull fails"
  fi
fi

# ---------------------------------------------------------------------------
# Resource sanity
# ---------------------------------------------------------------------------
if command -v podman >/dev/null 2>&1; then
  if podman machine list --format '{{.Running}}' 2>/dev/null | grep -q true; then
    warn "a podman machine is running and is holding RAM."
    warn "if minikube fails to start, free it with: podman machine stop"
  fi
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
  total_gb=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
  want_gb=$(( MINIKUBE_MEMORY / 1024 ))
  if (( want_gb + 4 > total_gb )); then
    warn "requesting ${want_gb}GB for minikube on a ${total_gb}GB machine; consider lowering MINIKUBE_MEMORY"
  fi
fi

# ---------------------------------------------------------------------------
# Helm repositories (HTTP, not OCI - the charts bundle their subcharts)
# ---------------------------------------------------------------------------
log "configuring Helm repositories"
add_repo() {
  local name=$1 url=$2
  if helm repo list 2>/dev/null | awk -v n="${name}" '$1==n {found=1} END{exit !found}'; then
    helm repo add "${name}" "${url}" --force-update >/dev/null
  else
    helm repo add "${name}" "${url}" >/dev/null
  fi
}
add_repo victoria-metrics "${REPO_VM}"
add_repo linkerd-edge     "${REPO_LINKERD}"
add_repo robusta          "${REPO_ROBUSTA}"
add_repo open-webui       "${REPO_OPENWEBUI}"
helm repo update victoria-metrics linkerd-edge robusta open-webui >/dev/null
ok "Helm repositories ready"

ok "preflight complete"
