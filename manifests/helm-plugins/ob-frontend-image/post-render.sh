#!/usr/bin/env bash
# Helm post-renderer: swap ONLY the frontend image, and optionally mount a
# custom load profile into the load generator.
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
#   OB_FRONTEND_PULL_SECRET optional. Name of a docker-registry Secret (in the
#                           release namespace) added as an imagePullSecret on
#                           the frontend Deployment, for a private registry.
#   OB_LOADGEN_CONFIGMAP    optional. Name of a ConfigMap (in the release
#                           namespace) holding locustfile.py; when set, the
#                           loadgenerator Deployment is patched to mount it
#                           over the image's built-in locustfile and to take
#                           USERS/RATE from OB_LOADGEN_USERS/OB_LOADGEN_RATE.
#                           OB_LOADGEN_CHECKSUM (a hash of the file) goes on
#                           the pod template so a changed profile rolls the
#                           pod: subPath mounts do not pick up ConfigMap edits.
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

# Strategic-merge patches, as "<file> <deployment name>" pairs.
patches=()

# Optional: private registry credentials for the frontend only.
if [[ -n "${OB_FRONTEND_PULL_SECRET:-}" ]]; then
  cat > "${workdir}/frontend-pull-secret-patch.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
spec:
  template:
    spec:
      imagePullSecrets:
        - name: ${OB_FRONTEND_PULL_SECRET}
EOF
  patches+=("frontend-pull-secret-patch.yaml frontend")
fi

# Optional: custom load profile. A strategic-merge patch, so the env entries
# merge by name (USERS/RATE are replaced, FRONTEND_ADDR is kept) and the
# container is matched by name.
if [[ -n "${OB_LOADGEN_CONFIGMAP:-}" ]]; then
  : "${OB_LOADGEN_USERS:?OB_LOADGEN_CONFIGMAP requires OB_LOADGEN_USERS}"
  : "${OB_LOADGEN_RATE:?OB_LOADGEN_CONFIGMAP requires OB_LOADGEN_RATE}"
  cat > "${workdir}/loadgenerator-patch.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: loadgenerator
spec:
  template:
    metadata:
      annotations:
        checksum/locustfile: "${OB_LOADGEN_CHECKSUM:-}"
    spec:
      containers:
        - name: main
          env:
            - name: USERS
              value: "${OB_LOADGEN_USERS}"
            - name: RATE
              value: "${OB_LOADGEN_RATE}"
          volumeMounts:
            - name: locustfile
              mountPath: /loadgen/locustfile.py
              subPath: locustfile.py
              readOnly: true
      volumes:
        - name: locustfile
          configMap:
            name: ${OB_LOADGEN_CONFIGMAP}
EOF
  patches+=("loadgenerator-patch.yaml loadgenerator")
fi

if (( ${#patches[@]} )); then
  printf 'patches:\n' >> "${workdir}/kustomization.yaml"
  for entry in "${patches[@]}"; do
    read -r file name <<< "${entry}"
    cat >> "${workdir}/kustomization.yaml" <<EOF
  - path: ${file}
    target:
      kind: Deployment
      name: ${name}
EOF
  done
fi

# kustomize is bundled inside kubectl.
if [[ "${OB_RELAX_PROBES:-false}" == "true" ]]; then
  kubectl kustomize "${workdir}" | python3 "$(dirname "${BASH_SOURCE[0]}")/relax-probes.py"
else
  kubectl kustomize "${workdir}"
fi
