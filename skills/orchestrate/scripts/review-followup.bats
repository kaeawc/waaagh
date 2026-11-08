#!/usr/bin/env bats
# review-followup.sh and thread-resolve.sh against a stubbed gh, plus the later-round doctrine
# contract. Run: bats review-followup.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
  FX="$BATS_TEST_TMPDIR/fx"; mkdir -p "$FX" "$BATS_TEST_TMPDIR/bin"
  export FX PATH="$BATS_TEST_TMPDIR/bin:$PATH" ORCHESTRATE_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export ORCHESTRATE_NOW=1793880000   # 2026-11-05T10:40:00Z
  # One review thread lives in $FX: its PR ($FX/thread-pr), resolved flag ($FX/resolved) and
  # replies ($FX/replies.json). One issue: state ($FX/istate), labels ($FX/labels, one per line)
  # and comments ($FX/icomments.json). Every write is logged to $FX/writes.
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FX/calls"
arg() { local k=$1; shift; while [ $# -gt 0 ]; do case "$1" in "$k="*) printf '%s' "${1#"$k="}"; return ;; esac; shift; done; }
thread_view() {
  jq -n --arg pr "$(cat "$FX/thread-pr")" --argjson r "$([ -f "$FX/resolved" ] && echo true || echo false)" \
    --slurpfile rep "$FX/replies.json" '{data: {node: {__typename: "PullRequestReviewThread", isResolved: $r,
      path: "src/a.sh", line: 12, originalLine: 12, pullRequest: {number: ($pr | tonumber), title: "Add a"},
      comments: {nodes: ([{author: {login: "codex-bot"}, url: "https://github.com/o/r/pull/7#discussion_r1",
        body: "P2: the loop drops the last page\nsecond line"}] + [$rep[0][] | {body: .}])}}}}'
}
issue_view() {
  jq -n --arg s "$(cat "$FX/istate")" --rawfile l "$FX/labels" --slurpfile c "$FX/icomments.json" \
    '{state: $s, labels: [$l | split("\n")[] | select(. != "") | {name: .}], comments: [$c[0][] | {body: .}]}'
}
case "$1 $2" in
  "api graphql")
    q=$(arg query "$@")
    case "$q" in
      *addPullRequestReviewThreadReply*)
        echo "reply" >>"$FX/writes"
        jq --arg b "$(arg b "$@")" '. + [$b]' "$FX/replies.json" >"$FX/r.tmp" && mv "$FX/r.tmp" "$FX/replies.json"
        echo '{"data":{}}' ;;
      *resolveReviewThread*) echo "resolve" >>"$FX/writes"; touch "$FX/resolved"; echo '{"data":{}}' ;;
      *reviewThreads*)
        [ "${THREADS_FAIL:-0}" = 1 ] && { echo "HTTP 404: Not Found" >&2; exit 1; }
        if [ -n "$(arg cursor "$@")" ]; then cat "$FX/threads2.json"; else cat "$FX/threads.json"; fi ;;
      *node*)
        if [ "$(arg id "$@")" = NOTATHREAD ]; then echo '{"data":{"node":{"__typename":"Issue"}}}'; else thread_view; fi ;;
      *) echo "unexpected query" >&2; exit 9 ;;
    esac ;;
  "issue create")
    echo "create" >>"$FX/writes"
    shift 2; while [ $# -gt 0 ]; do [ "$1" = --body ] && printf '%s' "$2" >"$FX/created-body"; shift; done
    echo "https://github.com/o/r/issues/101" ;;
  "issue list") cat "$FX/recent.json" ;;
  "issue view") issue_view ;;
  "issue comment")
    echo "comment" >>"$FX/writes"
    shift 2; while [ $# -gt 0 ]; do
      [ "$1" = --body ] && { jq --arg b "$2" '. + [$b]' "$FX/icomments.json" >"$FX/c.tmp" && mv "$FX/c.tmp" "$FX/icomments.json"; }
      shift; done ;;
  "issue edit")
    echo "edit" >>"$FX/writes"
    shift 2; while [ $# -gt 0 ]; do
      case "$1" in
        --add-label) echo "$2" >>"$FX/labels"; shift 2 ;;
        --remove-label) grep -vxF "$2" "$FX/labels" >"$FX/l.tmp" || true; mv "$FX/l.tmp" "$FX/labels"; shift 2 ;;
        *) shift ;;
      esac
    done ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  echo 7 >"$FX/thread-pr"; echo '[]' >"$FX/replies.json"; echo OPEN >"$FX/istate"
  : >"$FX/labels"; echo '[]' >"$FX/icomments.json"; echo '[]' >"$FX/recent.json"; : >"$FX/calls"; : >"$FX/writes"
}
rf() { "$SCRIPTS/review-followup.sh" "$@" --repo o/r; }
tr_() { "$SCRIPTS/thread-resolve.sh" "$@" --repo o/r; }
rfe() { rf "$@" 2>"$FX/err"; }   # stdout only; stderr kept in $FX/err

# threads.json: PR by "me", first reviewed at 10:00; threads from that round, a later review,
# the author, plus resolved and outdated ones that must not be listed.
write_threads() {
  cat >"$FX/threads.json" <<'JSON'
{"data":{"repository":{"pullRequest":{"author":{"login":"me"},
 "reviews":{"nodes":[{"author":{"login":"me"},"state":"COMMENTED","submittedAt":"2026-11-04T09:00:00Z"},
                     {"author":{"login":"codex-bot"},"state":"COMMENTED","submittedAt":"2026-11-04T10:00:00Z"},
                     {"author":{"login":"codex-bot"},"state":"COMMENTED","submittedAt":"2026-11-04T15:00:00Z"}]},
 "reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRRT_first","isResolved":false,"isOutdated":false,"path":"a.sh","line":3,"originalLine":3,
   "comments":{"nodes":[{"author":{"login":"codex-bot"},"createdAt":"2026-11-04T09:59:58Z","url":"u1","body":"**<sub><sub>![P1 Badge](https://img)</sub></sub>  Off by one**\n\ndetail"}]}},
  {"id":"PRRT_later","isResolved":false,"isOutdated":false,"path":"b.sh","line":null,"originalLine":9,
   "comments":{"nodes":[{"author":{"login":"codex-bot"},"createdAt":"2026-11-04T15:00:00Z","url":"u2","body":"P2: page dropped"}]}},
  {"id":"PRRT_own","isResolved":false,"isOutdated":false,"path":"c.sh","line":1,"originalLine":1,
   "comments":{"nodes":[{"author":{"login":"me"},"createdAt":"2026-11-04T16:00:00Z","url":"u3","body":"note to self"}]}},
  {"id":"PRRT_done","isResolved":true,"isOutdated":false,"path":"d.sh","line":1,"originalLine":1,
   "comments":{"nodes":[{"author":{"login":"codex-bot"},"createdAt":"2026-11-04T15:00:00Z","url":"u4","body":"x"}]}},
  {"id":"PRRT_old","isResolved":false,"isOutdated":true,"path":"e.sh","line":null,"originalLine":1,
   "comments":{"nodes":[{"author":{"login":"codex-bot"},"createdAt":"2026-11-04T15:00:00Z","url":"u5","body":"y"}]}}]}}}}}
JSON
}

@test "list: classifies first-round, later-round and own threads; skips resolved and outdated" {
  write_threads
  run rfe list --pr 7
  [ "$status" -eq 0 ]
  stderr=$(cat "$FX/err")
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "$(printf 'first\tPRRT_first\ta.sh:3\tcodex-bot\tu1\tOff by one')" ]
  [ "${lines[1]}" = "$(printf 'later\tPRRT_later\tb.sh:9\tcodex-bot\tu2\tP2: page dropped')" ]
  [[ "${lines[2]}" == own$'\t'PRRT_own* ]]
  [ "$stderr" = "pr=7 unresolved=3 first=1 later=1 own=1 round-end=2026-11-04T10:00:00Z" ]
}

@test "list: --round-end moves the round boundary" {
  write_threads
  run rfe list --pr 7 --round-end 2026-11-04T15:30:00Z
  [ "$status" -eq 0 ]
  [[ "${lines[1]}" == first$'\t'PRRT_later* ]]
  stderr=$(cat "$FX/err")
  [[ "$stderr" == *"first=2 later=0 own=1 round-end=2026-11-04T15:30:00Z" ]]
}

@test "list: follows further pages of review threads" {
  write_threads
  jq '.data.repository.pullRequest.reviewThreads.pageInfo = {hasNextPage: true, endCursor: "C1"}' "$FX/threads.json" >"$FX/t.tmp"
  mv "$FX/t.tmp" "$FX/threads.json"
  jq '.data.repository.pullRequest.reviewThreads = {pageInfo: {hasNextPage: false, endCursor: null},
      nodes: [.data.repository.pullRequest.reviewThreads.nodes[1] | .id = "PRRT_page2"]}' "$FX/threads.json" >"$FX/threads2.json"
  run rfe list --pr 7
  [ "$status" -eq 0 ]
  [[ "$output" == *$'later\tPRRT_page2'* ]]
  stderr=$(cat "$FX/err")
  [[ "$stderr" == *"unresolved=4 first=1 later=2 own=1"* ]]
}

@test "list: unreadable threads exit 4 with no rows" {
  THREADS_FAIL=1 run rfe list --pr 7
  [ "$status" -eq 4 ]
  [ -z "$output" ]
}

@test "thread-resolve: replies once, resolves, and a rerun changes nothing" {
  run tr_ --thread PRRT_x --pr 7 --reply "follow-up #5"
  [ "$status" -eq 0 ]
  [ "$output" = "resolved PRRT_x pr=7" ]
  [ "$(cat "$FX/writes")" = $'reply\nresolve' ]
  [[ "$(jq -r '.[0]' "$FX/replies.json")" == "follow-up #5"*"<!-- waaagh:reply thread=PRRT_x key="* ]]
  run tr_ --thread PRRT_x --pr 7 --reply "follow-up #5"
  [ "$status" -eq 0 ]
  [ "$output" = "unchanged PRRT_x pr=7" ]
  [ "$(wc -l <"$FX/writes" | tr -d ' ')" -eq 2 ]
  grep -q $'resolve\tpr=7\tthread=PRRT_x\treply=follow-up #5' "$ORCHESTRATE_STATE_DIR"/o__r/thread-actions.log
}

@test "thread-resolve: a resolved thread without the reply gets only the reply" {
  touch "$FX/resolved"
  run tr_ --thread PRRT_x --reply "fixed in abc123"
  [ "$status" -eq 0 ]
  [ "$(cat "$FX/writes")" = reply ]
}

@test "thread-resolve: without --reply it only resolves" {
  run tr_ --thread PRRT_x
  [ "$status" -eq 0 ]
  [ "$(cat "$FX/writes")" = resolve ]
}

@test "thread-resolve: refuses a thread on another PR or a non-thread node, and dry-run writes nothing" {
  run tr_ --thread PRRT_x --pr 8 --reply hi
  [ "$status" -eq 3 ]
  [[ "$output" == *"is on PR #7, not #8"* ]]
  run tr_ --thread NOTATHREAD
  [ "$status" -eq 3 ]
  run tr_ --thread PRRT_x --reply hi --dry-run
  [ "$status" -eq 0 ]
  [ "$output" = "would resolve PRRT_x pr=7 reply" ]
  [ ! -s "$FX/writes" ]
  run tr_ --thread 'bad id'
  [ "$status" -eq 2 ]
}

@test "file --title: files a quoted issue, replies follow-up #N, resolves, routes cloud-ready; rerun files nothing" {
  run rf file --pr 7 --thread PRRT_later --title "Last page dropped" --note "Root cause: cursor off by one"
  [ "$status" -eq 0 ]
  [[ "$output" == *"filed #101 pr=7 thread=PRRT_later"* ]]
  [[ "$output" == *"resolved PRRT_later pr=7"* ]]
  [[ "$output" == *"followup pr=7 thread=PRRT_later issue=#101 route=cloud-ready" ]]
  body=$(cat "$FX/created-body")
  [[ "$body" == "Follow-up from a later-round review thread on #7 (Add a)."* ]]
  [[ "$body" == *"- Thread: https://github.com/o/r/pull/7#discussion_r1"* ]]
  [[ "$body" == *'- File: `src/a.sh:12`'* ]]
  [[ "$body" == *$'> P2: the loop drops the last page\n> second line'* ]]
  [[ "$body" == *"Root cause: cursor off by one"* ]]
  [[ "$body" == *"<!-- waaagh:followup pr=7 thread=PRRT_later -->" ]]
  [[ "$(jq -r '.[0]' "$FX/replies.json")" == "follow-up #101"* ]]
  [ -f "$FX/resolved" ]
  [ "$(cat "$FX/labels")" = cloud-ready ]
  [ "$(jq -r .state "$ORCHESTRATE_STATE_DIR"/o__r/ops/followup-PRRT_later.json)" = done ]
  run rf file --pr 7 --thread PRRT_later --title "Last page dropped"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already-filed #101"* ]]
  [ "$(grep -c create "$FX/writes")" -eq 1 ]
  [ "$(grep -c reply "$FX/writes")" -eq 1 ]
}

@test "file --title: without a journal the marker on a recent issue prevents a second filing" {
  echo '[{"number":55,"body":"x <!-- waaagh:followup pr=7 thread=PRRT_later -->"}]' >"$FX/recent.json"
  run rf file --pr 7 --thread PRRT_later --title "Last page dropped"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already-filed #55"* ]]
  run ! grep -q create "$FX/writes"
  [[ "$(jq -r '.[0]' "$FX/replies.json")" == "follow-up #55"* ]]
}

@test "file --append: adds the finding to an open issue once and keeps its route" {
  echo "needs-local:research" >"$FX/labels"
  run rf file --pr 7 --thread PRRT_later --append 40
  [ "$status" -eq 0 ]
  [[ "$output" == *"appended #40"* ]]
  [[ "$output" == *"route=needs-local:research (kept)" ]]
  [[ "$(jq -r '.[0]' "$FX/icomments.json")" == "Same root cause, from a later-round review thread on #7 (Add a)."*"<!-- waaagh:followup pr=7 thread=PRRT_later -->" ]]
  [[ "$(jq -r '.[0]' "$FX/replies.json")" == "follow-up #40"* ]]
  run ! grep -q edit "$FX/writes"
  run rf file --pr 7 --thread PRRT_later --append 40
  [ "$status" -eq 0 ]
  [[ "$output" == *"already-appended #40"* ]]
  [ "$(grep -c comment "$FX/writes")" -eq 1 ]
}

@test "file --append: an unrouted issue is routed cloud-ready" {
  run rf file --pr 7 --thread PRRT_later --append 40
  [ "$status" -eq 0 ]
  [ "$(cat "$FX/labels")" = cloud-ready ]
}

@test "file: refuses a closed --append issue, a thread on another PR, and bad arguments" {
  echo CLOSED >"$FX/istate"
  run rf file --pr 7 --thread PRRT_later --append 40
  [ "$status" -eq 3 ]
  run rf file --pr 9 --thread PRRT_later --title t
  [ "$status" -eq 3 ]
  run rf file --pr 7 --thread PRRT_later --title t --append 4
  [ "$status" -eq 2 ]
  run rf file --pr 7 --thread PRRT_later --title t --route needs-local:x
  [ "$status" -eq 2 ]
  [ ! -s "$FX/writes" ]
}

@test "file --dry-run writes nothing" {
  run rf file --pr 7 --thread PRRT_later --title t --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *'would file "t" for thread PRRT_later'* ]]
  [ ! -s "$FX/writes" ]
}

@test "-h prints exactly the header of both scripts" {
  for s in review-followup.sh thread-resolve.sh; do
    run "$SCRIPTS/$s" -h
    [ "$status" -eq 0 ]
    [[ "${lines[${#lines[@]}-1]}" != *"set -euo"* ]]
    [[ "$output" == *"Exit: 0 ok"* ]]
    [ "$(awk 'NR > 1 && /^#/ { n++ } NR > 1 && !/^#/ { exit } END { print n }' "$SCRIPTS/$s")" -eq "${#lines[@]}" ]
  done
}

@test "doctrine: the PR doctor settles later-round threads with review-followup.sh; scripts are listed" {
  grep -q 'review-followup.sh list' "$SCRIPTS/../roles/pr-doctor.md"
  grep -q 'review-followup.sh file' "$SCRIPTS/../roles/pr-doctor.md"
  grep -q 'review-followup.sh' "$SCRIPTS/../SKILL.md"
  grep -q '`review-followup.sh`' "$ROOT/README.md"
  grep -q '`thread-resolve.sh`' "$ROOT/README.md"
}
