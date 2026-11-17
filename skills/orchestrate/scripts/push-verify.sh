#!/usr/bin/env bash
# Push a commit to a branch and VERIFY it landed: the push's exit status and its position in a
# command chain prove nothing (a slow pre-push hook can outlive the SSH connection, #262).
#
# Usage: push-verify.sh --branch NAME [--ref REV] [--remote NAME] [--no-verify] [--retries N]
#                       [--repo-dir DIR]
#   Pushes REV (default HEAD; a SHA works when the worktree is gone) to refs/heads/NAME on the
#   remote (default origin), then compares `git ls-remote REMOTE refs/heads/NAME` with REV's SHA.
#   A failed push is retried up to N more times (default 2, 3 s apart); the remote ref is read after
#   every attempt, so a push that landed but reported a dropped connection still counts as landed.
#   --no-verify skips the pre-push hook: run the repo's gates yourself first, then push with it, so
#   a slow hook cannot hold the connection open. Never forces: a rejected non-fast-forward is a failed push (exit 4).
# Output: one line, `verified: REMOTE/NAME is SHA` or `NOT verified: ...` on stderr.
# Exit: 0 remote ref equals the SHA | 2 usage | 3 push ran but the remote ref differs or is
#       absent | 4 the remote could not be read or every push attempt failed with no match
set -euo pipefail

branch="" ref=HEAD remote=origin noverify=no retries=2 dir=.
while (($#)); do
  case "$1" in
    --branch) branch=${2:-}; shift 2 ;;
    --ref) ref=${2:-}; shift 2 ;;
    --remote) remote=${2:-}; shift 2 ;;
    --no-verify) noverify=yes; shift ;;
    --retries) retries=${2:-}; shift 2 ;;
    --repo-dir) dir=${2:-}; shift 2 ;;
    -h | --help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0"; exit 0 ;;
    *) echo "push-verify.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$branch" && -n "$ref" && -n "$remote" ]] || { echo "push-verify.sh: --branch is required" >&2; exit 2; }
[[ "$retries" =~ ^[0-9]+$ ]] || { echo "push-verify.sh: bad --retries" >&2; exit 2; }
sha=$(git -C "$dir" rev-parse --verify --quiet "$ref^{commit}") || { echo "push-verify.sh: cannot resolve $ref" >&2; exit 2; }
pause=${PUSH_VERIFY_SLEEP:-3}

# remote_sha: prints the remote's SHA for the branch (empty when absent); returns 1 when unreadable.
remote_sha() {
  local out
  out=$(git -C "$dir" ls-remote "$remote" "refs/heads/$branch" 2>/dev/null) || return 1
  printf '%s\n' "$out" | awk 'NR == 1 { print $1 }'
}

args=(push)
[[ "$noverify" == no ]] || args+=(--no-verify)
args+=("$remote" "$sha:refs/heads/$branch")

attempt=0 pushed=no
while :; do
  if git -C "$dir" "${args[@]}" >&2; then pushed=yes; else pushed=no; fi
  got=""; readable=yes
  got=$(remote_sha) || readable=no
  if [[ "$readable" == yes && "$got" == "$sha" ]]; then
    echo "verified: $remote/$branch is $sha"
    exit 0
  fi
  [[ "$pushed" == yes && "$readable" == yes ]] && break
  attempt=$((attempt + 1))
  ((attempt <= retries)) || break
  sleep "$pause"
done

if [[ "$readable" == no ]]; then
  echo "NOT verified: cannot read $remote refs/heads/$branch (push $([[ $pushed == yes ]] && echo ok || echo failed)); do not assume it landed" >&2
  exit 4
fi
if [[ "$pushed" == no ]]; then
  echo "NOT verified: push failed after $((retries + 1)) attempts; $remote/$branch is ${got:-absent}, wanted $sha" >&2
  exit 4
fi
echo "NOT verified: $remote/$branch is ${got:-absent}, wanted $sha" >&2
exit 3
