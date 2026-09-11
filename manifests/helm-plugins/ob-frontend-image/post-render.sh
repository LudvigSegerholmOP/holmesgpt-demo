#!/usr/bin/env bash
# Helm post-renderer: swap ONLY the frontend image.
#
# The Online Boutique chart renders every container as
#   {{ .Values.images.repository }}/{{ .Values.<svc>.name }}:{{ .Values.images.tag }}
# so there is no per-service image override. Rather than fork the chart or
# mutate the Deployment out-of-band (which `helm upgrade` would revert), this
# runs the rendered manifests through kustomize's image transformer, which
# matches on image name and therefore touches the frontend and nothing else.
#
# Helm invokes this with the rendered manifests on stdin and expects the final
# manifests on stdout.
#
# Inputs (exported by scripts/60-online-boutique.sh; Helm passes the outer
# environment through to the plugin subprocess):
#   OB_UPSTREAM_IMAGE_REPO  repo prefix the chart renders by default
#   FRONTEND_IMAGE_REPO     replacement repository
#   FRONTEND_IMAGE_TAG      replacement tag
#   OB_RELAX_PROBES         "true" when the node runs the amd64 images under
#                           emulation; loosens every Deployment's probes so
#                           the slow-starting services are not killed by the
#                           chart's 1-second health checks (relax-probes.py)
set -euo pipefail

: "${OB_UPSTREAM_IMAGE_REPO:?post-renderer requires OB_UPSTREAM_IMAGE_REPO}"
: "${FRONTEND_IMAGE_REPO:?post-renderer requires FRONTEND_IMAGE_REPO}"
: "${FRONTEND_IMAGE_TAG:?post-renderer requires FRONTEND_IMAGE_TAG}"

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

cat > "${workdir}/rendered.yaml"

cat > "${workdir}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - rendered.yaml
images:
  - name: ${OB_UPSTREAM_IMAGE_REPO}/frontend
    newName: ${FRONTEND_IMAGE_REPO}
    newTag: ${FRONTEND_IMAGE_TAG}
EOF

# kustomize is bundled inside kubectl.
if [[ "${OB_RELAX_PROBES:-false}" == "true" ]]; then
  kubectl kustomize "${workdir}" | python3 "$(dirname "${BASH_SOURCE[0]}")/relax-probes.py"
else
  kubectl kustomize "${workdir}"
fi
