#!/usr/bin/env bash
#
# import-image.sh - Load locally built images into the cluster's container
# runtime, so pods can run them without a registry.
#
# Usage:
#   ./import-image.sh IMAGE:TAG [IMAGE:TAG ...]
#
# Reference them with imagePullPolicy: IfNotPresent, otherwise the kubelet
# tries to pull from a registry that has never heard of the image.
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

[ $# -gt 0 ] || die "usage: $0 IMAGE:TAG [IMAGE:TAG ...]"

require_cmd docker
provider_prereqs

for img in "$@"; do
  docker image inspect "$img" >/dev/null 2>&1 \
    || die "no local image '$img'. Build it first, or check the tag."
  step "Importing $img via $PROVIDER"
  provider_image_import "$img"
  info "done."
done

printf '\n'
info "Set imagePullPolicy: IfNotPresent on any pod using these images."
