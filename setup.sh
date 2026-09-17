#!/usr/bin/env bash
#
# setup.sh - Bring up the local GitOps sandbox.
#
#   1. Start the cluster (Colima on macOS, k3d on Linux)
#   2. Install Gitea, the AWS emulator, External Secrets, ArgoCD
#   3. Push git_dir_skel/ (+ the private overlay) into Gitea
#   4. Wire ArgoCD to Gitea and apply the AppProjects
#
# The root app-of-apps is deliberately NOT applied; run the command printed at
# the end when you want ArgoCD to start reconciling.
#
# Everything configurable lives in config.sh.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT
# shellcheck source=config.sh
. "$REPO_ROOT/config.sh"
# shellcheck source=lib/common.sh
. "$REPO_ROOT/lib/common.sh"
# shellcheck source=lib/providers.sh
. "$REPO_ROOT/lib/providers.sh"

RENDER_DIR="$REPO_ROOT/.render"

printf '%s\n' "============================================"
printf '%s\n' "  Local GitOps sandbox"
printf '%s\n' "============================================"
info "provider:   $PROVIDER ($(uname -s))"
info "kubernetes: $K8S_VERSION"
info "components: $COMPONENTS"
info "gitea repo: $GITEA_ORG/$GITEA_REPO"
printf '\n'

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
step "Checking prerequisites"
require_cmd kubectl
require_cmd helm
require_cmd git
require_cmd curl
provider_prereqs
info "all present."
printf '\n'

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------
step "Ensuring cluster is up"
provider_ensure_cluster

CONTEXT="$(provider_context)"
kubectl config use-context "$CONTEXT" >/dev/null 2>&1 \
  || die "kubectl context '$CONTEXT' not found. Check: kubectl config get-contexts"
kubectl cluster-info >/dev/null 2>&1 \
  || die "cannot reach the cluster on context '$CONTEXT'."
info "context: $CONTEXT"

wait_for 90 kubectl get deploy traefik -n kube-system \
  || die "Traefik not found in kube-system after 90s. The ingress hostnames will not work. Recreate the cluster: ./teardown.sh --destroy && $0"
kubectl wait --for=condition=Available deploy/traefik -n kube-system --timeout=90s >/dev/null 2>&1 \
  || die "Traefik deployment did not become Available. Check: kubectl get pods -n kube-system"
info "Traefik ingress controller present."
printf '\n'

# ---------------------------------------------------------------------------
# Render Helm values and bootstrap manifests
# ---------------------------------------------------------------------------
step "Rendering manifests"
rm -rf "$RENDER_DIR"
mkdir -p "$RENDER_DIR"
cp -R "$REPO_ROOT/helm-values" "$RENDER_DIR/helm-values"
cp -R "$REPO_ROOT/bootstrap" "$RENDER_DIR/bootstrap"
cp -R "$REPO_ROOT/manifests" "$RENDER_DIR/manifests"
render_tree "$RENDER_DIR"
assert_rendered "$RENDER_DIR"
info "rendered into .render/"
printf '\n'

# ---------------------------------------------------------------------------
# Helm repos
# ---------------------------------------------------------------------------
step "Adding Helm repositories"
helm repo add gitea-charts https://dl.gitea.com/charts/ >/dev/null 2>&1 || true
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo update >/dev/null
info "done."
printf '\n'

# ---------------------------------------------------------------------------
# Components
# ---------------------------------------------------------------------------
install_component() {
  local name="$1" chart="$2" version="$3" namespace="$4" timeout="${5:-5m}"

  step "Installing $name ($chart $version)"
  helm upgrade --install "$name" "$chart" \
    --namespace "$namespace" \
    --create-namespace \
    --version "$version" \
    --values "$RENDER_DIR/helm-values/${name}.yaml" \
    --wait \
    --timeout "$timeout"
  info "$name ready."
  printf '\n'
}

component_enabled() {
  case " $COMPONENTS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

component_enabled gitea &&
  install_component gitea gitea-charts/gitea "$GITEA_CHART_VERSION" gitea

component_enabled localstack && {
  step "Installing AWS emulator (Moto Server $MOTO_IMAGE_TAG) in namespace moto"
  kubectl apply -f "$RENDER_DIR/manifests/aws-emulator.yaml"
  kubectl -n moto rollout status deployment/moto --timeout=2m
  info "moto ready."
  printf '\n'
}

component_enabled external-secrets &&
  install_component external-secrets external-secrets/external-secrets "$ESO_CHART_VERSION" external-secrets 10m

component_enabled argocd && {
  # --force-conflicts: the ArgoCD CRDs are large enough that a re-run trips
  # server-side-apply field ownership from the previous release.
  step "Installing argocd (argo/argo-cd $ARGOCD_CHART_VERSION)"
  helm upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --create-namespace \
    --version "$ARGOCD_CHART_VERSION" \
    --values "$RENDER_DIR/helm-values/argocd.yaml" \
    --force-conflicts \
    --wait \
    --timeout 5m
  info "argocd ready."
  printf '\n'
}

# ---------------------------------------------------------------------------
# /etc/hosts
# ---------------------------------------------------------------------------
step "Checking /etc/hosts"
ensure_hosts_entries
printf '\n'

# ---------------------------------------------------------------------------
# Seed Gitea
# ---------------------------------------------------------------------------
component_enabled gitea && {
  step "Pushing repository content to Gitea"
  bash "$REPO_ROOT/push-gitea.sh"
  printf '\n'
}

# ---------------------------------------------------------------------------
# Wire ArgoCD to Gitea
# ---------------------------------------------------------------------------
component_enabled argocd && {
  step "Applying ArgoCD bootstrap manifests"
  kubectl apply -f "$RENDER_DIR/bootstrap/argocd-repo-secret.yaml"
  kubectl apply -f "$RENDER_DIR/bootstrap/appprojects.yaml"
  info "repo credentials and AppProjects applied."
  printf '\n'
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | b64decode 2>/dev/null || printf 'not found')

cat <<EOF
============================================
  Setup complete
============================================

  Gitea           http://$GITEA_HOST            $GITEA_ADMIN_USER / $GITEA_ADMIN_PASSWORD
  ArgoCD          http://$ARGOCD_HOST           admin / $ARGOCD_PASSWORD
  Argo Workflows  http://$ARGO_HOST             (server auth mode, no login)
  Argo Rollouts   http://$ROLLOUTS_HOST         (dashboard, no login)
  AWS emulator    http://$LOCALSTACK_HOST       (any dummy AWS credentials)

  In-cluster endpoints:
    Gitea repo    $GITEA_INTERNAL_URL
    AWS API       $LOCALSTACK_INTERNAL_URL

  Argo Workflows and Rollouts are deployed by ArgoCD, so they only appear
  after you apply the root app-of-apps:

    kubectl apply -f $RENDER_DIR/bootstrap/app-of-apps.yaml

  Other commands:
    ./push-gitea.sh                 re-push git_dir_skel/ after editing
    ./import-image.sh IMAGE:TAG     load a local image into the cluster
    ./teardown.sh                   remove the releases, keep the cluster
    ./teardown.sh --destroy         delete the cluster too
============================================
EOF
