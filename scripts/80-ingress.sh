#!/usr/bin/env bash
# Reach the UIs without port-forwarding: the minikube `ingress` addon
# (ingress-nginx, bound to ports 80/443 on the node) plus one hostname per UI.
#
#   http://shop.<domain>      Online Boutique frontend
#   http://grafana.<domain>   Grafana
#   http://chat.<domain>      Open WebUI (HolmesGPT)
#
# <domain> is INGRESS_DOMAIN from .env, or <minikube ip>.nip.io: nip.io is a
# public wildcard DNS that answers "a.b.c.d.nip.io" with a.b.c.d, so the names
# resolve to the node with no /etc/hosts edits. The vfkit driver puts the node
# on a NAT network the host can route to directly, so no `minikube tunnel`.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
load_env

step "Ingress"

# ---------------------------------------------------------------------------
# ingress-nginx via the addon. Enabling is idempotent; the addon pins its own
# controller version to the minikube release.
# ---------------------------------------------------------------------------
if minikube -p "${MINIKUBE_PROFILE}" addons list -o json 2>/dev/null \
     | python3 -c 'import sys,json; sys.exit(0 if json.load(sys.stdin).get("ingress",{}).get("Status")=="enabled" else 1)'; then
  ok "ingress addon already enabled"
else
  log "enabling the ingress addon"
  minikube -p "${MINIKUBE_PROFILE}" addons enable ingress 2>&1 | sed 's/^/     /'
fi
wait_rollout "${NS_INGRESS}" 5m deployment/ingress-nginx-controller
ok "ingress-nginx controller ready"

# ---------------------------------------------------------------------------
# Hostnames
# ---------------------------------------------------------------------------
NODE_IP=$(minikube -p "${MINIKUBE_PROFILE}" ip)
DOMAIN=$(ingress_domain) || die "cannot determine the ingress domain"
HOST_FRONTEND="${INGRESS_HOST_FRONTEND}.${DOMAIN}"
HOST_GRAFANA="${INGRESS_HOST_GRAFANA}.${DOMAIN}"
HOST_OPENWEBUI="${INGRESS_HOST_OPENWEBUI}.${DOMAIN}"
dim "     node ${NODE_IP}, domain ${DOMAIN}"

log "applying Ingress rules"
sed -e "s|__NS_DEMO__|${NS_DEMO}|g" \
    -e "s|__NS_MONITORING__|${NS_MONITORING}|g" \
    -e "s|__NS_HOLMES__|${NS_HOLMES}|g" \
    -e "s|__HOST_FRONTEND__|${HOST_FRONTEND}|g" \
    -e "s|__HOST_GRAFANA__|${HOST_GRAFANA}|g" \
    -e "s|__HOST_OPENWEBUI__|${HOST_OPENWEBUI}|g" \
    -e "s|__SVC_GRAFANA__|${REL_VM}-grafana|g" \
    -e "s|__SVC_OPENWEBUI__|${OPENWEBUI_FULLNAME}|g" \
    "${REPO_ROOT}/manifests/ingress/ingress.yaml" \
  | k apply -f - | sed 's/^/     /'

# ---------------------------------------------------------------------------
# Verify from the host, the way a browser would. First with --resolve, which
# proves the controller routes each host regardless of DNS; then with real
# resolution, which is what the browser depends on.
# ---------------------------------------------------------------------------
# routes <host> <path> - the controller answers 200 for this host
routes() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
         --resolve "$1:80:${NODE_IP}" "http://$1$2" 2>/dev/null) || code=000
  [[ "${code}" == "200" ]]
}
# nginx needs a moment after `apply` before a new host is in its config.
for spec in "${HOST_FRONTEND}:/" "${HOST_GRAFANA}:/api/health" "${HOST_OPENWEBUI}:/health"; do
  host="${spec%%:*}"; path="${spec#*:}"
  if retry 12 5 routes "${host}" "${path}"; then
    ok "http://${host}${path} -> 200"
  else
    die "ingress does not route ${host} (curl --resolve ${host}:80:${NODE_IP} http://${host}${path})"
  fi
done

resolves() {
  curl -s -o /dev/null --max-time 10 "http://$1/" >/dev/null 2>&1
}
if resolves "${HOST_FRONTEND}"; then
  ok "${DOMAIN} resolves from this machine"
else
  warn "${HOST_FRONTEND} does not resolve here (a DNS resolver that blocks nip.io?)."
  warn "Set INGRESS_DOMAIN in .env and add to /etc/hosts:"
  warn "  ${NODE_IP} ${INGRESS_HOST_FRONTEND}.<domain> ${INGRESS_HOST_GRAFANA}.<domain> ${INGRESS_HOST_OPENWEBUI}.<domain>"
fi

ok "ingress ready"
dim "     Online Boutique  http://${HOST_FRONTEND}"
dim "     Grafana          http://${HOST_GRAFANA}  (${GRAFANA_ADMIN_USER} / ${GRAFANA_ADMIN_PASSWORD})"
dim "     Open WebUI       http://${HOST_OPENWEBUI}"
