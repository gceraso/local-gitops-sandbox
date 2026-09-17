#!/usr/bin/env bash
#
# teardown.sh - Remove the sandbox.
#
#   ./teardown.sh             uninstall the releases, leave the cluster running
#   ./teardown.sh --destroy   also delete the cluster (Colima VM / k3d cluster)
#   ./teardown.sh --hosts     also strip the managed /etc/hosts entries
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

DESTROY_CLUSTER=false
CLEAN_HOSTS=false
for arg in "$@"; do
  case "$arg" in
    --destroy) DESTROY_CLUSTER=true ;;
    --hosts)   CLEAN_HOSTS=true ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *)         die "unknown option '$arg'. See --help." ;;
  esac
done

printf '%s\n' "============================================"
printf '%s\n' "  Tearing down the local GitOps sandbox"
printf '%s\n' "============================================"
printf '\n'

if ! kubectl cluster-info >/dev/null 2>&1; then
  warn "no reachable cluster; skipping in-cluster cleanup."
else
  # ArgoCD Applications carry a resources-finalizer that blocks namespace
  # deletion if the controller is torn down first. Strip them up front.
  step "Removing ArgoCD Applications"
  for app in $(kubectl get applications -n argocd -o name 2>/dev/null || true); do
    kubectl patch "$app" -n argocd --type merge \
      -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
  done
  kubectl delete applications --all -n argocd --timeout=30s >/dev/null 2>&1 || true
  kubectl delete applicationsets --all -n argocd --timeout=30s >/dev/null 2>&1 || true
  info "done."
  printf '\n'

  step "Uninstalling Helm releases"
  for release in argocd gitea external-secrets; do
    if helm status "$release" -n "$release" >/dev/null 2>&1; then
      helm uninstall "$release" -n "$release" --wait >/dev/null 2>&1 || true
      info "$release uninstalled."
    else
      info "$release not installed."
    fi
  done
  printf '\n'

  step "Deleting namespaces"
  for ns in argocd gitea moto external-secrets argo argo-rollouts argo-events cluster-svc keda; do
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
      if kubectl delete namespace "$ns" --timeout=60s >/dev/null 2>&1; then
        info "$ns deleted."
      else
        warn "$ns did not delete cleanly (check for stuck finalizers)."
      fi
    fi
  done
  printf '\n'
fi

rm -rf "$REPO_ROOT/.render"

if [ "$CLEAN_HOSTS" = true ]; then
  step "Cleaning /etc/hosts (requires sudo)"
  remove_hosts_entries
  printf '\n'
fi

if [ "$DESTROY_CLUSTER" = true ]; then
  step "Destroying the $PROVIDER cluster"
  provider_destroy
  printf '\n'
fi

printf '%s\n' "============================================"
printf '%s\n' "  Teardown complete."
if [ "$DESTROY_CLUSTER" = false ]; then
  printf '  Cluster left running. Add --destroy to remove it.\n'
fi
if [ "$CLEAN_HOSTS" = false ]; then
  printf '  /etc/hosts left alone. Add --hosts to clean it.\n'
fi
printf '%s\n' "============================================"
