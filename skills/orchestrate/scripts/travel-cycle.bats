#!/usr/bin/env bats
# travel-cycle.sh (traveling-mode.md, "Hourly cycle"): one orchestrator pass. The store is real git
# (a local bare repository); the sibling scripts the pass composes are stubs in
# ORCHESTRATE_SCRIPTS_DIR (orch_run), answering from fixture files; gh (the writes) is a stub that
# logs. Run: bats travel-cycle.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  T=$BATS_TEST_TMPDIR FX="$T/fx" S="$T/stubs"
  mkdir -p "$FX" "$S" "$T/bin"
  git init -q --bare -b main "$T/store.git"
  git clone -q "$T/store.git" "$T/store" 2>/dev/null
  git -C "$T/store" commit -q --allow-empty -m init && git -C "$T/store" push -q origin HEAD:main
  "$SCRIPTS/travel-store.sh" set-mode traveling --store "$T/store" --repo o/r >/dev/null
  export FX ORCHESTRATE_SCRIPTS_DIR="$S" PATH="$T/bin:$PATH" ORCHESTRATE_NOW=1795200000
  H40=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa B40=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb C40=cccccccccccccccccccccccccccccccccccccccc
  stub() { printf '#!/usr/bin/env bash\necho "%s $*" >>"$FX/calls"\n%s\n' "$1" "$2" >"$S/$1"; chmod +x "$S/$1"; }
  stub main-health.sh 'exit "$(cat "$FX/main-rc" 2>/dev/null || echo 0)"'
  stub pr-ready.sh 'cat "$FX/rows" 2>/dev/null || true'
  stub hold.sh 'cat "$FX/held" 2>/dev/null || true'
  stub open-blockers.sh 'n=${@: -1}; [ ! -f "$FX/blocked-$n" ] || { echo "$n BLOCKED by #1"; exit 3; }; echo "$n clear"'
  stub app-broker.sh 'echo dispatched'
  # review-ledger: latest from $FX/ledger-<pr> (a ledger row), inflight from $FX/inflight-<pr>.
  stub review-ledger.sh 'op=$1; shift; pr=""; while (($#)); do [ "$1" = --pr ] && pr=$2; shift; done
case "$op" in latest) cat "$FX/ledger-$pr" 2>/dev/null || exit 3 ;; inflight) cat "$FX/inflight-$pr" 2>/dev/null || true ;; *) ;; esac'
  stub gh-issues.sh 'case "$1" in prs-open) cat "$FX/prs.json" ;; issues) cat "$FX/issues.json" 2>/dev/null || echo "[]" ;; esac'
  # gh-read: statuses at a head from $FX/statuses-<sha>.json, a PR from $FX/pull-<n>.json.
  stub gh-read.sh 'r=${@: -1}; case "$r" in *"/statuses"*) s=${r#*commits/}; s=${s%%/*}; cat "$FX/statuses-$s.json" 2>/dev/null || echo "[]" ;;
  *"/pulls/"*) cat "$FX/pull-${r##*/}.json" 2>/dev/null || echo "{}" ;; *) echo "[]" ;; esac'
  printf '#!/usr/bin/env bash\necho "gh $*" >>"$FX/calls"\n' >"$T/bin/gh"; chmod +x "$T/bin/gh"
  echo '[]' >"$FX/prs.json"
}
cyc() { "$SCRIPTS/travel-cycle.sh" run --repo o/r --store "$T/store" --holder cloud-run:1 "$@"; }
app_status() { # SHA STATE [CREATOR]
  jq -n --arg s "$2" --arg c "${3:-waaagh-bot[bot]}" '[{context: "orchestrate/review", state: $s, creator: {login: $c}, updated_at: "2026-11-21T01:00:00Z"}]' >"$FX/statuses-$1.json"
}
pr() { # N [LABEL] [BRANCH] [BODY]
  jq -c --argjson n "$1" --arg l "${2:-}" --arg b "${3:-work/$1-x}" --arg body "${4:-}" \
    '. + [{number: $n, headRefName: $b, labels: (if $l == "" then [] else [{name: $l}] end), updatedAt: "2026-11-21T00:00:00Z", body: $body, closingIssuesReferences: [], isDraft: false}]' \
    "$FX/prs.json" >"$FX/p" && mv "$FX/p" "$FX/prs.json"
}
calls() { [ -f "$FX/calls" ] || { echo 0; return; }; grep -cF -- "$1" "$FX/calls" || true; }

@test "a local mode or a held lease skips the pass without acting" {
  "$SCRIPTS/travel-store.sh" set-mode local --store "$T/store" --repo o/r >/dev/null
  run cyc
  [ "$status" -eq 0 ]
  [ "$output" = "pass merged=0 reviews=0 repairs=0 dispatched=0 main=unknown skipped=mode-local" ]
  "$SCRIPTS/travel-store.sh" set-mode traveling --store "$T/store" --repo o/r >/dev/null
  "$SCRIPTS/travel-store.sh" lease take --holder host --store "$T/store" --repo o/r >/dev/null
  run cyc
  [ "$output" = "pass merged=0 reviews=0 repairs=0 dispatched=0 main=unknown skipped=lease-held" ]
  [ "$(calls main-health)" -eq 0 ]
}

@test "merge: only READY, App success at the head, ledger ship, no repair, not held; then the lease is released" {
  printf '5\tREADY\t%s\tMERGEABLE\t3\t-\n6\tREADY\t%s\tMERGEABLE\t3\t-\n7\tREADY\t%s\tMERGEABLE\t3\t-\n' "$H40" "$B40" "$C40" >"$FX/rows"
  app_status "$H40" success; app_status "$B40" success "someone"; app_status "$C40" success
  printf 'x\t5\tship\t%s\t-\n' "$H40" >"$FX/ledger-5"
  printf 'x\t7\tship\t%s\t-\n' "$C40" >"$FX/ledger-7"; echo 7 >"$FX/held"
  pr 5; pr 6; pr 7
  run cyc
  [ "$status" -eq 0 ]
  [[ "$output" == *"merge requested #5"* ]]
  [[ "$output" == *"pass merged=1 "*"main=green" ]]
  grep -qx "app-broker.sh merge --repo o/r --pr 5 --sha $H40" "$FX/calls"
  [ "$(calls 'app-broker.sh merge --repo o/r --pr 6')" -eq 0 ]   # status from someone else: no verdict
  [ "$(calls 'app-broker.sh merge --repo o/r --pr 7')" -eq 0 ]   # held
  # PR 6 has no App verdict at its head: it gets a review label instead.
  grep -qxF 'gh api -X POST repos/o/r/issues/6/labels -f labels[]=cloud-review' "$FX/calls"
  git -C "$T/store" pull -q --ff-only
  [[ "$(cat "$T/store/o__r/LEASE")" == "holder=none"* ]]
  grep -q $'\tmerge-request\tpr=5 ' "$T/store/o__r/journal.tsv"
  # A red main merges nothing, and the next pass confirms the earlier request once GitHub shows it merged.
  echo 1 >"$FX/main-rc"; : >"$FX/calls"; echo '{"merged": true, "state": "closed"}' >"$FX/pull-5.json"
  run cyc
  [[ "$output" == *"merged #5 (confirmed)"* && "$output" == *"main=red" ]]
  [ "$(calls 'app-broker.sh merge')" -eq 0 ]
}

@test "review, repair and dispatch labels respect their caps, the busy target and blockers" {
  printf '10\tREADY\t%s\tMERGEABLE\t3\t-\n11\tBLOCK\t%s\tMERGEABLE\t2\tfail:lint\n12\tBLOCK\t%s\tCONFLICTING\t3\t-\n13\tBLOCK\t%s\tMERGEABLE\t3\tthreads=1\n' "$H40" "$B40" "$C40" "$C40" >"$FX/rows"
  pr 10; pr 11; pr 12; pr 13
  jq -n '[{number: 20, labels: [{name: "cloud-ready"}]}, {number: 21, labels: [{name: "cloud-ready"}]},
          {number: 22, labels: [{name: "cloud-ready"}, {name: "cloud-dispatched"}]}, {number: 23, labels: []}]' >"$FX/issues.json"
  touch "$FX/blocked-21"
  run cyc --busy 4
  [ "$status" -eq 0 ]
  grep -qxF 'gh api -X POST repos/o/r/issues/10/labels -f labels[]=cloud-review' "$FX/calls"
  grep -qxF 'gh api -X POST repos/o/r/issues/11/labels -f labels[]=cloud-repair' "$FX/calls"
  grep -qxF 'gh api -X POST repos/o/r/issues/12/labels -f labels[]=cloud-repair' "$FX/calls"
  [ "$(calls 'issues/13/labels')" -eq 0 ]          # blocked only on threads: waits for the host
  grep -qxF 'gh api -X POST repos/o/r/issues/20/labels -f labels[]=cloud-dispatch' "$FX/calls"
  [ "$(calls 'issues/21/labels')" -eq 0 ]          # open blocker
  [ "$(calls 'issues/22/labels')" -eq 0 ]          # already dispatched
  [ "$(calls 'issues/23/labels')" -eq 0 ]          # not cloud-ready
  [[ "$output" == *"pass merged=0 reviews=1 repairs=2 dispatched=1 main=green" ]]
  grep -q 'review-ledger.sh repair --repo o/r --pr 11 --session label:cloud-repair' "$FX/calls"
  # Busy: 1 review + 2 repairs + 1 dispatched issue already live = 4 >= --busy 4: no more dispatch.
  : >"$FX/calls"
  pr 30 cloud-review; pr 31 cloud-repair; pr 32 cloud-repair
  jq '. + [{number: 24, labels: [{name: "cloud-ready"}]}]' "$FX/issues.json" >"$FX/i" && mv "$FX/i" "$FX/issues.json"
  jq '(.[] | select(.number == 20) | .labels) += [{name: "cloud-dispatch"}]' "$FX/issues.json" >"$FX/i" && mv "$FX/i" "$FX/issues.json"
  run cyc --busy 4
  [ "$(calls 'issues/24/labels')" -eq 0 ]
  # A repair added within the hour is not added again.
  [ "$(calls 'issues/11/labels -f labels[]=cloud-repair')" -eq 0 ]
}

@test "stale worker labels are removed; attribution lines are stripped from worker PRs" {
  pr 40 cloud-review work/40-auto $'Fixes #3\n\nCo-Authored-By: Someone <x@y>\n🤖 Generated with [Claude Code](https://claude.ai/code)'
  jq '(.[] | select(.number == 40) | .updatedAt) = "2026-11-20T00:00:00Z"' "$FX/prs.json" >"$FX/p" && mv "$FX/p" "$FX/prs.json"
  run cyc
  [[ "$output" == *"stale cloud-review on #40"* ]]
  grep -qxF 'gh api -X DELETE repos/o/r/issues/40/labels/cloud-review' "$FX/calls"
  grep -q 'gh api -X PATCH repos/o/r/pulls/40 -f body=Fixes #3' "$FX/calls"
  [ "$(calls 'Co-Authored-By')" -eq 0 ]
}

@test "--dry-run takes no lease and writes nothing; it says what it would do" {
  printf '5\tREADY\t%s\tMERGEABLE\t3\t-\n6\tREADY\t%s\tMERGEABLE\t3\t-\n' "$H40" "$B40" >"$FX/rows"
  app_status "$H40" success; printf 'x\t5\tship\t%s\t-\n' "$H40" >"$FX/ledger-5"; pr 5; pr 6
  run cyc --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would app-broker.sh merge --pr 5 --sha $H40"* ]]
  [[ "$output" == *"would gh api -X POST repos/o/r/issues/6/labels -f labels[]=cloud-review"* ]]
  [ "$(calls 'app-broker.sh merge')" -eq 0 ]
  [ "$(grep -c '^gh ' "$FX/calls" 2>/dev/null || true)" = 0 ] || [ ! -f "$FX/calls" ]
  git -C "$T/store" pull -q --ff-only
  [ ! -f "$T/store/o__r/LEASE" ]
  [ "$(grep -c . "$T/store/o__r/journal.tsv")" -eq 1 ]   # only set-mode's row
}

@test "usage" {
  run "$SCRIPTS/travel-cycle.sh" run --repo o/r --store "$T/store"
  [ "$status" -eq 2 ]
  run cyc --merge-cap x
  [ "$status" -eq 2 ]
  run "$SCRIPTS/travel-cycle.sh" go
  [ "$status" -eq 2 ]
}
