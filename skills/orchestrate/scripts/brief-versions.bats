#!/usr/bin/env bats
# Brief version bumps (#199): a standard cloud brief whose body changed must carry a new version, and
# skills/orchestrate/briefs/versions.tsv records the body hash of each shipped version. A committed
# manifest, not a merge-base diff, so it works on CI's shallow checkout. Run: bats brief-versions.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  BRIEFS="$(cd "$SCRIPTS/../briefs" && pwd)"
  W="$BATS_TEST_TMPDIR/briefs"
  mkdir -p "$W"
  # A self-consistent copy for the checker's own tests: the briefs as they are, each recorded at its
  # version, so those tests hold while the real tree is mid-edit (the first test checks the real one).
  cp "$BRIEFS"/*.md "$W/"
  local k v
  for k in implement repair; do
    v=$(sed -n '1s/.*waaagh-brief [a-z]* v\([0-9]*\).*/\1/p' "$W/$k.md")
    printf '%s\t%s\t%s\n' "$k" "$v" "$(tail -n +2 "$W/$k.md" | git hash-object --stdin)" >>"$W/versions.tsv"
  done
}

# check_briefs DIR: every DIR/K.md with a "<!-- waaagh-brief K vV" first line must have the row
# K<TAB>V<TAB>hash-of-body in DIR/versions.tsv. Prints one line per problem; returns 1 on any.
check_briefs() {
  local dir=$1 f k v h want max bad=0
  for f in "$dir"/*.md; do
    k=$(awk 'NR == 1 && match($0, /waaagh-brief [a-z]+ v[0-9]+/) { s = substr($0, RSTART, RLENGTH); split(s, a, " "); print a[2] }' "$f")
    [[ -n "$k" ]] || continue
    [[ "$(basename "$f" .md)" == "$k" ]] || { echo "$f: first line names kind $k"; bad=1; continue; }
    v=$(awk 'NR == 1 { s = $0; sub(/.*waaagh-brief [a-z]+ v/, "", s); sub(/[^0-9].*/, "", s); print s }' "$f")
    h=$(tail -n +2 "$f" | git hash-object --stdin)
    want=$(awk -F'\t' -v k="$k" -v v="$v" '$1 == k && $2 == v { print $3 }' "$dir/versions.tsv")
    max=$(awk -F'\t' -v k="$k" '$1 == k && $2 + 0 > m { m = $2 + 0 } END { print m + 0 }' "$dir/versions.tsv")
    if [[ "$want" == "$h" ]]; then
      continue
    elif [[ -n "$want" ]]; then
      echo "brief $k v$v changed without a version bump: raise it to v$((max + 1)) and append \"$k	$((max + 1))	$h\" to versions.tsv"
    elif ((v <= max)); then
      echo "brief $k v$v is not above v$max, the highest in versions.tsv: raise it to v$((max + 1))"
    else
      echo "brief $k v$v is not in versions.tsv: append \"$k	$v	$h\""
    fi
    bad=1
  done
  return "$bad"
}
bump() { # bump K: raise K.md's version by one in $W
  local v
  v=$(awk 'NR == 1 { s = $0; sub(/.*waaagh-brief [a-z]+ v/, "", s); sub(/[^0-9].*/, "", s); print s }' "$W/$1.md")
  sed "1s/waaagh-brief $1 v$v/waaagh-brief $1 v$((v + 1))/" "$W/$1.md" >"$W/x"
  mv "$W/x" "$W/$1.md"
}

@test "the committed briefs match versions.tsv" {
  # Not under `run`, so a failure prints the fix (bump and the row to append) in the test output.
  check_briefs "$BRIEFS"
  [ "$(grep -c '^implement	' "$BRIEFS/versions.tsv")" -ge 1 ]
  [ "$(grep -c '^repair	' "$BRIEFS/versions.tsv")" -ge 1 ]
}

@test "editing a brief without a bump fails and names the row to append" {
  echo "One more rule." >>"$W/repair.md"
  run check_briefs "$W"
  [ "$status" -eq 1 ]
  [[ "$output" == "brief repair v"*" changed without a version bump: raise it to v"* ]]
  [ "${#lines[@]}" -eq 1 ]
  # A whitespace-only change counts.
  cp "$BRIEFS/repair.md" "$W/repair.md"
  printf '\n' >>"$W/implement.md"
  run check_briefs "$W"
  [ "$status" -eq 1 ]
  [[ "$output" == "brief implement v"*" changed without a version bump"* ]]
}

@test "bumping and appending the printed row passes, with no test edit" {
  echo "One more rule." >>"$W/repair.md"
  bump repair
  run check_briefs "$W"
  [ "$status" -eq 1 ]
  [[ "$output" == "brief repair v"*" is not in versions.tsv: append \""* ]]
  row=${output#*append \"}
  printf '%s\n' "${row%\"*}" >>"$W/versions.tsv"
  run check_briefs "$W"
  [ "$status" -eq 0 ]
  # The edit-without-bump message's row works the same way after the bump it asks for.
  echo "And another." >>"$W/repair.md"
  run check_briefs "$W"
  [ "$status" -eq 1 ]
  row=${output#*append \"}
  bump repair
  printf '%s\n' "${row%\"*}" >>"$W/versions.tsv"
  run check_briefs "$W"
  [ "$status" -eq 0 ]
}

@test "an old version string is never reused, and the kind must match the file" {
  v=$(awk -F'\t' '$1 == "implement" { m = $2 } END { print m }' "$W/versions.tsv")
  printf 'implement\t%s\tdeadbeef\n' "$((v + 1))" >>"$W/versions.tsv"
  printf 'implement\t%s\tcafe\n' "$((v + 2))" >>"$W/versions.tsv"
  bump implement
  echo "x" >>"$W/implement.md"
  run check_briefs "$W"
  [ "$status" -eq 1 ]
  [[ "$output" == "brief implement v$((v + 1)) changed without a version bump: raise it to v$((v + 3))"* ]]
  # Going back down to an unrecorded number below the highest is refused too.
  awk -F'\t' -v v="$((v + 1))" '!($1 == "implement" && $2 == v)' "$W/versions.tsv" >"$W/m"
  mv "$W/m" "$W/versions.tsv"
  run check_briefs "$W"
  [ "$status" -eq 1 ]
  [ "$output" = "brief implement v$((v + 1)) is not above v$((v + 2)), the highest in versions.tsv: raise it to v$((v + 3))" ]
  sed '1s/waaagh-brief repair/waaagh-brief implement/' "$BRIEFS/repair.md" >"$W/repair.md"
  run check_briefs "$W"
  [[ "$output" == *"repair.md: first line names kind implement"* ]]
}

@test "the bump rule is documented next to the briefs" {
  R="$BRIEFS/README.md"
  grep -qF "## The bump rule" "$R"
  grep -qF "versions.tsv" "$R"
  grep -qF "tail -n +2 K.md | git hash-object --stdin" "$R"
  grep -qF "brief-versions.bats" "$R"
  grep -qF "briefs/README.md" "$SCRIPTS/../roles/cloud-dispatch.md"
}
