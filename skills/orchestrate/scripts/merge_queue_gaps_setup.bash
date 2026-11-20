# Setup and helpers shared by merge-queue-gaps.bats and merge-queue-review.bats
# (split for a shorter parallel run, #112).
# Loaded at file level by both; not a suite itself.

# The origin and seed fixture: built once per file, copied per test (test_helper.bash, #112).
setup_file() {
  load test_helper
  seed_origin_template
}

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  export ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state" ORCHESTRATE_AUTHOR=me ORCHESTRATE_NOW=1790510400 ORCHESTRATE_READ_SLEEP=0
  unset ORCHESTRATE_REVIEW_BOT_LOGIN ORCHESTRATE_REVIEW_TRIGGER ORCHESTRATE_REVIEW_CHECK ORCHESTRATE_REVIEW_QUOTA_RE ORCHESTRATE_REVIEW_EVERY ORCHESTRATE_REVIEW_PROBE_EVERY MERGE_QUEUE_CHECK_CMD MERGE_QUEUE_ADMIN_EVIDENCE MERGE_QUEUE_ADMIN_CHECKS ORCHESTRATE_DIRECT_MERGE \
    ORCHESTRATE_MERGE_SENSITIVE ORCHESTRATE_GENERATED_FILES ORCHESTRATE_FAST_PATH_OVER ORCHESTRATE_ADMIN_MERGE
  seed_origin_copy
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  # Fixture switches in $FX:
  #   open-empty          `pr list --head --state open` answers [] (no open PR)
  #   merged-list-fails   `pr list --state merged` answers HTTP 502
  #   create-fails        `pr create` fails (and opens nothing)
  #   checks.json, checks-<n>.json  statusCheckRollup; the n-th readiness list uses checks-<n>.json
  #   labels.json         PR labels
  #   merge-mode          ok (default) | queued | 5xx | reject
  #   view-fails          `pr view` answers HTTP 502 this many more times
  #   files-fail, behind  merge-sensitive reads: PR files unreadable; commits behind the base
  #   reviews.json        bot reviews (review-gate.sh)
#   comment-fails       `pr comment` (a review request) answers HTTP 502
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
all="$*"
echo "$all" >>"$FX/calls"
head_of() { git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse -q --verify "refs/heads/$(cat "$FX/branch" 2>/dev/null)" || echo none; }
case "$all" in
  "api repos/o/r") echo '{"default_branch":"main"}' ;;
  *rules/branches*) echo '[]' ;;
  "api repos/o/r/branches/"*) echo '{"protected":false}' ;;
  *graphql*) echo '{"data":{"repository":{"p5":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}' ;;
  "api repos/o/r/actions/runs?"*) echo '{"workflow_runs":[]}' ;;
  "api --paginate repos/o/r/pulls/5/files"*) [ ! -f "$FX/files-fail" ] || { echo "HTTP 404" >&2; exit 1; }; printf 'f.txt\n' ;;
  "api repos/o/r/pulls/5/reviews"*) cat "$FX/reviews.json" ;;
  "api repos/o/r/issues/5/comments"*) echo '[]' ;;
  "api repos/o/r/commits/"*"/check-runs"*) echo '{"check_runs":[]}' ;;
  "api repos/o/r/pulls/5 "*) echo main ;;
  "api repos/o/r/compare/"*"...main "*) printf 'f.txt\n' ;; # the base's drift
  "api repos/o/r/compare/"*) cat "$FX/behind" 2>/dev/null || echo 1 ;;
  "pr list"*"--state merged"*) [ ! -f "$FX/merged-list-fails" ] || { echo "HTTP 502" >&2; exit 1; }; echo '[]' ;;
  "pr list"*--head*) b=$(echo "$all" | sed 's/.*--head \([^ ]*\).*/\1/'); echo "$b" >"$FX/branch"
    if [ -f "$FX/open-empty" ]; then echo '[]'; else jq -n --arg h "$(head_of)" '[{number: 5, headRefOid: $h}]'; fi ;;
  "pr list"*"--json number") echo '[{"number":5}]' ;;
  "pr list"*) echo x >>"$FX/ready-calls"; n=$(wc -l <"$FX/ready-calls" | tr -d ' ')
    c="$FX/checks.json"; [ ! -f "$FX/checks-$n.json" ] || c="$FX/checks-$n.json"
    jq -n --arg h "$(head_of)" --argjson c "$(cat "$c")" --argjson l "$(cat "$FX/labels.json")" \
      '[{number: 5, author: {login: "me"}, isDraft: false, isCrossRepository: false, baseRefName: "main",
         headRefOid: $h, mergeable: "MERGEABLE", labels: $l, statusCheckRollup: $c}]' ;;
  "pr comment"*) [ ! -f "$FX/comment-fails" ] || { echo "HTTP 502" >&2; exit 1; } ;;
  "pr create"*) [ ! -f "$FX/create-fails" ] || { echo "GraphQL: something went wrong" >&2; exit 1; } ;;
  "pr merge"*) case "$(cat "$FX/merge-mode" 2>/dev/null)" in
      queued) touch "$FX/auto"; echo "! Pull request will be automatically merged when all requirements are met" ;;
      5xx) echo "HTTP 502: Bad Gateway" >&2; exit 1 ;;
      reject) echo "Pull request is not mergeable: base branch policy prohibits the merge" >&2; exit 1 ;;
      *) echo MERGED >"$FX/merged" ;;
    esac ;;
  "pr view"*) if [ -s "$FX/view-fails" ] && [ "$(cat "$FX/view-fails")" -gt 0 ]; then
      echo $(($(cat "$FX/view-fails") - 1)) >"$FX/view-fails"; echo "HTTP 502" >&2; exit 1; fi
    if [ -f "$FX/merged" ]; then echo '{"state":"MERGED","mergeCommit":{"oid":"feedface"}}'
    else jq -n --arg h "$(head_of)" --arg auto "$([ -f "$FX/auto" ] && echo yes)" '{state: "OPEN", isDraft: false,
      isCrossRepository: false, headRefOid: $h, author: {login: "me"}, mergeable: "MERGEABLE",
      autoMergeRequest: (if $auto == "yes" then {enabledAt: "2026-09-27T12:00:00Z"} else null end)}'; fi ;;
  *) echo "unexpected gh call: $all" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  reset_fx
  echo body >"$BATS_TEST_TMPDIR/body.md"
  Q="$ORCHESTRATE_STATE_DIR/o__r/merge-queue"
}

reset_fx() {
  rm -rf "$FX"; mkdir -p "$FX"
  echo '[{"name":"build","conclusion":"SUCCESS","startedAt":"2026-09-27T01:00:00Z"}]' >"$FX/checks.json"
  echo '[]' >"$FX/labels.json"
  echo '[]' >"$FX/reviews.json"
}

# wt NAME [FILE CONTENT]: a clone on branch NAME with one commit editing FILE.
wt() {
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/$1" 2>/dev/null
  git -C "$BATS_TEST_TMPDIR/$1" switch -q -c "$1"
  echo "${3:-$1}" >"$BATS_TEST_TMPDIR/$1/${2:-$1.txt}"
  git -C "$BATS_TEST_TMPDIR/$1" add -A
  git -C "$BATS_TEST_TMPDIR/$1" commit -qm "$1"
}
mq() { "$SCRIPTS/merge-queue.sh" "$1" --repo o/r "${@:2}"; }
enqueue() { mq add --id "$1" --worktree "$BATS_TEST_TMPDIR/$1" --branch "$1" --title "t $1" --body-file "$BATS_TEST_TMPDIR/body.md" >/dev/null; }
outcome() { head -1 "$Q/$1.outcome"; }
reason() { sed -n 2p "$Q/$1.outcome"; }
main_moves() { # FILE CONTENT: a new commit on origin/main
  echo "$2" >"$BATS_TEST_TMPDIR/seed/$1"
  git -C "$BATS_TEST_TMPDIR/seed" add -A
  git -C "$BATS_TEST_TMPDIR/seed" commit -qm "main $1"
  git -C "$BATS_TEST_TMPDIR/seed" push -q origin HEAD:main
}
