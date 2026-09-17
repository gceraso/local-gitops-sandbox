#!/usr/bin/env bash
#
# check-no-secrets.sh - Refuse to ship identifying or secret-shaped strings.
#
# Scans tracked files only. private/ and config.local.sh are gitignored and so
# are never seen here, which is the point of putting work-specific values
# there.
#
# Usage:
#   ./bin/check-no-secrets.sh                run the built-in patterns
#   DENYLIST=path ./bin/check-no-secrets.sh  also fail on these strings
#
# DENYLIST is a file of one case-insensitive substring per line: employer
# names, internal project names, domains. Keep it outside the repository.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FOUND=0

report() {
  FOUND=1
  printf '\n%s\n' "FAIL: $1"
  printf '%s\n' "$2" | sed 's/^/    /'
}

scan() {
  local label="$1" pattern="$2" hits
  # -I skips binary files; grep returns 1 on no match, which is the good case.
  hits=$(git grep -InE "$pattern" -- . ':(exclude)bin/check-no-secrets.sh' 2>/dev/null || true)
  [ -n "$hits" ] && report "$label" "$hits"
  return 0
}

printf '%s\n' "Scanning tracked files for identifying and secret-shaped strings..."

# AWS account IDs. Bounded so version strings and ports do not match.
scan "possible AWS account ID (12 digits)" \
  '(^|[^0-9A-Za-z.])[0-9]{12}([^0-9A-Za-z.]|$)'

scan "AWS ARN" 'arn:aws[a-z-]*:'

# Explicit boundaries rather than \b: git grep's ERE engine does not
# implement it, and the pattern silently matches nothing.
scan "AWS access key ID" \
  '(^|[^0-9A-Za-z])(AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ANVA)[0-9A-Z]{16}([^0-9A-Za-z]|$)'

scan "private key block" '[-]{5}BEGIN [A-Z ]*PRIVATE KEY[-]{5}'

scan "GitHub / Slack token" \
  '(^|[^0-9A-Za-z])(gh[pousr]_[A-Za-z0-9]{16,}|xox[baprs]-[A-Za-z0-9-]{10,})'

# S3 bucket names carrying an org prefix and a random suffix, the shape a
# Terraform state bucket usually has.
scan "possible S3 state bucket" \
  '[a-z0-9-]+-terraform-state-[a-z0-9]{6,}'

# No generic hostname check: the repo legitimately references upstream Helm
# repositories, so it would be all false positives. Real employer domains are
# what DENYLIST is for.

if [ -n "${DENYLIST:-}" ]; then
  [ -f "$DENYLIST" ] || { printf 'error: DENYLIST file %s not found\n' "$DENYLIST" >&2; exit 2; }
  while IFS= read -r term; do
    # Skip blanks and comments.
    case "$term" in ''|'#'*) continue ;; esac
    hits=$(git grep -Iin -- "$term" 2>/dev/null || true)
    [ -n "$hits" ] && report "denylisted term '$term'" "$hits"
  done < "$DENYLIST"
fi

printf '\n'
if [ "$FOUND" -ne 0 ]; then
  printf '%s\n' "Findings above. Move the value into config.local.sh or private/ and"
  printf '%s\n' "reference it as a \${VAR} template instead."
  exit 1
fi

printf '%s\n' "Clean."
