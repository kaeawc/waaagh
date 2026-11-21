#!/usr/bin/env bats
# travel.sh (traveling-mode.md, "Toggle on the host"): enter hands a campaign to the cloud, exit
# takes it back, status reports. Real git store (a local bare repository); gh, device-lock.sh and
# travel-guard.sh are stubs. Run: bats travel.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  T=$BATS_TEST_TMPDIR FX="$T/fx" S="$T/stubs"
  mkdir -p "$FX" "$S" "$T/bin"
  git init -q --bare -b main "$T/store.git"
  git clone -q "$T/store.git" "$T/store" 2>/dev/null
  git -C "$T/store" commit -q --allow-empty -m init && git -C "$T/store" push -q origin HEAD:main
  export FX ORCHESTRATE_SCRIPTS_DIR="$S" PATH="$T/bin:$PATH" ORCHESTRATE_STATE_DIR="$T/host" ORCHESTRATE_NOW=1795200000
  SD="$T/host/o__r"; mkdir -p "$SD/learnings"
  printf 'x\t5\tship\tabc\t-\n' >"$SD/reviews.tsv"; echo "keep calm" >"$SD/decisions.md"; echo l1 >"$SD/learnings/a.md"
  echo "noise" >"$SD/not-a-ledger.log"
  printf '#!/usr/bin/env bash\necho "device-lock.sh $*" >>"$FX/calls"\ncat "$FX/lock" 2>/dev/null || echo free\n' >"$S/device-lock.sh"
  printf '#!/usr/bin/env bash\necho "travel-guard.sh $*" >>"$FX/calls"\necho ok\n' >"$S/travel-guard.sh"
  # gh: variables from $FX/var-<name>; set and delete are logged.
  cat >"$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >>"$FX/calls"
case "$1 $2" in
  "variable get") cat "$FX/var-$3" 2>/dev/null || exit 1 ;;
  "variable set") echo "$5" >"$FX/var-$3" ;;
  "variable delete") rm -f "$FX/var-$3" ;;
esac
STUB
  chmod +x "$S"/*.sh "$T/bin/gh"
}
tr_() { "$SCRIPTS/travel.sh" "$@" --repo o/r --store "$T/store"; }
store_file() { git -C "$T/store" show "origin/main:o__r/$1" 2>/dev/null; }

@test "enter is a dry run by default; --apply copies the ledgers, sets MODE and the guard, and marks the host" {
  echo true >"$FX/var-POOLS"
  run tr_ enter --app-id 5846220 --runner-var POOLS
  [ "$status" -eq 0 ]
  [[ "$output" == *"o/r: would copy reviews.tsv decisions.md learnings into the store"* ]]
  [[ "$output" == *"this was a dry run"* ]]
  [ -z "$(store_file MODE)" ]
  [ "$(cat "$FX/var-POOLS")" = true ]
  run tr_ enter --app-id 5846220 --runner-var POOLS --apply
  [ "$status" -eq 0 ]
  [ "$(store_file MODE)" = traveling ]
  [[ "$(store_file LEASE)" == "holder=none"* ]]
  [ "$(store_file reviews.tsv)" = "$(cat "$SD/reviews.tsv")" ]
  [ "$(store_file learnings/a.md)" = l1 ]
  [ -z "$(store_file not-a-ledger.log)" ]
  [ "$(store_file runner-var)" = POOLS=true ]
  [ "$(cat "$FX/var-POOLS")" = false ]
  grep -qx 'travel-guard.sh on --repo o/r --app-id 5846220' "$FX/calls"
  [ -f "$SD/TRAVELING" ]
  [[ "$output" == *"next: enable the orchestrator and worker routines"* && "$output" != *"dry run"* ]]
  run tr_ enter --app-id 5846220 --apply
  [ "$status" -eq 3 ]
  [[ "$output" == *"already says MODE=traveling"* ]]
}

@test "enter refuses a live merge loop, a live device lock, or anything resembling a credential" {
  mkdir -p "$SD/loops"; touch "$SD/loops/merge.heartbeat"
  run tr_ enter --app-id 1 --apply
  [ "$status" -eq 3 ]
  [[ "$output" == *"the merge loop beat"* ]]
  rm "$SD/loops/merge.heartbeat"
  echo "held name=lane pid=1 age=5 live=yes" >"$FX/lock"
  run tr_ enter --app-id 1 --apply
  [ "$status" -eq 3 ]
  [[ "$output" == *"a live device lock is held"* ]]
  rm "$FX/lock"
  printf 'token ghp_%s\n' "$(printf 'A%.0s' $(seq 1 36))" >>"$SD/decisions.md"
  run tr_ enter --app-id 1 --apply
  [ "$status" -eq 3 ]
  [[ "$output" == *"resembles a credential; nothing was pushed"* ]]
  [ -z "$(store_file MODE)" ]
  [ -z "$(store_file decisions.md)" ]
  [ ! -f "$SD/TRAVELING" ]
}

@test "exit refuses a cloud run's live lease, then takes the campaign back and restores the host" {
  echo true >"$FX/var-POOLS"
  tr_ enter --app-id 1 --runner-var POOLS --apply >/dev/null
  "$SCRIPTS/travel-store.sh" lease take --holder cloud-run:9 --store "$T/store" --repo o/r >/dev/null
  run tr_ exit --runner-var POOLS --apply
  [ "$status" -eq 3 ]
  [[ "$output" == *"a cloud run holds the lease"* ]]
  # The cloud worked meanwhile: a newer ledger in the store.
  ORCHESTRATE_NOW=$((ORCHESTRATE_NOW + 6000)) "$SCRIPTS/travel-store.sh" journal --actor cloud-run:9 --action pass --store "$T/store" --repo o/r >/dev/null
  printf 'y\t6\tship\tdef\t-\n' >>"$T/store/o__r/reviews.tsv"; git -C "$T/store" commit -qam cloud; git -C "$T/store" push -q origin HEAD:main
  ORCHESTRATE_NOW=$((ORCHESTRATE_NOW + 6000)) run tr_ exit --runner-var POOLS --apply
  [ "$status" -eq 0 ]
  [ "$(store_file MODE)" = local ]
  [[ "$(store_file LEASE)" == "holder=none"* ]]
  [ "$(tail -1 "$SD/reviews.tsv")" = $'y\t6\tship\tdef\t-' ]
  ls -d "$SD"/travel-backup-* >/dev/null
  [ "$(grep -c . "$SD"/travel-backup-*/reviews.tsv)" -eq 1 ]
  [ "$(cat "$FX/var-POOLS")" = true ]
  grep -qx 'travel-guard.sh off --repo o/r' "$FX/calls"
  [ ! -f "$SD/TRAVELING" ]
  [[ "$output" == *"next: restart the host loops"* ]]
}

@test "status reports the marker, heartbeat, lock, store, variable and guard; usage" {
  echo false >"$FX/var-POOLS"
  run tr_ status --runner-var POOLS
  [ "$status" -eq 0 ]
  [[ "$output" == *"o/r: no marker; merge loop beat never; device lock free"* ]]
  [[ "$output" == *"o/r: store MODE=local holder=none"* ]]
  [[ "$output" == *"o/r: POOLS=false"* ]]
  [[ "$output" == *"o/r: travel guard ok"* ]]
  run "$SCRIPTS/travel.sh" enter --repo o/r --store "$T/store"
  [ "$status" -eq 2 ]
  [[ "$output" == *"needs --app-id"* ]]
  run "$SCRIPTS/travel.sh" status --store "$T/store"
  [ "$status" -eq 2 ]
  run tr_ status --runner-var 'bad-name'
  [ "$status" -eq 2 ]
}
