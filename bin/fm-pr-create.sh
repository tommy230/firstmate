#!/usr/bin/env bash
# Guarded GitHub PR creation.
#
# Default firstmate workflow is local-main review. This wrapper refuses to open
# a GitHub PR unless the caller provides both an explicit approval switch and an
# exact target repository. Use it instead of calling `gh-axi pr create` directly.
#
# Usage:
#   FM_ALLOW_UPSTREAM_PR=1 \
#   FM_UPSTREAM_PR_TARGET=owner/repo \
#   bin/fm-pr-create.sh --repo owner/repo [gh-axi pr create args...]
set -eu

usage() {
  cat >&2 <<'USAGE'
usage: fm-pr-create.sh --repo owner/repo [gh-axi pr create args...]

Refuses by default. To intentionally create a GitHub PR, set:
  FM_ALLOW_UPSTREAM_PR=1
  FM_UPSTREAM_PR_TARGET=owner/repo

The target must also be explicit in --repo, -R, or GH_REPO and must match
FM_UPSTREAM_PR_TARGET exactly.
USAGE
}

target_repos_from_args() {
  local arg value
  while [ "$#" -gt 0 ]; do
    arg=$1
    case "$arg" in
      --repo|-R)
        shift
        [ "$#" -gt 0 ] || refuse "$arg requires a repository value."
        value=$1
        [ -n "$value" ] || refuse "$arg requires a non-empty repository value."
        printf '%s\n' "$value"
        ;;
      --repo=*)
        value=${arg#--repo=}
        [ -n "$value" ] || refuse "--repo requires a non-empty repository value."
        printf '%s\n' "$value"
        ;;
      -R?*)
        refuse "use '-R owner/repo' with a space; compact -Rowner/repo is refused."
        ;;
      --)
        refuse "'--' argument terminator is refused for guarded PR creation."
        ;;
    esac
    shift
  done

  if [ -n "${GH_REPO:-}" ]; then
    printf '%s\n' "$GH_REPO"
  fi
}

refuse() {
  echo "REFUSED: $1" >&2
  echo "Default workflow is local-main review, not upstream GitHub PR creation." >&2
  echo "To intentionally create an upstream PR, set FM_ALLOW_UPSTREAM_PR=1 and FM_UPSTREAM_PR_TARGET=owner/repo, then pass --repo owner/repo." >&2
  exit 1
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

[ "$#" -gt 0 ] || { usage; exit 1; }

TARGET_REPOS=$(target_repos_from_args "$@")

[ "${FM_ALLOW_UPSTREAM_PR:-}" = 1 ] || refuse "GitHub PR creation is blocked unless explicitly approved."
[ -n "${FM_UPSTREAM_PR_TARGET:-}" ] || refuse "FM_UPSTREAM_PR_TARGET is required for an approved upstream PR."
[ -n "$TARGET_REPOS" ] || refuse "the PR target repo must be explicit in --repo, -R, or GH_REPO."

while IFS= read -r target_repo; do
  [ -n "$target_repo" ] || continue
  [ "$target_repo" = "$FM_UPSTREAM_PR_TARGET" ] || refuse "target repo '$target_repo' does not match approved repo '$FM_UPSTREAM_PR_TARGET'."
done <<EOF
$TARGET_REPOS
EOF

exec "${FM_GH_AXI:-gh-axi}" pr create "$@"
