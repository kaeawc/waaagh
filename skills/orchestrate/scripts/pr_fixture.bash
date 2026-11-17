# The one PR-row fixture (#304): what `gh pr list --json ...` and the REST list give pr-ready.sh and
# friends. Sourced by selftest_helper.bash, bench.sh and the suites that need a row of their own shape.
# The head is a 40-character sha ending in the PR number, so head_of-style checks see a real one.

PR_FIXTURE_JQ='def pr_row($n; $a; $d; $f; $m; $c; $l; $x):
  {number:$n, author:{login:$a}, isDraft:$d, state:"OPEN", isCrossRepository:$f, baseRefName:"main",
   headRefOid:("abcdef0123456789abcdef0123456789abcdef01"[0:(40-($n|tostring|length))]+($n|tostring)),
   mergeable:$m, labels:$l, statusCheckRollup:$c} + $x;'

# pr_fixture_row number author draft fork mergeable checks-json [labels-json] [extra-json merged over the row]
pr_fixture_row() {
  local none='{}'
  jq -cn --argjson n "$1" --arg a "$2" --argjson d "$3" --argjson f "$4" --arg m "$5" --argjson c "$6" \
    --argjson l "${7:-[]}" --argjson x "${8:-$none}" "$PR_FIXTURE_JQ"' pr_row($n; $a; $d; $f; $m; $c; $l; $x)'
}

# pr_fixture_rows from to author draft fork mergeable checks-json: pr_fixture_row for each number
# from..to (counting down when from > to), from one jq instead of one per row.
pr_fixture_rows() {
  jq -cn --argjson a "$1" --argjson b "$2" --arg au "$3" --argjson d "$4" --argjson f "$5" --arg m "$6" --argjson c "$7" \
    "$PR_FIXTURE_JQ"'(if $a <= $b then range($a; $b + 1) else range($a; $b - 1; -1) end)
     | pr_row(.; $au; $d; $f; $m; $c; []; {})'
}
