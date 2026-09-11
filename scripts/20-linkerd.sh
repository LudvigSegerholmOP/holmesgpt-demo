#!/usr/bin/env bash
# Install Linkerd: generate mTLS material, then linkerd-crds + linkerd-control-plane.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
load_env
setup_docker_config

step "Linkerd ${VER_LINKERD}"

CA_CRT="${CERT_DIR}/ca.crt"
CA_KEY="${CERT_DIR}/ca.key"
ISSUER_CRT="${CERT_DIR}/issuer.crt"
ISSUER_KEY="${CERT_DIR}/issuer.key"

# ---------------------------------------------------------------------------
# mTLS trust anchor + identity issuer.
#
# Linkerd requires an ECDSA P-256 root CA and an intermediate issuer whose
# common name is identity.linkerd.cluster.local. The upstream docs use step-cli;
# openssl produces an equivalent chain with no extra dependency.
#
# Generated once and reused, so re-running setup.sh does not invalidate the
# identities of already-running proxies.
# ---------------------------------------------------------------------------
generate_certs() {
  log "generating Linkerd trust anchor and issuer (ECDSA P-256, 10y)"
  local cnf_root="${STATE_DIR}/linkerd-root.cnf"
  local cnf_issuer="${STATE_DIR}/linkerd-issuer.cnf"

  cat > "${cnf_root}" <<'EOF'
[req]
distinguished_name = dn
prompt             = no
x509_extensions    = v3_ca
[dn]
CN = root.linkerd.cluster.local
[v3_ca]
basicConstraints = critical, CA:TRUE
keyUsage         = critical, keyCertSign, cRLSign
subjectAltName   = DNS:root.linkerd.cluster.local
EOF

  cat > "${cnf_issuer}" <<'EOF'
[req]
distinguished_name = dn
prompt             = no
[dn]
CN = identity.linkerd.cluster.local
[v3_issuer]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage         = critical, keyCertSign, cRLSign
subjectAltName   = DNS:identity.linkerd.cluster.local
EOF

  openssl ecparam -name prime256v1 -genkey -noout -out "${CA_KEY}"
  openssl req -x509 -new -key "${CA_KEY}" -sha256 -days 3650 \
    -config "${cnf_root}" -out "${CA_CRT}"

  openssl ecparam -name prime256v1 -genkey -noout -out "${ISSUER_KEY}"
  openssl req -new -key "${ISSUER_KEY}" -config "${cnf_issuer}" \
    -out "${STATE_DIR}/issuer.csr"
  openssl x509 -req -in "${STATE_DIR}/issuer.csr" \
    -CA "${CA_CRT}" -CAkey "${CA_KEY}" -CAcreateserial \
    -sha256 -days 3650 \
    -extfile "${cnf_issuer}" -extensions v3_issuer \
    -out "${ISSUER_CRT}"

  chmod 600 "${CA_KEY}" "${ISSUER_KEY}"
  rm -f "${STATE_DIR}/issuer.csr"

  openssl verify -CAfile "${CA_CRT}" "${ISSUER_CRT}" >/dev/null \
    || die "generated Linkerd issuer does not verify against the trust anchor"
}

if [[ -s "${CA_CRT}" && -s "${CA_KEY}" && -s "${ISSUER_CRT}" && -s "${ISSUER_KEY}" ]]; then
  if openssl x509 -in "${ISSUER_CRT}" -noout -checkend 2592000 >/dev/null 2>&1; then
    ok "reusing existing certificates in certs/"
  else
    warn "issuer certificate expires within 30 days; regenerating"
    generate_certs
  fi
else
  generate_certs
fi

expiry=$(openssl x509 -in "${ISSUER_CRT}" -noout -enddate | cut -d= -f2)
ok "issuer valid until ${expiry}"

# ---------------------------------------------------------------------------
# CRDs
# ---------------------------------------------------------------------------
log "installing linkerd-crds"
h upgrade --install "${REL_LINKERD_CRDS}" linkerd-edge/linkerd-crds \
  --version "${VER_LINKERD}" \
  --namespace "${NS_LINKERD}" \
  --wait --timeout 5m

wait_for_crd \
  servers.policy.linkerd.io \
  serverauthorizations.policy.linkerd.io \
  authorizationpolicies.policy.linkerd.io
ok "linkerd CRDs established"

# ---------------------------------------------------------------------------
# iptables variant.
#
# linkerd-init defaults to nft. The minikube VM image ships iptables-legacy
# (/sbin/iptables -> xtables-legacy-multi), and on it iptables-nft-save fails
# with "Could not fetch rule set generation id: Invalid argument", so every
# injected pod gets stuck in Init:CrashLoopBackOff. Probe the node rather than
# hardcoding, since other drivers and runtimes do provide nft.
# ---------------------------------------------------------------------------
detect_iptables_mode() {
  if minikube -p "${MINIKUBE_PROFILE}" ssh -- \
      "sudo iptables-nft-save -t nat >/dev/null 2>&1" >/dev/null 2>&1; then
    echo "nft"
  else
    echo "legacy"
  fi
}

: "${LINKERD_IPTABLES_MODE:=$(detect_iptables_mode)}"
ok "node iptables mode: ${LINKERD_IPTABLES_MODE}"

# ---------------------------------------------------------------------------
# Control plane
# ---------------------------------------------------------------------------
log "installing linkerd-control-plane"
h upgrade --install "${REL_LINKERD_CP}" linkerd-edge/linkerd-control-plane \
  --version "${VER_LINKERD}" \
  --namespace "${NS_LINKERD}" \
  --values "${REPO_ROOT}/values/linkerd-control-plane.yaml" \
  --set "proxyInit.iptablesMode=${LINKERD_IPTABLES_MODE}" \
  --set-file identityTrustAnchorsPEM="${CA_CRT}" \
  --set-file identity.issuer.tls.crtPEM="${ISSUER_CRT}" \
  --set-file identity.issuer.tls.keyPEM="${ISSUER_KEY}" \
  --wait --timeout 10m

wait_rollout "${NS_LINKERD}" 5m

if command -v linkerd >/dev/null 2>&1; then
  log "running 'linkerd check'"
  # The local CLI may be a different edge build than the charts; a version-skew
  # warning is expected and not fatal.
  if linkerd check --context "${MINIKUBE_PROFILE}" --wait 3m 2>&1 | tail -30; then
    ok "linkerd check passed"
  else
    warn "linkerd check reported problems (often just CLI/control-plane version skew)"
  fi
fi

ok "Linkerd ready"
