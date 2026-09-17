# local_setup

A disposable GitOps cluster on your laptop: ArgoCD reconciling from a Gitea
server running beside it, with a Moto Server standing in for AWS. Everything
the cluster deploys comes from a directory in this repository, so there are no
external repos to create and nothing to clean up but the cluster itself.

Useful for rehearsing an ArgoCD change before it reaches a real cluster,
checking that an ApplicationSet renders what you expect, or testing an
operator without waiting on a CI pipeline.

Runs on **macOS** (Colima) and **Linux** (k3d). Both use k3s underneath, so the
manifests are identical either way.

## Quick start

```bash
git clone https://github.com/gceraso/local_setup
cd local_setup
./setup.sh

# then, when you want ArgoCD to start deploying:
kubectl apply -f .render/bootstrap/app-of-apps.yaml
```

`setup.sh` creates the cluster if it is missing, installs the base components,
pushes the manifests into Gitea and wires ArgoCD to it. It stops short of
applying the root app-of-apps so you get a working cluster to look at before
anything starts reconciling.

### Prerequisites

| | macOS | Arch Linux |
|---|---|---|
| Cluster | `brew install colima` | `sudo pacman -S k3d docker` |
| Tools | `brew install kubectl helm git curl` | `sudo pacman -S kubectl helm git curl` |
| Optional | `brew install argo argocd jq` | `sudo pacman -S jq` (argo/argocd via AUR) |

On Linux, Docker must be running and your user must be in the `docker` group.

`setup.sh` checks all of this before touching anything and tells you what is
missing.

## What you get

| Component | Namespace | URL | Login |
|-----------|-----------|-----|-------|
| Gitea | `gitea` | http://gitea.test | `gitea_admin` / `localdev123` |
| ArgoCD | `argocd` | http://argocd.test | `admin` / printed by `setup.sh` |
| AWS emulator (Moto) | `localstack` | http://localstack.test | any dummy credentials |
| External Secrets | `external-secrets` | — | — |
| Argo Workflows | `argo` | http://argo.test | none (server auth mode) |
| Argo Rollouts | `argo-rollouts` | http://rollouts.test | none |
| Argo Events | `argo-events` | — | — |
| KEDA | `keda` | — | — |

The first four are installed directly by `setup.sh`. The rest are deployed by
ArgoCD and only appear once you apply the root app-of-apps.

Hostnames use `.test`, which RFC 6761 reserves for exactly this, so they can
never collide with a real domain. `setup.sh` points them at `127.0.0.1` in
`/etc/hosts`.

## How it fits together

```
k3s (Colima on macOS / k3d on Linux)
│
├── Traefik ─────────── routes *.test to services
│
├── Gitea ───────────── holds the repo ArgoCD reads
│     └── contents come from git_dir_skel/ + private/, pushed by push-gitea.sh
│
├── ArgoCD ──────────── reconciles from Gitea over in-cluster DNS
│     └── http://gitea-http.gitea.svc.cluster.local:3000/local/argocd.git
│
└── Moto Server ──────── AWS API on :4566, backing External Secrets
```

ArgoCD reaches Gitea through service DNS rather than the ingress, so repo sync
does not depend on `/etc/hosts` or on the host network being visible from
inside a pod.

## Day to day

```bash
vim git_dir_skel/app-of-apps/orchestration/my-app.yaml
./push-gitea.sh          # ArgoCD picks it up within ~30s

argocd app list
open http://argocd.test
```

`push-gitea.sh` force-pushes, so Gitea always mirrors your working tree. It
never merges, and nothing on the Gitea side survives a push.

To deploy only part of the tree, narrow the `path` in
`bootstrap/app-of-apps.yaml` — `app-of-apps/orchestration` instead of
`app-of-apps` — and re-run `setup.sh` or re-apply the rendered manifest.

### Running a locally built image

k3s cannot pull from your Docker daemon, so images have to be side-loaded:

```bash
docker build -t my-job:latest .
./import-image.sh my-job:latest
```

Then set `imagePullPolicy: IfNotPresent` on the pod. If it is an Argo
Workflows container, also set `command:` explicitly — the emissary executor
reads the entrypoint from registry metadata, which a side-loaded image does
not have.

### Teardown

```bash
./teardown.sh              # remove the releases, keep the cluster
./teardown.sh --destroy    # delete the cluster too
./teardown.sh --hosts      # also strip the /etc/hosts entries
```

## Configuration

Every knob lives in [`config.sh`](config.sh): hostnames, chart versions,
cluster size, Kubernetes version, Gitea org and repo, which components to
install. Override without editing the tracked file:

```bash
# one-off
DOMAIN=localhost COLIMA_MEMORY=8 ./setup.sh

# persistent — config.local.sh is gitignored
cat > config.local.sh <<'EOF'
COLIMA_MEMORY=24
COMPONENTS="gitea argocd"          # skip the AWS emulator and ESO
K3D_CLUSTER_NAME=scratch

# Your own template variables, for use in private/ manifests
MY_BUCKET="acme-prod-state-9f3a2b"
EXTRA_RENDER_VARS="MY_BUCKET"
EOF
```

Manifests under `git_dir_skel/`, `bootstrap/` and `helm-values/` are templates.
`${VAR}` is substituted for any name in `RENDER_VARS` (plus whatever you list
in `EXTRA_RENDER_VARS`); ArgoCD's own `{{placeholder}}` syntax passes through
untouched. An unknown `${VAR}` fails the run rather than shipping the literal
text into the cluster.

### Choosing a provider

Auto-detected from `uname`. Force it with `PROVIDER=colima` or `PROVIDER=k3d`.
Adding another means implementing five functions in
[`lib/providers.sh`](lib/providers.sh); kind would need an ingress controller
installed too, since it has none.

## Keeping work off GitHub

This repository is public and generic. Anything tied to your employer — real
bucket names, account IDs, internal project names — goes in `private/`, which
is gitignored and merged over `git_dir_skel/` at push time.

```bash
mkdir -p private/git_dir_skel
cp -R examples/private-overlay/git_dir_skel/. private/git_dir_skel/
./push-gitea.sh
```

See [`examples/private-overlay/README.md`](examples/private-overlay/README.md).
Put values in `config.local.sh` and reference them as `${VAR}` rather than
hardcoding them, even inside the overlay.

Before pushing, check nothing leaked:

```bash
./bin/check-no-secrets.sh
DENYLIST=~/.config/local_setup/denylist ./bin/check-no-secrets.sh
```

It scans tracked files for account IDs, ARNs, access keys and anything in your
denylist. CI runs it on every pull request.

## Repository layout

```
setup.sh                 bring everything up
push-gitea.sh            publish git_dir_skel/ (+ private/) to Gitea
teardown.sh              tear it down
import-image.sh          side-load a local image into the cluster
refresh-aws-creds.sh     copy SSO credentials into a Secret for real-AWS work
config.sh                all configuration
bin/check-no-secrets.sh  leak guard
lib/
  common.sh              logging, prereqs, templating, /etc/hosts
  providers.sh           Colima and k3d behind one interface
helm-values/             values for the three Helm-installed components
manifests/               AWS emulator, applied directly with kubectl (no Helm chart exists for it)
bootstrap/               applied by setup.sh to wire ArgoCD to Gitea
git_dir_skel/            the repository ArgoCD reconciles — see its README
examples/                private-overlay template
```

## Known limits

- **OCI and ECR Helm charts do not resolve.** Karpenter and anything else
  published to a private registry will not sync. Git-sourced and public-repo
  charts are fine.
- **Private images do not pull.** Applications referencing them go Degraded,
  but ApplicationSet and Helm template rendering still validates correctly,
  which is usually what you are testing. Use `./import-image.sh` for images you
  can build locally.
- **AWS-only resources are inert.** The `gp3` StorageClass in
  `charts/cluster-svc` has no CSI driver behind it locally; a PVC bound to it
  stays Pending. It is deliberately not the default class, so it does not
  affect anything else.
- **Memory.** Colima defaults to 16 GB here. The base components use 5–6 GB
  together; the rest is headroom for whatever you deploy. Drop
  `COLIMA_MEMORY` if that is too much for your machine.
- **Chart versions are pinned and behind upstream.** `argo-cd` and
  `argo-workflows` have both had breaking majors since. Bump them
  deliberately, one at a time.

## License

MIT. See [LICENSE](LICENSE).
