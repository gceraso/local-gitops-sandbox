#!/usr/bin/env bash
#
# Shared helpers. Source this after config.sh.

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _c_bold=$'\033[1m'; _c_red=$'\033[31m'; _c_yellow=$'\033[33m'; _c_off=$'\033[0m'
else
  _c_bold=""; _c_red=""; _c_yellow=""; _c_off=""
fi

step() { printf '%s==> %s%s\n' "$_c_bold" "$*" "$_c_off"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%swarning:%s %s\n' "$_c_yellow" "$_c_off" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$_c_red" "$_c_off" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
# Package name differs per platform, so the hint has to as well.
pkg_hint() {
  case "$(uname -s)" in
    Darwin) printf 'brew install %s' "$1" ;;
    Linux)  printf 'sudo pacman -S %s   (or your distro equivalent)' "$1" ;;
    *)      printf 'install %s' "$1" ;;
  esac
}

require_cmd() {
  local cmd="$1" pkg="${2:-$1}"
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found. Try: $(pkg_hint "$pkg")"
}

# Polls a command until it succeeds or the timeout elapses. k3s installs
# Traefik (and other packaged components) asynchronously via a HelmChart CRD
# job that only starts once the API server is up, so a resource can be
# legitimately absent for a few seconds right after the cluster reports
# ready -- a one-shot check races it.
wait_for() {
  local timeout="$1" waited=0; shift
  until "$@" >/dev/null 2>&1; do
    [ "$waited" -ge "$timeout" ] && return 1
    sleep 2
    waited=$((waited + 2))
  done
}

# ---------------------------------------------------------------------------
# Templating
# ---------------------------------------------------------------------------
# Substitutes ${NAME} for each name in RENDER_VARS. Deliberately not envsubst:
# that lives in gettext, which is not installed by default on macOS, and it
# would also expand every other $-sequence in a manifest.
#
# Reads stdin, writes stdout.
render() {
  local name value args=()
  for name in $RENDER_VARS; do
    eval "value=\${$name-}"
    # Escape what sed treats as special in a replacement, plus the delimiter.
    value=${value//\\/\\\\}
    value=${value//|/\\|}
    value=${value//&/\\&}
    value=${value//$'\n'/ }
    args+=(-e "s|\${$name}|$value|g")
  done
  sed "${args[@]}"
}

# Renders one file to a destination path, creating parent directories.
render_file() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  render < "$src" > "$dst"
}

# Renders every .yaml/.yml file under a directory tree in place.
render_tree() {
  local dir="$1" f tmp
  while IFS= read -r f; do
    tmp="$f.rendered"
    render < "$f" > "$tmp" && mv "$tmp" "$f"
  done < <(find "$dir" -type f \( -name '*.yaml' -o -name '*.yml' \))
}

# Fails loudly if a rendered tree still contains template markers. Without
# this a typo in RENDER_VARS ships a literal "${FOO}" into the cluster, where
# it surfaces much later as an unresolvable hostname.
#
# Scoped to the same files render_tree touches. Markdown is excluded on
# purpose: documentation quotes ${VAR} to explain the mechanism, and flagging
# that would make the check unusable.
assert_rendered() {
  local dir="$1" leftovers
  leftovers=$(find "$dir" -type f \( -name '*.yaml' -o -name '*.yml' \) \
    -exec grep -lE '\$\{[A-Z_]+\}' {} + 2>/dev/null || true)
  if [ -n "$leftovers" ]; then
    warn "unsubstituted template variables remain in:"
    # shellcheck disable=SC2086  # deliberate split on the newline-separated list
    printf '      %s\n' $leftovers >&2
    printf '%s\n' "$leftovers" | while IFS= read -r f; do
      grep -ohE '\$\{[A-Z_]+\}' "$f" 2>/dev/null || true
    done | sort -u | sed 's/^/      /' >&2
    die "add the missing names to EXTRA_RENDER_VARS in config.local.sh, or to RENDER_VARS in config.sh"
  fi
}

# ---------------------------------------------------------------------------
# /etc/hosts
# ---------------------------------------------------------------------------
ensure_hosts_entries() {
  local host missing=()
  for host in $MANAGED_HOSTS; do
    # Word-boundary match so "argo.test" does not satisfy "argocd.test".
    grep -qE "(^|[[:space:]])${host}([[:space:]]|$)" /etc/hosts 2>/dev/null || missing+=("$host")
  done

  [ ${#missing[@]} -eq 0 ] && { info "/etc/hosts already has all entries."; return 0; }

  step "Adding ${#missing[@]} entries to /etc/hosts (requires sudo)"
  for host in "${missing[@]}"; do
    printf '127.0.0.1 %s\n' "$host" | sudo tee -a /etc/hosts >/dev/null
    info "added $host"
  done
}

remove_hosts_entries() {
  local host tmp changed=0
  tmp=$(mktemp)
  cp /etc/hosts "$tmp"

  for host in $MANAGED_HOSTS; do
    if grep -qE "(^|[[:space:]])${host}([[:space:]]|$)" "$tmp"; then
      # Built up as the current user, then written back in a single sudo call.
      # No -i: BSD and GNU sed disagree on whether it takes an argument.
      sed "/^127\.0\.0\.1[[:space:]]\{1,\}${host//./\\.}$/d" "$tmp" > "$tmp.new"
      mv "$tmp.new" "$tmp"
      changed=1
      info "removed $host"
    fi
  done

  if [ "$changed" -eq 1 ]; then
    # shellcheck disable=SC2024  # the redirect is input, from a file we own;
    # sudo is only needed for tee's write to /etc/hosts.
    sudo tee /etc/hosts < "$tmp" >/dev/null
  else
    info "no managed entries present."
  fi
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
# BSD base64 wants -D, GNU wants -d; both accept --decode.
b64decode() { base64 --decode; }
