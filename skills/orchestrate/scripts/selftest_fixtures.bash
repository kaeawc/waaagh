# The data fixtures of the selftest-*.bats suites: PR rows, check rows, workflow-run rows and issue
# lists. No gh stub and no name a stub defines lives here, so a suite can load this file alone
# (selftest_helper.bash loads it with selftest_stubs.bash, #310). ready_prs, sim_fails and
# dupes_fixture write into $FX, which the caller sets (stub_gh_router does).

# shellcheck source=pr_fixture.bash
source "${BASH_SOURCE[0]%/*}/pr_fixture.bash"
pr_row() { pr_fixture_row "$@"; } # number author draft fork mergeable checks-json [labels-json]

OKC='[{"name":"build","conclusion":"SUCCESS","startedAt":"2026-09-27T01:00:00Z"}]'

check() { # name conclusion workflow startedAt [run] [job] [typename]
  jq -cn --arg n "$1" --arg c "$2" --arg w "$3" --arg t "$4" --arg r "${5:-}" --arg j "${6:-}" --arg ty "${7:-CheckRun}" \
    '{__typename: $ty, name: $n, conclusion: $c, workflowName: $w, startedAt: $t}
     + (if $r == "" then {} else {detailsUrl: ("https://github.com/o/r/actions/runs/\($r)" + (if $j == "" then "" else "/job/\($j)" end))} end)'
}

pr_rows() { pr_fixture_rows "$@"; } # from to author draft fork mergeable checks-json: pr_row for each number from..to

ready_prs() { # n: n mergeable, green PRs by me
  if (($1 > 0)); then pr_rows 1 "$1" me false false MERGEABLE "$OKC"; fi | jq -s . >"$FX/prs.json"
}
# The readiness row for the admin tests: build passes, "sim" failed (a classified flake).
sim_fails() { pr_row 1 me false false MERGEABLE '[{"name":"build","conclusion":"SUCCESS"},{"name":"sim","conclusion":"FAILURE"}]' | jq -s . >"$FX/prs.json"; }
run_json() { # workflow status conclusion sha id createdAt
  jq -cn --arg w "$1" --arg s "$2" --arg c "$3" --arg h "$4" --argjson id "$5" --arg t "$6" \
    '{workflowName:$w,status:$s,conclusion:$c,headSha:$h,databaseId:$id,createdAt:$t}'
}
# n issues titled the same, numbered 1..n, plus optional extra JSON rows.
dupes_fixture() {
  jq -n --argjson n "$1" --argjson extra "${2:-[]}" \
    '[range(1; $n + 1) | {number: ., title: "Fix shared device session recovery failure"}] + $extra' >"$FX/issues.json"
}

DIVERSE='[{"number":901,"title":"Crash when the keyboard opens on tablet"},
          {"number":902,"title":"Crash when keyboard opens on tablets"},
          {"number":903,"title":"Login screen shows stale avatar image"},
          {"number":904,"title":"Login screen shows a stale avatar"}]'
