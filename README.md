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
| Chat UI | **Open WebUI**, talking to HolmesGPT through **holmes-bridge** (a Go service in `holmes-bridge/`, with SQLite persistence) |

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

Tear it down with `./teardown.sh`. Your chats survive: the teardown saves the
Open WebUI and holmes-bridge volumes to `backups/` first, and the next
`./setup.sh` puts them back (see [Surviving a teardown](#surviving-a-teardown)).
Add `--certs` to also drop the generated Linkerd CA.

---

## Configuration

All configuration is in `.env` (see `.env.example`). The values you are most
likely to change:

| Variable | Purpose |
|---|---|
| `OPENROUTER_API_KEY` | **Required.** HolmesGPT's LLM backend. |
| `HOLMES_MODEL` | LiteLLM model string, e.g. `openrouter/anthropic/claude-sonnet-4.5`. |
| `GITHUB_PAT` | Enables the GitHub MCP integration (read code, open issues). Omit to skip it. |
| `GHCR_PAT` | Classic PAT with `read:packages` for pulling a private `ghcr.io` frontend. Defaults to `GITHUB_PAT`; omit if the package is public. |
| `FRONTEND_IMAGE_REPO` / `FRONTEND_IMAGE_TAG` | The frontend image (see below). |
| `MINIKUBE_CPUS` / `MINIKUBE_MEMORY` | Cluster sizing. Defaults: 6 CPU / 12 GB. |

Chart versions and in-cluster URLs live in `lib/versions.sh`. Per-component
Helm values live in `values/` and are yours to edit.

### Where the secrets go

`.env` is the only place a credential is typed. The setup scripts turn it into
Kubernetes Secrets, each in the namespace of the thing that uses it:

| `.env` variable | Secret | Namespace | Consumer |
|---|---|---|---|
| `OPENROUTER_API_KEY` | `holmes-llm-keys` | `holmesgpt` | HolmesGPT LLM backend (step 70) |
| `GITHUB_PAT` | `github-mcp-token` | `holmesgpt` | HolmesGPT GitHub MCP server (step 70) |
| `GHCR_PAT` + `GITHUB_USER` | `ghcr-pull` (docker-registry) | `microservices-demo` | frontend `imagePullSecret`, only when the image is on a private `ghcr.io` package (step 60) |
| *(minted)* | `grafana-api-key` | `holmesgpt` | HolmesGPT Grafana toolset (step 70) |

Re-running a step re-applies its secrets, so rotating a key is: edit `.env`,
`./setup.sh --only 70` (or `--only 60` for the pull secret).

---

## Chatting with HolmesGPT (Open WebUI)

Step 75 installs [Open WebUI](https://github.com/open-webui/open-webui) in the
`holmesgpt` namespace and a Go service, **holmes-bridge**, that exposes
HolmesGPT as an OpenAI-compatible model. Open WebUI sees one model,
`holmesgpt`, and needs no plugins or pipelines.

```bash
open http://chat.$(minikube -p holmesgpt-demo ip).nip.io   # no login for the demo
```

Ask something like *"Why is the frontend slow? Check Linkerd latency and the
recent commits."* Every tool HolmesGPT runs shows up as a collapsible step in
the reply, labelled with the tool and toolset (`victorialogs_query
(victorialogs): …`, `get_file_contents (github)`), and the final analysis
follows. The bash toolset is off in `values/holmes.yaml` so every step goes
through a dedicated integration; the GitHub MCP server is limited to reading
code, commits, PRs, CI logs and issues, plus creating and commenting on
issues.

**Persistence.** Two SQLite databases, each on its own PersistentVolumeClaim:

| Database | Where | Holds |
|---|---|---|
| Open WebUI | `open-webui` PVC | chats, users, UI settings |
| holmes-bridge | `holmes-bridge-data` PVC | HolmesGPT's full conversation history per chat (tool calls included), every request with tokens/cost/duration, every tool call with its output |

Because the bridge resumes HolmesGPT from its stored history, follow-up
questions reuse the investigation so far rather than starting over. Browse the
record:

```bash
kubectl --context holmesgpt-demo -n holmesgpt port-forward svc/holmes-bridge 8000:80
curl -s localhost:8000/api/conversations
curl -s localhost:8000/api/requests?limit=5
curl -s localhost:8000/api/requests/1/tool_calls
```

### Surviving a teardown

`minikube delete` takes every PersistentVolume with it, so both databases are
copied out of the cluster before that happens and copied back into the next
one:

```bash
./teardown.sh              # -> backups/open-webui.tar.gz, backups/holmes-bridge.tar.gz
./setup.sh                 # step 75 unpacks them into the new, empty volumes
./backup.sh                # a snapshot any time, without tearing down
./backup.sh --restore      # roll the running cluster back to backups/
./teardown.sh --no-backup  # tear down without touching backups/
rm -rf backups/            # next setup starts with empty chats
```

Step 75 only restores into a volume it has just created, so re-running it on a
live cluster never rolls chats back; `./backup.sh --restore` is the explicit
way to do that. If the backup fails, the teardown stops before deleting
anything.

The copy is taken from a throwaway busybox pod with the volume mounted, with
the owning workload scaled to zero for the few seconds it takes. That matters
because Open WebUI runs SQLite in WAL mode: a `webui.db` copied out of the
running pod would be missing everything still in `webui.db-wal`, which is
typically most of the recent chats. `backups/` is gitignored. Open WebUI's
`cache/` (downloaded models, thumbnails) is left out of the archive.

**Building the bridge.** `./setup.sh --only 75` builds the image from
`holmes-bridge/` on the minikube node (`minikube image build`), so no Go
toolchain is needed locally. The tag is a hash of the source tree: edit the Go
code, re-run step 75, and only then is a new image built and rolled out. See
`holmes-bridge/README.md` for the API and configuration.

---

## Swapping the frontend image

The point of the demo is running *your* frontend against the stock backend.

```bash
# .env - the baseline the cluster comes up with (and rolls back to)
FRONTEND_IMAGE_REPO=ghcr.io/ludvigsegerholmop/frontend
FRONTEND_IMAGE_TAG=sha-8cfa654
```

Then `./setup.sh --only 60`.

### Rolling out a release

`deploy-frontend.sh` is the "ship a change, watch the agent" lever. It runs
step 60 with the image overridden, so the pull check, pull secret and
post-renderer are the same as a fresh install, and nothing is written to
`.env`:

```bash
./deploy-frontend.sh --list          # tags on FRONTEND_IMAGE_REPO (ghcr.io)
./deploy-frontend.sh --status        # what the cluster is running now
./deploy-frontend.sh sha-3a75a95     # roll a tag of FRONTEND_IMAGE_REPO out
./deploy-frontend.sh ghcr.io/someone/frontend:v2   # or any repo:tag
./deploy-frontend.sh --rollback      # back to what .env says
```

The [frontend repo](https://github.com/LudvigSegerholmOP/frontend)'s CI
pushes `ghcr.io/ludvigsegerholmop/frontend:{latest,main,sha-<short>}` for
every commit on `main`, so a release is `./deploy-frontend.sh sha-<short>`.
`sha-8cfa654` is the stock frontend; `sha-3a75a95` ("related products and
bundle recommendations") is the regression that fans out ~40 catalog RPCs per
page.

### Private ghcr.io packages

A private `ghcr.io` package is fine, with one catch: ghcr.io only accepts
**classic** PATs with `read:packages`; fine-grained tokens are rejected
whatever their permissions, so the fine-grained `GITHUB_PAT` the GitHub MCP
wants cannot double as the pull credential. Set `GHCR_PAT` to a classic token
(it defaults to `GITHUB_PAT`, which is right when that is classic), or make
the package public and leave both empty. When `FRONTEND_IMAGE_REPO` is on
`ghcr.io` and `GHCR_PAT` is set, step 60 creates the docker-registry secret
`microservices-demo/ghcr-pull` from it and the post-renderer attaches it as an
`imagePullSecret` on the frontend Deployment only.

Preflight and step 60 fetch the image manifest from this machine with the
same credentials before touching the cluster, so a token or visibility
problem fails in a second with a hint rather than as `ImagePullBackOff`
after the 15 minute Helm wait.
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
rewrites the frontend and nothing else (and, for a private registry, adds the
`imagePullSecret` with a strategic-merge patch on the same Deployment). `scripts/60-online-boutique.sh` asserts
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
teardown.sh               backs up the chat volumes to backups/, then deletes the cluster
backup.sh                 snapshot (or --restore) the Open WebUI + holmes-bridge volumes
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
scripts/70-holmesgpt      secrets (namespace holmesgpt), Grafana SA token, Holmes
scripts/75-openwebui      holmes-bridge image + Deployment, Open WebUI chart
scripts/80-ingress        ingress addon + hostnames for the three UIs
scripts/99-verify         live end-to-end checks
values/                   Helm values, hand-editable
manifests/helm-plugins/   the Helm post-renderer (image swap, probes, load profile)
manifests/online-boutique/  locustfile.py, Linkerd ServiceProfiles
manifests/grafana/        the release impact dashboard
manifests/ingress/        Ingress rules for shop., grafana., chat.<domain>
certs/                    generated Linkerd CA (gitignored)
backups/                  chat volumes saved by teardown.sh / backup.sh (gitignored)
```

Steps are independent and idempotent. Re-running `./setup.sh` is safe; each
step is a `helm upgrade --install`.

---

## Access

Step 80 enables minikube's `ingress` addon (ingress-nginx on the node's ports
80/443) and publishes one hostname per UI. With the vfkit driver the node IP is
routable from macOS, so nothing needs to be port-forwarded or tunnelled:

| UI | URL |
|---|---|
| Online Boutique | `http://shop.<domain>` |
| Grafana (admin/admin) | `http://grafana.<domain>` — release impact dashboard at `/d/ob-frontend-release-impact` |
| Open WebUI | `http://chat.<domain>` |

`<domain>` defaults to `<minikube ip>.nip.io` (e.g. `192.168.64.6.nip.io`);
[nip.io](https://nip.io) is a public wildcard DNS that resolves any
`a.b.c.d.nip.io` name to `a.b.c.d`, so there is nothing to configure locally.
`./setup.sh --only 99` prints the live URLs. If the node IP changes (it
normally survives restarts) re-run `./setup.sh --only 80`. If your DNS resolver
blocks nip.io, set `INGRESS_DOMAIN` in `.env` and point the three names at
`minikube -p holmesgpt-demo ip` in `/etc/hosts`.

The Open WebUI rule turns off nginx's response buffering and raises its
timeouts to 30 min, because a HolmesGPT investigation streams for minutes.

Everything else is still a port-forward:

```bash
P=holmesgpt-demo

# Linkerd dashboard
linkerd viz dashboard --context $P

# HolmesGPT API
kubectl --context $P -n holmesgpt port-forward svc/holmes-holmes 5050:80
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
`kubectl -n holmesgpt logs deploy/holmes-holmes`.

**Re-run a single step.** `./setup.sh --only 50`, or `--from 30` to resume.
