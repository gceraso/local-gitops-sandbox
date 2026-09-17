#!/usr/bin/env bash
#
# refresh-aws-creds.sh - Copy AWS credentials for a profile into a Kubernetes
# Secret so in-cluster pods can call real AWS.
#
# Only needed when a workload must reach a real account. Anything that can be
# faked should point at LocalStack instead.
#
# Usage:
#   ./refresh-aws-creds.sh PROFILE [NAMESPACE] [SECRET_NAME]
#
# Defaults: NAMESPACE=argo, SECRET_NAME=aws-creds-PROFILE
#
# Re-run whenever the session expires; SSO sessions are typically 8h. The
# Secret holds short-lived credentials, never a long-lived access key.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT
# shellcheck source=config.sh
. "$REPO_ROOT/config.sh"
# shellcheck source=lib/common.sh
. "$REPO_ROOT/lib/common.sh"

require_cmd aws
require_cmd jq
require_cmd kubectl

PROFILE="${1:-${AWS_PROFILE:-}}"
[ -n "$PROFILE" ] || die "usage: $0 PROFILE [NAMESPACE] [SECRET_NAME]  (or export AWS_PROFILE)"

NAMESPACE="${2:-argo}"
SECRET="${3:-aws-creds-$PROFILE}"

step "Exporting credentials for profile '$PROFILE'"
creds=$(aws configure export-credentials --profile "$PROFILE" --format process 2>/dev/null) \
  || die "could not export credentials. Log in first: aws sso login --profile $PROFILE"

ak=$(printf '%s' "$creds" | jq -r '.AccessKeyId')
sk=$(printf '%s' "$creds" | jq -r '.SecretAccessKey')
st=$(printf '%s' "$creds" | jq -r '.SessionToken // empty')
expiry=$(printf '%s' "$creds" | jq -r '.Expiration // "unknown"')

if [ -z "$ak" ] || [ "$ak" = "null" ]; then
  die "no AccessKeyId in the exported credentials."
fi

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl create secret generic "$SECRET" \
  --namespace "$NAMESPACE" \
  --from-literal=AWS_ACCESS_KEY_ID="$ak" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$sk" \
  --from-literal=AWS_SESSION_TOKEN="$st" \
  --from-literal=AWS_REGION="$AWS_REGION" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

info "wrote secret '$SECRET' in namespace '$NAMESPACE'"
info "expires: $expiry"
