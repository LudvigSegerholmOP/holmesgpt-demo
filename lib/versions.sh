#!/usr/bin/env bash
# Single source of truth for every pinned version and in-cluster endpoint.
# Bump here, nowhere else.

# ---------------------------------------------------------------------------
# Helm repositories
# ---------------------------------------------------------------------------
readonly REPO_VM="https://victoriametrics.github.io/helm-charts"
readonly REPO_LINKERD="https://helm.linkerd.io/edge"
readonly REPO_ROBUSTA="https://robusta-charts.storage.googleapis.com"

# ---------------------------------------------------------------------------
# Chart versions
# ---------------------------------------------------------------------------
readonly VER_VM_K8S_STACK="0.91.2"        # VictoriaMetrics v1.150.0, Grafana 13.1.1
readonly VER_VM_LOGS_SINGLE="0.13.9"      # VictoriaLogs v1.52.0
readonly VER_LINKERD="2026.8.4"           # edge-26.8.4 (crds, control-plane, viz)
readonly VER_HOLMES="0.40.0"

# 0.10.5, not 0.10.6, deliberately. The chart defaults images.repository to the
# public us-central1-docker.pkg.dev/google-samples/microservices-demo and
# images.tag to .Chart.AppVersion. That registry only publishes up to v0.10.5 -
# chart 0.10.6 renders :v0.10.6 tags that exist solely in the online-boutique-ci
# registry, so every service lands in ImagePullBackOff. 0.10.5 is internally
# consistent: all 11 images resolve against the public registry.
readonly VER_ONLINE_BOUTIQUE="0.10.5"

# Git ref used to fetch Linkerd's official Grafana dashboards
readonly LINKERD_DASHBOARD_REF="edge-26.8.4"

# ---------------------------------------------------------------------------
# Images
# ---------------------------------------------------------------------------
# Explicit Grafana 13 pin. The chart already defaults to 13.1.1; this makes the
# requirement enforceable rather than incidental.
readonly GRAFANA_IMAGE_TAG="13.2.0"

# Online Boutique upstream frontend image, i.e. the image the chart renders by
# default and which the post-renderer rewrites.
readonly OB_UPSTREAM_IMAGE_REPO="us-central1-docker.pkg.dev/google-samples/microservices-demo"

# QEMU user-mode emulation installer, run on the node when it is not amd64
# (the Online Boutique images are amd64-only). See scripts/10-cluster.sh.
readonly BINFMT_IMAGE="tonistiigi/binfmt:qemu-v10.2.3"

# ---------------------------------------------------------------------------
# Namespaces
# ---------------------------------------------------------------------------
readonly NS_MONITORING="monitoring"
readonly NS_LINKERD="linkerd"
readonly NS_LINKERD_VIZ="linkerd-viz"
readonly NS_DEMO="microservices-demo"
readonly NS_HOLMES="holmesgpt"

# ---------------------------------------------------------------------------
# Helm release names
# ---------------------------------------------------------------------------
readonly REL_VM="vm"
readonly REL_VLOGS="vlogs"
readonly REL_LINKERD_CRDS="linkerd-crds"
readonly REL_LINKERD_CP="linkerd-control-plane"
readonly REL_LINKERD_VIZ="linkerd-viz"
readonly REL_OB="onlineboutique"
readonly REL_HOLMES="holmes"

# ---------------------------------------------------------------------------
# In-cluster endpoints
#
# These depend on fullnameOverride settings in values/. The VictoriaMetrics
# operator derives Service names from the CR name, so `fullnameOverride: vm`
# yields the VMSingle CR `vm` and therefore the Service `vmsingle-vm`.
# ---------------------------------------------------------------------------
readonly URL_VMSINGLE="http://vmsingle-${REL_VM}.${NS_MONITORING}.svc.cluster.local:8428"
readonly URL_VMALERTMANAGER="http://vmalertmanager-${REL_VM}.${NS_MONITORING}.svc.cluster.local:9093"
readonly URL_GRAFANA="http://${REL_VM}-grafana.${NS_MONITORING}.svc.cluster.local"
readonly URL_VICTORIALOGS="http://victorialogs.${NS_MONITORING}.svc.cluster.local:9428"

# Grafana datasource created by victoria-metrics-k8s-stack (name == uid).
readonly GRAFANA_VM_DATASOURCE="VictoriaMetrics"
readonly GRAFANA_VL_DATASOURCE="VictoriaLogs"

# Online Boutique extras published by scripts/60 and scripts/65.
readonly OB_LOADGEN_CONFIGMAP="loadgenerator-locustfile"
# imagePullSecret for a private ghcr.io frontend, built from GITHUB_PAT.
readonly OB_PULL_SECRET="ghcr-pull"
readonly OB_DASHBOARD_UID="ob-frontend-release-impact"
readonly OB_DASHBOARD_FOLDER="Online Boutique"

# The holmes chart names its objects "<release>-holmes" and exposes port 80
# in front of the container's 5050.
readonly HOLMES_FULLNAME="${REL_HOLMES}-holmes"
readonly URL_HOLMES="http://${HOLMES_FULLNAME}.${NS_HOLMES}.svc.cluster.local:80"
