#!/usr/bin/env bash
# Print a stable identity for a checkout's content: base commit + working-tree diff hash.
# A dirty tree is not identified by HEAD alone, so validation results must be keyed by this.
#
# Usage: fingerprint.sh [--dir PATH] [--key COMMAND] [--env NAME]... [--tool CMD]...
#                       [--input PATH]... [--env-manifest FILE] [--show-env]
#   (no --key)   vcs=<git|jj> base=<sha> tree=<clean|hash> fingerprint=<base12>-<tree12>
#   --key CMD    v2|<fingerprint>|<os-arch>|<cmd-hash12>|<env-hash12>  (cache key for one
#                command's result; keys without the v2 prefix are an older contract, never reuse)
# The environment signature covers only what you declare, never the whole environment:
#   --env NAME     a variable the command reads (its value is hashed, never printed)
#   --tool CMD     a toolchain probe, e.g. "node --version"; its output and exit code are hashed
#   --input PATH   a file outside the fingerprinted tree the result depends on, e.g. an ignored
#                  dependency-install marker such as node_modules/.package-lock.json (relative
#                  to --dir); its content is hashed, "missing" if absent
#   --env-manifest FILE   lines "env NAME", "tool CMD", "input PATH"; "#" starts a comment
#   --show-env     print the declared inputs (variables only as set/unset) and the signature
# A command that depends on state it does not declare (network, services, caches, devices) is not
# eligible for result reuse: run it fresh.
set -euo pipefail

dir=.
key_cmd=""
show_env=no
decl=()
while (($#)); do
  case "$1" in
    --dir) dir=$2; shift 2 ;;
    --key) key_cmd=$2; shift 2 ;;
    --env) decl+=("env $2"); shift 2 ;;
    --tool) decl+=("tool $2"); shift 2 ;;
    --input) decl+=("input $2"); shift 2 ;;
    --env-manifest)
      [[ -f "$2" ]] || { echo "fingerprint.sh: no such manifest: $2" >&2; exit 2; }
      while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%%#*}
        line=$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
        [[ -n "$line" ]] || continue
        case "$line" in
          "env "* | "tool "* | "input "*) decl+=("$line") ;;
          *) echo "fingerprint.sh: bad manifest line: $line" >&2; exit 2 ;;
        esac
      done <"$2"
      shift 2 ;;
    --show-env) show_env=yes; shift ;;
    -h | --help) sed -n '2,21p' "$0"; exit 0 ;;
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

# One line per declared input, sorted so declaration order does not matter. Values are reduced to
# hashes here and never leave this function except through the combined signature.
env_lines() {
  local d name val out rc
  echo "envsig v1"
  for d in ${decl[@]+"${decl[@]}"}; do
    case "$d" in
      "env "*)
        name=${d#env }
        [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "fingerprint.sh: bad variable name: $name" >&2; exit 2; }
        if [[ -n "${!name+set}" ]]; then
          val=${!name}
          printf 'env %s=%s\n' "$name" "$(printf '%s' "$val" | hash_stdin)"
        else
          printf 'env %s unset\n' "$name"
        fi ;;
      "tool "*)
        rc=0
        out=$(bash -c "${d#tool }" 2>&1 </dev/null) || rc=$?
        printf 'tool %s exit=%s out=%s\n' "${d#tool }" "$rc" "$(printf '%s' "$out" | hash_stdin)" ;;
      "input "*)
        if [[ -f "${d#input }" ]]; then
          printf 'input %s=%s\n' "${d#input }" "$(git hash-object -- "${d#input }")"
        else
          printf 'input %s missing\n' "${d#input }"
        fi ;;
    esac
  done | LC_ALL=C sort -u
}

if [[ "$show_env" == yes ]]; then
  for d in ${decl[@]+"${decl[@]}"}; do
    case "$d" in
      "env "*) name=${d#env }; printf 'env %s %s\n' "$name" "$([[ -n "${!name+set}" ]] && echo set || echo unset)" ;;
      "tool "*) printf 'tool %s: %s\n' "${d#tool }" "$(bash -c "${d#tool }" 2>&1 </dev/null | head -1 || true)" ;;
      "input "*) printf 'input %s %s\n' "${d#input }" "$([[ -f "${d#input }" ]] && echo present || echo missing)" ;;
    esac
  done
fi

if [[ -n "$key_cmd" || "$show_env" == yes ]]; then
  env_sig=$(env_lines | hash_stdin)
fi

if [[ -n "$key_cmd" ]]; then
  cmd_hash=$(printf '%s' "$key_cmd" | hash_stdin)
  printf 'v2|%s|%s|%s|%s\n' "$fingerprint" "$(uname -sm | tr ' ' '-')" "${cmd_hash:0:12}" "${env_sig:0:12}"
elif [[ "$show_env" == yes ]]; then
  printf 'envsig=%s\n' "${env_sig:0:12}"
else
  printf 'vcs=%s base=%s tree=%s fingerprint=%s\n' "$vcs" "$base" "$tree" "$fingerprint"
fi
