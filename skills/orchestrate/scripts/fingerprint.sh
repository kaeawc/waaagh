#!/usr/bin/env bash
# Print a stable identity for a checkout's content: base commit + working-tree diff hash.
# A dirty tree is not identified by HEAD alone, so validation results must be keyed by this.
#
# Usage: fingerprint.sh [--dir PATH] [--key COMMAND]
#   (no --key)   vcs=<git|jj> base=<sha> tree=<clean|hash> fingerprint=<base12>-<tree12>
#   --key CMD    <fingerprint>|<os-arch>|<cmd-hash12>   (cache key for one command's result)
set -euo pipefail

dir=.
key_cmd=""
while (($#)); do
  case "$1" in
    --dir) dir=$2; shift 2 ;;
    --key) key_cmd=$2; shift 2 ;;
    -h | --help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "fingerprint.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

cd "$dir"

hash_stdin() { git hash-object --stdin; }

# Emit NUL-separated path + blob hash for every untracked, non-ignored file.
untracked_stream() {
  git ls-files --others --exclude-standard -z | while IFS= read -r -d '' f; do
    printf '%s\0' "$f"
    git hash-object -- "$f"
  done
}

if command -v jj >/dev/null 2>&1 && jj root >/dev/null 2>&1; then
  vcs=jj
  # jj snapshots the working copy into @; its changes are the diff against @-.
  base=$(jj log -r @- --no-graph -T 'commit_id')
  diff=$(jj diff --git -r @)
  untracked=""
else
  vcs=git
  base=$(git rev-parse HEAD)
  diff=$(git diff HEAD --binary)
  untracked=$(untracked_stream | tr '\0' '\n')
fi

if [[ -z "$diff" && -z "$untracked" ]]; then
  tree=clean
else
  tree=$(printf '%s\n--untracked--\n%s' "$diff" "$untracked" | hash_stdin)
fi

fingerprint="${base:0:12}-${tree:0:12}"

if [[ -n "$key_cmd" ]]; then
  cmd_hash=$(printf '%s' "$key_cmd" | hash_stdin)
  printf '%s|%s|%s\n' "$fingerprint" "$(uname -sm | tr ' ' '-')" "${cmd_hash:0:12}"
else
  printf 'vcs=%s base=%s tree=%s fingerprint=%s\n' "$vcs" "$base" "$tree" "$fingerprint"
fi
