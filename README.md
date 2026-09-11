# HolmesGPT SRE demo cluster

A scripted, reproducible minikube environment for demonstrating AI-assisted
incident investigation:

| Layer | What runs |
|---|---|
| Application | Google [Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) (11 microservices + load generator), with a **swappable frontend image** |
| Service mesh | **Linkerd** — injected into the demo namespace only, with mTLS |
| Metrics | **VictoriaMetrics** (`vmsingle` + `vmagent`), scraping Kubernetes, node, cAdvisor and every Linkerd proxy |
| Logs | **VictoriaLogs** + a Vector DaemonSet shipping every pod's stdout/stderr |
| Dashboards | **Grafana 13**, with VictoriaMetrics + VictoriaLogs datasources and Linkerd's official dashboards |
| AI SRE | **HolmesGPT**, wired to VictoriaMetrics, VictoriaLogs, Grafana and GitHub |

Everything runs in one minikube profile (`holmesgpt-demo` by default) and does
not touch any other cluster or kube-context.

---

## Quick start

```bash
brew install minikube helm kubectl linkerd bash    # if you don't have them
cp .env.example .env                               # then edit it
./setup.sh
```

`.env` needs at minimum an `OPENROUTER_API_KEY`. Expect the first run to take
15–25 minutes, most of it pulling images.

Tear it down with `./teardown.sh` (add `--certs` to also drop the generated
Linkerd CA).

---

## Configuration

All configuration is in `.env` (see `.env.example`). The values you are most
likely to change:

| Variable | Purpose |
|---|---|
| `OPENROUTER_API_KEY` | **Required.** HolmesGPT's LLM backend. |
| `HOLMES_MODEL` | LiteLLM model string, e.g. `openrouter/anthropic/claude-sonnet-4.5`. |
| `GITHUB_PAT` | Enables the GitHub MCP integration. Omit to skip it. |
| `FRONTEND_IMAGE_REPO` / `FRONTEND_IMAGE_TAG` | The frontend image (see below). |
| `MINIKUBE_CPUS` / `MINIKUBE_MEMORY` | Cluster sizing. Defaults: 6 CPU / 12 GB. |

Chart versions and in-cluster URLs live in `lib/versions.sh`. Per-component
Helm values live in `values/` and are yours to edit.

---

## Swapping the frontend image

The point of the demo is running *your* frontend against the stock backend.

```bash
# .env
FRONTEND_IMAGE_REPO=ghcr.io/ludvigsegerholmop/frontend
FRONTEND_IMAGE_TAG=latest
```

Then `./setup.sh --only 60`.

### Why this needs a post-renderer

The upstream Online Boutique chart builds every container image as

```
{{ .Values.images.repository }}/{{ .Values.<service>.name }}:{{ .Values.images.tag }}
```

There is no per-service image override — setting `images.repository` would
repoint *all eleven* services. Patching the Deployment afterwards with
`kubectl set image` works until the next `helm upgrade` reverts it.

So `manifests/ob-frontend-post-render.sh` pipes Helm's rendered output through
kustomize's image transformer, which matches on image *name* and therefore
rewrites the frontend and nothing else. `scripts/60-online-boutique.sh` asserts
this afterwards: the frontend must equal your image, and `cartservice` must
still be on the upstream one.

---

## Layout

```
setup.sh                  entrypoint: --list / --only NN / --from NN
teardown.sh
lib/versions.sh           every pinned version and in-cluster URL
lib/common.sh             logging, waits, kubectl/helm bound to the profile
scripts/00-preflight      tool checks, .env, Helm repos, DOCKER_CONFIG shim
scripts/10-cluster        minikube profile + namespaces + injection annotation
scripts/20-linkerd        openssl trust anchor & issuer, CRDs, control plane
scripts/30-victoria-metrics  VM operator, vmsingle, vmagent, Grafana 13
scripts/40-victoria-logs  VictoriaLogs + Vector + Grafana datasource
scripts/50-linkerd-observability  scrape configs, dashboards, linkerd-viz
scripts/60-online-boutique   the demo app, frontend image swapped
scripts/70-holmesgpt      secrets, Grafana SA token, Holmes
scripts/99-verify         live end-to-end checks
values/                   Helm values, hand-editable
manifests/                the frontend post-renderer
certs/                    generated Linkerd CA (gitignored)
```

Steps are independent and idempotent. Re-running `./setup.sh` is safe; each
step is a `helm upgrade --install`.

---

## Access

```bash
P=holmesgpt-demo

# Grafana (admin/admin)
kubectl --context $P -n monitoring port-forward svc/vm-grafana 3000:80

# Online Boutique
minikube -p $P service -n microservices-demo frontend-external

# Linkerd dashboard
linkerd viz dashboard --context $P

# HolmesGPT API
kubectl --context $P -n holmes port-forward svc/holmes-holmes 5050:80
```

Ask HolmesGPT something:

```bash
curl -s localhost:5050/api/chat \
  -H 'Content-Type: application/json' \
  -d '{"ask":"Why is the frontend slow? Correlate Linkerd latency metrics with recent commits."}'
```

---

## Design notes

**Linkerd metrics reach Grafana without Linkerd's Prometheus.**
`scripts/50-linkerd-observability.sh` applies Linkerd's documented
"bring your own Prometheus" scrape configuration as two `VMScrapeConfig`
resources. The long `labelmap`/`labeldrop` chain in there is load-bearing: it is
what converts `linkerd.io/proxy-deployment` pod labels into the `deployment`,
`namespace` and `pod` labels that every Linkerd dashboard and `linkerd viz stat`
query filters on. `linkerd-viz` is then installed with `prometheus.enabled=false`
and `prometheusUrl` pointed at `vmsingle`, so there is exactly one TSDB.

Linkerd's dashboards are fetched from the `linkerd2` repo at the pinned ref and
rewritten before being published as ConfigMaps: the `__inputs`/`__requires`
import prompts are stripped (Grafana cannot provision a dashboard that still
wants interactive input) and the `datasource` template variable is bound to the
VictoriaMetrics datasource.

**`k8sRBAC: false` in `values/holmes.yaml` is deliberate.**
In the Holmes chart, `k8sRBAC: true` selects *caller-credential* mode: it
creates a ServiceAccount with `automountServiceAccountToken: false`, creates no
ClusterRole, and force-disables the `kubernetes/core`, `kubernetes/logs` and
`bash` toolsets. That is for a UI passing a per-user token. A standalone
in-cluster Holmes needs `false`.

**`DOCKER_CONFIG` is overridden during the run.**
This machine's `~/.docker/config.json` sets `"credsStore": "desktop"` while
`docker-credential-desktop` is not installed, which makes every Helm OCI pull
(the Online Boutique chart) fail with an exec error. `lib/common.sh` points
`DOCKER_CONFIG` at an empty throwaway directory. All registries used are public.

**Scrape targets that don't exist on minikube are disabled.**
`kubeEtcd`, `kubeControllerManager`, `kubeScheduler` and `kubeProxy` are turned
off in `values/victoria-metrics-k8s-stack.yaml`. Leaving them on yields
permanently-down targets, which is exactly the sort of false signal that
derails an AI investigation.

---

## Troubleshooting

**minikube won't start / OOM.** `podman machine stop` frees ~10 GB, or lower
`MINIKUBE_MEMORY`.

**Online Boutique pods crash with `exec format error` (Apple Silicon).** Every
Online Boutique image is amd64-only; the minikube node is arm64. Step 10
registers QEMU emulation on the node (`tonistiigi/binfmt`) and step 60 relaxes
the chart's probes, since the emulated services start slowly. The registration
lives in kernel memory, so it is redone on every `./setup.sh` - if you restart
the VM by hand, run `./setup.sh --only 10` before the pods will start again.

**`helm: another operation (install/upgrade/rollback) is in progress`.** A
previous install was interrupted mid-`--wait`. Clear it with
`helm -n microservices-demo uninstall onlineboutique` and re-run. If the pods
that follow fail with `file integrity checksum failed` in `docker save`, the
VM lost writes during the interruption and the node's image store is corrupt -
`./teardown.sh && ./setup.sh` is the only clean fix.

**Pods in the demo namespace have no `linkerd-proxy`.** They were created before
the namespace annotation. `kubectl -n microservices-demo rollout restart deploy`.

**Grafana datasource unhealthy.** The VictoriaMetrics/VictoriaLogs datasource
plugins are downloaded from grafana.com on first boot; the pod needs egress.
Check `kubectl -n monitoring logs deploy/vm-grafana -c grafana`.

**A Holmes toolset reports an error.** `scripts/99-verify.sh` prints each
toolset's self-reported status. For detail:
`kubectl -n holmes logs deploy/holmes-holmes`.

**Re-run a single step.** `./setup.sh --only 50`, or `--from 30` to resume.
