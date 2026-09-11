# HolmesGPT SRE demo cluster

A scripted, reproducible minikube environment for demonstrating AI-assisted
incident investigation:

| Layer | What runs |
|---|---|
| Application | Google [Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) (11 microservices + load generator), with a **swappable frontend image** |
| Service mesh | **Linkerd** — injected into the demo namespace only, with mTLS |
| Metrics | **VictoriaMetrics** (`vmsingle` + `vmagent`), scraping Kubernetes, node, cAdvisor and every Linkerd proxy |
| Logs | **VictoriaLogs** + a Vector DaemonSet shipping every pod's stdout/stderr |
| Dashboards | **Grafana 13**, with VictoriaMetrics + VictoriaLogs datasources, Linkerd's official dashboards and a purpose-built **frontend release impact** dashboard |
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

For a one-off release without editing `.env`, pass the image on the command
line; these variables win over `.env` for that run:

```bash
# deploy a candidate frontend
FRONTEND_IMAGE_REPO=ghcr.io/ludvigsegerholmop/frontend FRONTEND_IMAGE_TAG=latest ./setup.sh --only 60

# roll back to whatever .env says
./setup.sh --only 60
```

The node must be able to pull the image anonymously (a private GHCR package
fails with `unauthorized`; make the package public or add an imagePullSecret).
On Apple Silicon a multi-arch image runs natively while the stock amd64-only
services run under emulation.

### Why this needs a post-renderer

The upstream Online Boutique chart builds every container image as

```
{{ .Values.images.repository }}/{{ .Values.<service>.name }}:{{ .Values.images.tag }}
```

There is no per-service image override — setting `images.repository` would
repoint *all eleven* services. Patching the Deployment afterwards with
`kubectl set image` works until the next `helm upgrade` reverts it.

So `manifests/helm-plugins/ob-frontend-image/post-render.sh` pipes Helm's rendered output through
kustomize's image transformer, which matches on image *name* and therefore
rewrites the frontend and nothing else. `scripts/60-online-boutique.sh` asserts
this afterwards: the frontend must equal your image, and `cartservice` must
still be on the upstream one.

---

## Watching a release: the frontend release impact dashboard

Grafana folder **Online Boutique**, dashboard **Frontend release impact**
(`/d/ob-frontend-release-impact`). It is built to answer "what did that
deployment do?" without any other context:

| Row | What it shows | Source |
|---|---|---|
| At a glance | running frontend image, success rate, p95, request rate, **catalog RPCs per request** | kube-state-metrics, Linkerd proxy |
| User-facing | latency percentiles, requests by status code, success rate, **p95 by route** (`GET /product/{id}`, `GET /cart`, ...) | frontend inbound proxy |
| Blast radius | outbound RPCs by backend, **productcatalogservice calls by gRPC method**, fan-out ratio, catalog latency, outbound failures | frontend outbound proxy |
| Resources | CPU and memory against limits, restarts, for frontend and productcatalogservice | kubelet |
| Logs | log volume by severity, per-path request time from the frontend's own request logs, warnings and errors | VictoriaLogs |

Rollouts are drawn as annotations (a new frontend image appearing in a
Running pod) and as lanes on the "Frontend image over time" panel, so the
before/after boundary is always visible.

The per-route panels come from the two Linkerd ServiceProfiles in
`manifests/online-boutique/serviceprofiles.yaml` (frontend HTTP routes and
productcatalogservice gRPC methods). Step 60 applies them before installing
the chart, because a proxy only reads a profile when it first resolves the
destination: pods that predate a profile never report route metrics until
they are restarted. Step 65 publishes the dashboard and checks the metrics
are flowing.

### Load profile

The load generator runs `manifests/online-boutique/locustfile.py` instead of
the image's built-in one. It keeps the upstream user journey but thinks for
1-3 s instead of 1-10 s and leans on the product and cart pages, which is where
a frontend that fans out to the backends shows first. `LOADGEN_USERS` and
`LOADGEN_RATE` in `.env` (default 20 users, 2/s) size it; both can be
overridden per run (`LOADGEN_USERS=40 ./setup.sh --only 60`). Edit the file and
re-run step 60 to change the mix; the pod rolls automatically because the
file's hash is on the pod template.

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
scripts/60-online-boutique   the demo app, frontend image swapped, load profile mounted
scripts/65-online-boutique-observability  ServiceProfiles + release impact dashboard
scripts/70-holmesgpt      secrets, Grafana SA token, Holmes
scripts/99-verify         live end-to-end checks
values/                   Helm values, hand-editable
manifests/helm-plugins/   the Helm post-renderer (image swap, probes, load profile)
manifests/online-boutique/  locustfile.py, Linkerd ServiceProfiles
manifests/grafana/        the release impact dashboard
certs/                    generated Linkerd CA (gitignored)
```

Steps are independent and idempotent. Re-running `./setup.sh` is safe; each
step is a `helm upgrade --install`.

---

## Access

```bash
P=holmesgpt-demo

# Grafana (admin/admin); release impact dashboard at /d/ob-frontend-release-impact
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

**Per-route panels on the release impact dashboard are empty.** The pods were
created before the ServiceProfiles (for example after editing
`manifests/online-boutique/serviceprofiles.yaml`).
`kubectl -n microservices-demo rollout restart deploy`.

**Pods in the demo namespace have no `linkerd-proxy`.** They were created before
the namespace annotation. `kubectl -n microservices-demo rollout restart deploy`.

**Grafana datasource unhealthy.** The VictoriaMetrics/VictoriaLogs datasource
plugins are downloaded from grafana.com on first boot; the pod needs egress.
Check `kubectl -n monitoring logs deploy/vm-grafana -c grafana`.

**A Holmes toolset reports an error.** `scripts/99-verify.sh` prints each
toolset's self-reported status. For detail:
`kubectl -n holmes logs deploy/holmes-holmes`.

**Re-run a single step.** `./setup.sh --only 50`, or `--from 30` to resume.
