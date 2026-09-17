#!/usr/bin/env bash
#
# Cluster provider abstraction.
#
# Each provider implements four functions:
#   provider_prereqs        check required binaries
#   provider_ensure_cluster create/start the cluster if it is not running
#   provider_context        print the kubectl context name
#   provider_image_import   load a locally built image into the cluster
#   provider_destroy        delete the cluster entirely
#
# Adding a provider means adding a case branch to each. Both shipped providers
# run k3s, so Traefik is present and the ingress manifests are identical.

# ---------------------------------------------------------------------------
# colima (macOS)
# ---------------------------------------------------------------------------
# Built once at source time. An array rather than a string so an empty profile
# does not expand into a stray empty argument.
COLIMA_ARGS=()
[ -n "${COLIMA_PROFILE:-}" ] && COLIMA_ARGS=(-p "$COLIMA_PROFILE")

colima_prereqs() {
  require_cmd colima
  require_cmd docker
}

colima_context() {
  if [ -n "$COLIMA_PROFILE" ]; then printf 'colima-%s' "$COLIMA_PROFILE"; else printf 'colima'; fi
}

colima_ensure_cluster() {
  if colima status "${COLIMA_ARGS[@]+"${COLIMA_ARGS[@]}"}" >/dev/null 2>&1; then
    info "Colima already running."
    # A Colima VM started without --with-kubernetes has no cluster at all, and
    # the failure downstream is an opaque connection refused.
    kubectl --context "$(colima_context)" cluster-info >/dev/null 2>&1 || die \
      "Colima is running but has no Kubernetes cluster. Recreate it: colima delete ${COLIMA_PROFILE:+-p $COLIMA_PROFILE} && $0"
    return 0
  fi

  step "Starting Colima (k8s $K8S_VERSION, ${COLIMA_MEMORY} GB, ${COLIMA_CPUS} CPU)"
  # --k3s-arg replaces Colima's default of --disable=traefik, which is why
  # Traefik ends up enabled here.
  colima start "${COLIMA_ARGS[@]+"${COLIMA_ARGS[@]}"}" \
    --with-kubernetes \
    --kubernetes-version "$K8S_VERSION" \
    --k3s-arg='--write-kubeconfig-mode=644' \
    --cpu "$COLIMA_CPUS" \
    --memory "$COLIMA_MEMORY" \
    --disk "$COLIMA_DISK"
}

colima_image_import() {
  docker save "$1" \
    | colima ssh "${COLIMA_ARGS[@]+"${COLIMA_ARGS[@]}"}" -- sudo ctr --namespace k8s.io images import -
}

colima_destroy() {
  colima delete -f "${COLIMA_ARGS[@]+"${COLIMA_ARGS[@]}"}"
}

# ---------------------------------------------------------------------------
# k3d (Linux)
# ---------------------------------------------------------------------------
k3d_prereqs() {
  require_cmd k3d
  require_cmd docker
  docker info >/dev/null 2>&1 || die \
    "cannot talk to the Docker daemon. Start it (sudo systemctl start docker) and make sure your user is in the 'docker' group."
}

k3d_context() { printf 'k3d-%s' "$K3D_CLUSTER_NAME"; }

k3d_ensure_cluster() {
  if k3d cluster list "$K3D_CLUSTER_NAME" >/dev/null 2>&1; then
    info "k3d cluster '$K3D_CLUSTER_NAME' exists."
    k3d cluster start "$K3D_CLUSTER_NAME" >/dev/null 2>&1 || true
    return 0
  fi

  # Container tags cannot contain "+", which the k3s version string uses.
  local image_tag="${K8S_VERSION//+/-}"

  step "Creating k3d cluster '$K3D_CLUSTER_NAME' (k8s $K8S_VERSION)"
  # Publishing 80/443 on the loadbalancer is what makes http://gitea.test
  # resolve to the cluster the same way it does through Colima's VM.
  k3d cluster create "$K3D_CLUSTER_NAME" \
    --image "rancher/k3s:${image_tag}" \
    --servers "$K3D_SERVERS" \
    --agents "$K3D_AGENTS" \
    --port "80:80@loadbalancer" \
    --port "443:443@loadbalancer" \
    --k3s-arg '--write-kubeconfig-mode=644@server:*' \
    --wait
}

k3d_image_import() { k3d image import "$1" --cluster "$K3D_CLUSTER_NAME"; }

k3d_destroy() { k3d cluster delete "$K3D_CLUSTER_NAME"; }

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
_dispatch() {
  local fn="${PROVIDER}_$1"; shift
  command -v "$fn" >/dev/null 2>&1 \
    || die "unknown PROVIDER '$PROVIDER'. Supported: colima, k3d."
  "$fn" "$@"
}

provider_prereqs()        { _dispatch prereqs; }
provider_ensure_cluster() { _dispatch ensure_cluster; }
provider_context()        { _dispatch context; }
provider_image_import()   { _dispatch image_import "$1"; }
provider_destroy()        { _dispatch destroy; }
