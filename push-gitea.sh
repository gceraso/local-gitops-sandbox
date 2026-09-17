#!/usr/bin/env bash
#
# push-gitea.sh - Publish repository content to the local Gitea.
#
# Build order, lowest precedence first:
#   1. git_dir_skel/            tracked, generic
#   2. $PRIVATE_DIR/git_dir_skel/  untracked, yours; overrides or adds paths
#   3. render()                 substitutes ${VAR} from config.sh
#
# The result is force-pushed, so Gitea always mirrors your working tree
# exactly. Nothing is preserved on the Gitea side between pushes.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT
# shellcheck source=config.sh
. "$REPO_ROOT/config.sh"
# shellcheck source=lib/common.sh
. "$REPO_ROOT/lib/common.sh"

require_cmd git
require_cmd curl

GITEA_URL="http://$GITEA_HOST"
SKEL="$REPO_ROOT/git_dir_skel"
[ -d "$SKEL" ] || die "$SKEL does not exist."

info "gitea:   $GITEA_URL"
info "repo:    $GITEA_ORG/$GITEA_REPO"
info "source:  git_dir_skel/"
[ -d "$PRIVATE_DIR/git_dir_skel" ] && info "overlay: $PRIVATE_DIR/git_dir_skel/"
printf '\n'

# ---------------------------------------------------------------------------
# Wait for the Gitea API
# ---------------------------------------------------------------------------
step "Waiting for the Gitea API"
for i in $(seq 1 30); do
  if curl -sf "$GITEA_URL/api/v1/version" >/dev/null 2>&1; then
    info "ready."
    break
  fi
  [ "$i" -eq 30 ] && die "Gitea API unreachable at $GITEA_URL after 60s. Is the ingress up, and is $GITEA_HOST in /etc/hosts?"
  sleep 2
done

api() {
  curl -s -o /dev/null -w '%{http_code}' \
    -X POST "$GITEA_URL$1" \
    -u "$GITEA_ADMIN_USER:$GITEA_ADMIN_PASSWORD" \
    -H 'Content-Type: application/json' \
    -d "$2"
}

# ---------------------------------------------------------------------------
# Organisation and repository (both idempotent)
# ---------------------------------------------------------------------------
step "Ensuring organisation '$GITEA_ORG'"
code=$(api /api/v1/orgs "{\"username\":\"$GITEA_ORG\",\"visibility\":\"public\"}")
case "$code" in
  201) info "created." ;;
  422) info "already exists." ;;
  401|403) die "Gitea rejected the admin credentials (HTTP $code). Check GITEA_ADMIN_USER / GITEA_ADMIN_PASSWORD." ;;
  *)   warn "unexpected HTTP $code creating the organisation." ;;
esac

step "Ensuring repository '$GITEA_ORG/$GITEA_REPO'"
code=$(api "/api/v1/orgs/$GITEA_ORG/repos" \
  "{\"name\":\"$GITEA_REPO\",\"default_branch\":\"main\",\"auto_init\":false,\"private\":false}")
case "$code" in
  201) info "created." ;;
  409) info "already exists." ;;
  *)   warn "unexpected HTTP $code creating the repository." ;;
esac

# ---------------------------------------------------------------------------
# Assemble, render, push
# ---------------------------------------------------------------------------
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

step "Assembling repository content"
cp -R "$SKEL/." "$STAGE/"

if [ -d "$PRIVATE_DIR/git_dir_skel" ]; then
  cp -R "$PRIVATE_DIR/git_dir_skel/." "$STAGE/"
  info "private overlay applied."
fi

render_tree "$STAGE"
assert_rendered "$STAGE"
info "templates rendered."

step "Pushing to Gitea"
cd "$STAGE"
git init -q -b main
git add -A
# Identity is set locally so this never depends on the caller's global config.
git -c user.email="$GITEA_ADMIN_EMAIL" -c user.name="$GITEA_ADMIN_USER" \
  commit -q -m "local sandbox content (generated)"

# Credentials go in the URL rather than a stored remote; the staging directory
# is deleted on exit, so they are not persisted anywhere.
git remote add origin \
  "http://$GITEA_ADMIN_USER:$GITEA_ADMIN_PASSWORD@$GITEA_HOST/$GITEA_ORG/$GITEA_REPO.git"
git push -q origin main --force

printf '\n'
info "UI:         $GITEA_URL/$GITEA_ORG/$GITEA_REPO"
info "In-cluster: $GITEA_INTERNAL_URL"
