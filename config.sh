#!/usr/bin/env bash
#
# Configuration for the local GitOps sandbox.
#
# Every value below can be overridden two ways:
#   1. Export the variable before running a script:  DOMAIN=localhost ./setup.sh
#   2. Create config.local.sh (gitignored) and set it there.
#
# Nothing in this file is a secret. GITEA_ADMIN_PASSWORD guards a throwaway Git
# server that only listens on your loopback interface.

# Sourced first so that every ${VAR:-default} below sees the override, and so
# derived values like GITEA_INTERNAL_URL are built from the overridden inputs.
if [ -f "${REPO_ROOT:-.}/config.local.sh" ]; then
  # shellcheck disable=SC1091
  . "${REPO_ROOT:-.}/config.local.sh"
fi

# ---------------------------------------------------------------------------
# Cluster provider
# ---------------------------------------------------------------------------
# colima -> macOS (Lima VM running k3s)
# k3d    -> Linux (k3s in Docker)
# Both run k3s, so Traefik and the ingress story are identical either way.
if [ -z "${PROVIDER:-}" ]; then
  case "$(uname -s)" in
    Darwin) PROVIDER="colima" ;;
    Linux)  PROVIDER="k3d" ;;
    *)      PROVIDER="k3d" ;;
  esac
fi

# Kubernetes version. Use the k3s release format; the k3d provider rewrites
# "+" to "-" for the container image tag.
K8S_VERSION="${K8S_VERSION:-v1.35.3+k3s1}"

# Colima only. Empty means the default profile, which is what a plain
# `colima start` gives you. Set this to run the sandbox in its own VM.
COLIMA_PROFILE="${COLIMA_PROFILE:-}"
COLIMA_MEMORY="${COLIMA_MEMORY:-16}"
COLIMA_CPUS="${COLIMA_CPUS:-4}"
COLIMA_DISK="${COLIMA_DISK:-60}"

# k3d only.
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-gitops-local}"
K3D_SERVERS="${K3D_SERVERS:-1}"
K3D_AGENTS="${K3D_AGENTS:-0}"

# ---------------------------------------------------------------------------
# Hostnames
# ---------------------------------------------------------------------------
# ".test" is reserved by RFC 6761 for exactly this, so it can never collide
# with a real domain. Entries are added to /etc/hosts pointing at 127.0.0.1.
DOMAIN="${DOMAIN:-test}"

GITEA_HOST="${GITEA_HOST:-gitea.${DOMAIN}}"
ARGOCD_HOST="${ARGOCD_HOST:-argocd.${DOMAIN}}"
ARGO_HOST="${ARGO_HOST:-argo.${DOMAIN}}"
ROLLOUTS_HOST="${ROLLOUTS_HOST:-rollouts.${DOMAIN}}"
LOCALSTACK_HOST="${LOCALSTACK_HOST:-localstack.${DOMAIN}}"

# Every hostname the setup script manages in /etc/hosts.
MANAGED_HOSTS="${MANAGED_HOSTS:-$GITEA_HOST $ARGOCD_HOST $ARGO_HOST $ROLLOUTS_HOST $LOCALSTACK_HOST}"

# ---------------------------------------------------------------------------
# Gitea
# ---------------------------------------------------------------------------
GITEA_ORG="${GITEA_ORG:-local}"
GITEA_REPO="${GITEA_REPO:-argocd}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-gitea_admin}"
GITEA_ADMIN_PASSWORD="${GITEA_ADMIN_PASSWORD:-localdev123}"
GITEA_ADMIN_EMAIL="${GITEA_ADMIN_EMAIL:-admin@local.dev}"

# What ArgoCD uses to reach Gitea. In-cluster service DNS, not the ingress,
# so repo sync does not depend on /etc/hosts or the host network.
GITEA_INTERNAL_URL="${GITEA_INTERNAL_URL:-http://gitea-http.gitea.svc.cluster.local:3000/${GITEA_ORG}/${GITEA_REPO}.git}"

# ---------------------------------------------------------------------------
# Chart versions
# ---------------------------------------------------------------------------
# Bump deliberately: `helm search repo <chart>` and read the changelog first.
# argo-cd and argo-workflows have both had breaking major bumps recently.
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-9.5.2}"
GITEA_CHART_VERSION="${GITEA_CHART_VERSION:-10.6.0}"
ESO_CHART_VERSION="${ESO_CHART_VERSION:-0.17.0}"

# ---------------------------------------------------------------------------
# Components installed directly by setup.sh (Helm), in order.
# ---------------------------------------------------------------------------
# Everything else (Argo Workflows, Rollouts, Events, KEDA, ...) is deployed by
# ArgoCD from the Gitea repo. Drop a name here to skip it entirely.
COMPONENTS="${COMPONENTS:-gitea localstack external-secrets argocd}"

# ---------------------------------------------------------------------------
# AWS emulator (Moto Server, applied via manifests/aws-emulator.yaml)
# ---------------------------------------------------------------------------
# Kept the "LOCALSTACK_*" names since the rest of the sandbox (ESO wiring,
# /etc/hosts, the summary printed by setup.sh) refers to this by role, not by
# which emulator is behind it. The in-cluster namespace/Service are named
# "moto" to match what's actually running there.
AWS_REGION="${AWS_REGION:-us-east-1}"
MOTO_IMAGE_TAG="${MOTO_IMAGE_TAG:-5.2.3}"
LOCALSTACK_INTERNAL_URL="${LOCALSTACK_INTERNAL_URL:-http://moto.moto.svc.cluster.local:4566}"

# ---------------------------------------------------------------------------
# Private overlay
# ---------------------------------------------------------------------------
# Contents of $PRIVATE_DIR/git_dir_skel are copied over git_dir_skel/ at push
# time, so work-specific Applications never touch this repository's history.
# The directory is gitignored. See examples/private-overlay/.
PRIVATE_DIR="${PRIVATE_DIR:-${REPO_ROOT:-.}/private}"

# ---------------------------------------------------------------------------
# Template variables
# ---------------------------------------------------------------------------
# Names substituted into manifests and Helm values by render(). Templates use
# the ${NAME} form; ArgoCD's own {{placeholder}} syntax is left untouched.
#
# To add your own, set EXTRA_RENDER_VARS in config.local.sh rather than
# editing this list. config.local.sh is sourced before this point, so it
# cannot append to RENDER_VARS directly.
RENDER_VARS="${RENDER_VARS:-
  DOMAIN
  GITEA_HOST ARGOCD_HOST ARGO_HOST ROLLOUTS_HOST LOCALSTACK_HOST
  GITEA_ORG GITEA_REPO GITEA_ADMIN_USER GITEA_ADMIN_PASSWORD GITEA_ADMIN_EMAIL
  GITEA_INTERNAL_URL
  ARGOCD_CHART_VERSION GITEA_CHART_VERSION
  AWS_REGION MOTO_IMAGE_TAG LOCALSTACK_INTERNAL_URL
} ${EXTRA_RENDER_VARS:-}"
