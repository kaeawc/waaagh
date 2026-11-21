#!/usr/bin/env bats
# travel-store.sh (traveling-mode.md): MODE, LEASE and journal.tsv in the state store, one writer
# at a time through a lease and fast-forward-only pushes. Real git against a local bare "store".
# Run: bats travel-store.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  T=$BATS_TEST_TMPDIR
  git init -q --bare -b main "$T/store.git"
  git clone -q "$T/store.git" "$T/a" 2>/dev/null
  git -C "$T/a" commit -q --allow-empty -m init && git -C "$T/a" push -q origin HEAD:main
  git clone -q "$T/store.git" "$T/b" 2>/dev/null
  export ORCHESTRATE_NOW=1795200000   # 2026-11-21T...
}
ts() { local d=$1; shift; "$SCRIPTS/travel-store.sh" "$@" --store "$T/$d" --repo kaeawc/waaagh; }
lease_of() { git -C "$T/$1" show origin/main:kaeawc__waaagh/LEASE 2>/dev/null || true; }

@test "mode defaults to local; set-mode writes, journals and pushes it" {
  run ts a mode
  [ "$output" = local ]
  run "$SCRIPTS/travel-store.sh" set-mode traveling --store "$T/a" --repo kaeawc/waaagh
  [ "$status" -eq 0 ]
  run ts b mode
  [ "$output" = traveling ]
  [[ "$(cat "$T/b/kaeawc__waaagh/journal.tsv")" == *$'\thost\tmode\ttraveling' ]]
  run "$SCRIPTS/travel-store.sh" set-mode away --store "$T/a" --repo kaeawc/waaagh
  [ "$status" -eq 2 ]
}

@test "one writer: a take on a free lease pushes; another holder waits until it expires" {
  run ts a lease take --holder cloud-run:1
  [ "$status" -eq 0 ]
  [[ "$output" == "taken by cloud-run:1 until "* ]]
  [[ "$(lease_of a)" == "holder=cloud-run:1 expires=$((ORCHESTRATE_NOW + 5400)) since="* ]]
  run ts b lease take --holder cloud-run:2
  [ "$status" -eq 4 ]
  [[ "$output" == "held by cloud-run:1 until "* ]]
  # The same holder may take it again (a retried run), and renew it.
  run ts a lease take --holder cloud-run:1 --ttl 60
  [ "$status" -eq 0 ]
  ORCHESTRATE_NOW=$((ORCHESTRATE_NOW + 30)) run ts a lease renew --holder cloud-run:1
  [ "$status" -eq 0 ]
  run ts b lease renew --holder cloud-run:2
  [ "$status" -eq 4 ]
  # Expired: anyone may take it.
  ORCHESTRATE_NOW=$((ORCHESTRATE_NOW + 6000)) run ts b lease take --holder cloud-run:2
  [ "$status" -eq 0 ]
  [[ "$(cat "$T/b/kaeawc__waaagh/journal.tsv")" == *$'\tcloud-run:2\tlease-take\tfrom=cloud-run:1 expired=1'* ]]
}

@test "a rejected push takes nothing and leaves the checkout on the remote's history" {
  # b has a stale view: a pushes a lease, then b commits a journal row without pushing, so b's next
  # push cannot fast-forward... except that every command fast-forwards first. Make b diverge by
  # hand to force the rejected path.
  run ts a lease take --holder cloud-run:1 --ttl 60
  [ "$status" -eq 0 ]
  git -C "$T/b" pull -q --ff-only
  echo local >"$T/b/kaeawc__waaagh/x"; git -C "$T/b" add -A; git -C "$T/b" commit -qm diverge
  ORCHESTRATE_NOW=$((ORCHESTRATE_NOW + 120)) run ts a lease release --holder cloud-run:1
  [ "$status" -eq 0 ]
  ORCHESTRATE_NOW=$((ORCHESTRATE_NOW + 120)) run ts b lease take --holder cloud-run:2
  [ "$status" -eq 3 ]
  [[ "$output" == *"cannot fast-forward"* || "$output" == *"push rejected"* ]]
  [[ "$(lease_of a)" == "holder=none"* ]]
}

@test "release frees the lease only for its holder; journal appends rows and pushes on request" {
  run ts a lease take --holder host
  run ts b lease release --holder cloud-run:9
  [ "$status" -eq 4 ]
  run ts a lease release --holder host
  [ "$status" -eq 0 ]
  [[ "$(lease_of a)" == "holder=none expires=0 since="* ]]
  run ts a journal --actor cloud-run:1 --action merge-request --detail "pr=5 sha=abc" --push
  [ "$status" -eq 0 ]
  git -C "$T/b" pull -q --ff-only
  [[ "$(tail -1 "$T/b/kaeawc__waaagh/journal.tsv")" == *$'\tcloud-run:1\tmerge-request\tpr=5 sha=abc' ]]
  run ts a journal --actor x --action "two"$'\t'"cols"
  [ "$status" -eq 2 ]
  run ts a lease show
  [[ "$output" == "holder=none expires=0 since="* ]]
}

@test "scan finds anything resembling a credential, and passes a clean folder" {
  mkdir -p "$T/a/kaeawc__waaagh"
  printf 'decision: ship it\n' >"$T/a/kaeawc__waaagh/decisions.md"
  run ts a scan
  [ "$status" -eq 0 ]
  [ "$output" = clean ]
  printf 'token ghp_%s\n' "$(printf 'A%.0s' $(seq 1 36))" >>"$T/a/kaeawc__waaagh/decisions.md"
  printf -- '-----BEGIN RSA PRIVATE KEY-----\n' >"$T/a/kaeawc__waaagh/k.pem"
  run ts a scan
  [ "$status" -eq 3 ]
  [[ "$output" == *"decisions.md:2: looks like a credential"* ]]
  [[ "$output" == *"k.pem:1: looks like a credential"* ]]
}

@test "usage" {
  run "$SCRIPTS/travel-store.sh" lease take --store "$T/a" --repo kaeawc/waaagh
  [ "$status" -eq 2 ]
  run "$SCRIPTS/travel-store.sh" mode --store "$T/nope" --repo kaeawc/waaagh
  [ "$status" -eq 2 ]
  run "$SCRIPTS/travel-store.sh" mode --store "$T/a"
  [ "$status" -eq 2 ]
  run "$SCRIPTS/travel-store.sh" lease take --holder h --ttl 0 --store "$T/a" --repo kaeawc/waaagh
  [ "$status" -eq 2 ]
}
