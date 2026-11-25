#!/usr/bin/env bats
# Exclusive gate classes (#396): `gate-slot.sh --class NAME` (or the per-repo gate-env.sh's
# gate_class) holds a one-slot pool for NAME beside the gate slot, so two commands of one class
# never run at once on a host, with the gate slots' bounded wait (exit 75), dead-holder reclaim and
# re-entrancy. Order is observed through files, never through timing alone.
# Run: bats gate-class.bats

setup() {
  load test_helper
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  T=$BATS_TEST_TMPDIR
  export ORCHESTRATE_SLOT_DIR="$T/slots" SLOT_POLL=0.05 ORCHESTRATE_BUILD_ROOT="$T/build"
  unset ORCHESTRATE_GATE_ENV ORCHESTRATE_BUILD_DIRS ORCHESTRATE_LANE_ID ORCHESTRATE_CLASS_HELD ORCHESTRATE_SLOT_HELD ORCHESTRATE_SLOT_HOLDER
  G="$SCRIPTS/gate-slot.sh" H="$SCRIPTS/heavy-build-slot.sh" L="$T/order"
}

gate() { "$G" "$@"; }
holders() { find "$ORCHESTRATE_SLOT_DIR/$1" -name holder 2>/dev/null | wc -l | tr -d ' '; }
# held NAME: a command that logs NAME-start, runs until release-NAME exists, then logs NAME-end.
held() { echo "echo $1-start >>'$L'; while [ ! -e '$T/release-$1' ]; do sleep 0.05; done; echo $1-end >>'$L'"; }
release() { touch "$T/release-$1"; }
await() { local _; for _ in $(seq 1 200); do eval "$1" && return 0; sleep 0.05; done; echo "timed out: $1"; return 1; }
started() { grep -qx "$1-start" "$L" 2>/dev/null; }

teardown() { for n in a b c; do release "$n"; done; wait; }

@test "two commands of one class never overlap; a gate of no class or another class is not held back" {
  gate --class db -- bash -c "$(held a)" &
  await 'started a'
  gate --class db -- bash -c "$(held b)" 2>"$T/b.err" &
  await 'grep -q "waiting (.*class db held by gate pid" "$T/b.err"'
  # Neither a classless gate nor one of another class waits for db.
  run gate -- bash -c 'echo plain'
  [ "$output" = plain ]
  run gate --class gen --wait 1 -- bash -c 'echo gen'
  [ "$status" -eq 0 ]
  [ "$output" = gen ]
  # The second db command has not started, and while it waits it holds neither db nor a gate slot.
  run ! started b
  [ "$(holders class-db)" -eq 1 ]
  [ "$(holders gate)" -eq 1 ]
  release a
  await 'started b'
  release b
  wait
  [ "$(tr '\n' ' ' <"$L")" = "a-start a-end b-start b-end " ]
  [ "$(holders class-db)" -eq 0 ]
  [ "$(holders gate)" -eq 0 ]
}

@test "a busy class is a bounded wait: exit 75 naming the holder, and nothing is left held" {
  gate --label lane-7 --class db -- bash -c "$(held a)" &
  await 'started a'
  pid=$(sed -n 1p "$ORCHESTRATE_SLOT_DIR/class-db/slot-1/holder")
  run gate --class db --wait 1 -- echo never
  [ "$status" -eq 75 ]
  [[ "$output" == *"no gate slot within 1s"*"class db held by lane-7 pid $pid"* ]]
  [[ "$output" != *never* ]]
  [ "$(holders gate)" -eq 1 ]   # only the holder's own
  # Classes are taken together or not at all: a free class is not kept while another is busy.
  run gate --class zz --class db --wait 1 -- true
  [ "$status" -eq 75 ]
  [ "$(holders class-zz)" -eq 0 ]
  release a
  wait
  [ "$(holders class-db)" -eq 0 ]
}

@test "a class slot held by a dead or reused PID is reclaimed; a live one is not" {
  mkdir -p "$ORCHESTRATE_SLOT_DIR/class-db/slot-1"
  printf '999999\nMon Jan 1 00:00:00 1990\nghost\n' >"$ORCHESTRATE_SLOT_DIR/class-db/slot-1/holder"
  run gate --class db --wait 2 -- bash -c 'echo "ran $ORCHESTRATE_CLASS_HELD"'
  [ "$status" -eq 0 ]
  [[ "$output" == "ran db="[0-9]* ]]
  # PID reuse: this live shell, with another start time.
  mkdir -p "$ORCHESTRATE_SLOT_DIR/class-db/slot-1"
  printf '%s\nMon Jan 1 00:00:00 1990\nreused\n' "$$" >"$ORCHESTRATE_SLOT_DIR/class-db/slot-1/holder"
  run gate --class db --wait 2 -- true
  [ "$status" -eq 0 ]
  [ "$(holders class-db)" -eq 0 ]
  # A live holder is never swept.
  gate --class db -- bash -c "$(held a)" &
  await 'started a'
  run gate --class db --wait 1 -- true
  [ "$status" -eq 75 ]
  [ "$(holders class-db)" -eq 1 ]
}

@test "re-entrant: a nested gate of a held class runs in it; a new class nested is taken (#313)" {
  run gate --class db -- "$G" --class db --wait 1 -- bash -c 'echo "inner $GATE_SLOT_KIND $ORCHESTRATE_CLASS_HELD"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"already inside a gate slot"* ]]
  [[ "$output" =~ inner\ gate\ db=[0-9]+$ ]]
  # Inside the only gate slot, with db held, the nested gate takes gen only.
  run gate --slots 1 --class db -- "$G" --slots 1 --class db --class gen --wait 1 -- bash -c 'echo "held: $ORCHESTRATE_CLASS_HELD"'
  [ "$status" -eq 0 ]
  [[ "$output" =~ held:\ db=([0-9]+)\ gen=([0-9]+) ]]
  [ "${BASH_REMATCH[1]}" != "${BASH_REMATCH[2]}" ]   # gen is the inner gate's own
  # Nested in a heavy build.
  run "$H" -- "$G" --class db --wait 1 -- bash -c 'echo "ran $GATE_SLOT_KIND $ORCHESTRATE_CLASS_HELD"'
  [ "$status" -eq 0 ]
  [[ "$output" =~ ran\ heavy\ db=[0-9]+ ]]
  [ "$(holders class-db)" -eq 0 ]
  [ "$(holders class-gen)" -eq 0 ]
  [ "$(holders gate)" -eq 0 ]
}

@test "a class marker that is no longer true is ignored" {
  gate --class db -- bash -c "$(held a)" &
  await 'started a'
  pid=$(sed -n 1p "$ORCHESTRATE_SLOT_DIR/class-db/slot-1/holder")
  # Another PID than the holder, a holder that is not a number, or another class name: still waits.
  ORCHESTRATE_CLASS_HELD="db=$$" run gate --class db --wait 1 -- true
  [ "$status" -eq 75 ]
  ORCHESTRATE_CLASS_HELD="db=x gen=$pid" run gate --class db --wait 1 -- true
  [ "$status" -eq 75 ]
  # The true holder's marker (as its own command inherits it) runs inside.
  ORCHESTRATE_CLASS_HELD="db=$pid" run gate --class db --wait 1 -- echo inside
  [ "$status" -eq 0 ]
  [ "$output" = inside ]
  release a
  wait
  # Left behind after its wrapper exited: the slot is gone, so the class is taken as usual.
  ORCHESTRATE_CLASS_HELD="db=$pid" run gate --class db -- bash -c 'echo "$ORCHESTRATE_CLASS_HELD"'
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^db=$pid\ db=[0-9]+$ ]]
  [[ "$output" != "db=$pid db=$pid" ]]
}

@test "the per-repo gate-env.sh maps commands to classes with gate_class" {
  cat >"$T/gate-env.sh" <<'ENV'
export GATE_ENV_SEEN=1
gate_class() {
  case " $* " in
    *" pytest "* | *"manage.py test"*) echo db ;;
    *" codegen "*) printf 'gen\ndb\n' ;;
  esac
}
ENV
  run gate --env-file "$T/gate-env.sh" -- bash -c 'echo "$GATE_ENV_SEEN|${ORCHESTRATE_CLASS_HELD:-}"' pytest
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^1\|db=[0-9]+$ ]]
  run gate --env-file "$T/gate-env.sh" -- bash -c 'echo "${ORCHESTRATE_CLASS_HELD:-none}"' codegen
  [[ "$output" =~ ^db=[0-9]+\ gen=[0-9]+$ ]]
  run gate --env-file "$T/gate-env.sh" -- bash -c 'echo "${ORCHESTRATE_CLASS_HELD:-none}"' lint
  [ "$output" = none ]
  # --class adds to the mapped ones; a repeat is one class.
  run gate --env-file "$T/gate-env.sh" --class db --class api -- bash -c 'echo "$ORCHESTRATE_CLASS_HELD"' pytest
  [[ "$output" =~ ^api=[0-9]+\ db=[0-9]+$ ]]
  # The mapped class contends like any other.
  gate --class db -- bash -c "$(held a)" &
  await 'started a'
  run gate --env-file "$T/gate-env.sh" --wait 1 -- true manage.py test
  [ "$status" -eq 75 ]
  [[ "$output" == *"class db held by"* ]]
  release a
  wait
  # A gate env without gate_class asks nothing (no class); a failing or bad one is a usage error.
  printf 'export X=1\n' >"$T/plain-env.sh"
  run gate --env-file "$T/plain-env.sh" -- bash -c 'echo "${ORCHESTRATE_CLASS_HELD:-none}"' pytest
  [ "$output" = none ]
  printf 'gate_class() { return 3; }\n' >"$T/bad-env.sh"
  run gate --env-file "$T/bad-env.sh" -- true
  [ "$status" -eq 2 ]
  [[ "$output" == *"gate_class in $T/bad-env.sh failed"* ]]
  printf 'gate_class() { echo "DB"; }\n' >"$T/bad-env.sh"
  run gate --env-file "$T/bad-env.sh" -- true
  [ "$status" -eq 2 ]
  [[ "$output" == *"bad class name: DB"* ]]
}

@test "class names are validated, never globbed; --class needs a name" {
  touch "$T/db"
  cd "$T"
  for bad in '*' 'a/b' '../x' '-x' 'Db' "$(printf 'x%.0s' $(seq 1 41))"; do
    run gate --class "$bad" -- echo ran
    [ "$status" -eq 2 ] || { echo "accepted: $bad"; false; }
    [[ "$output" != *ran* ]]
  done
  run gate --class "" -- true
  [ "$status" -eq 2 ]
  [[ "$output" == *"--class needs a name"* ]]
  [ ! -e "$ORCHESTRATE_SLOT_DIR/class-db" ]
}

@test "a Gradle command keeps its class through the heavy slot, and frees it after" {
  mkdir -p "$T/bin"
  printf '#!/bin/sh\necho "$GATE_SLOT_KIND $ORCHESTRATE_CLASS_HELD"; ls "$ORCHESTRATE_SLOT_DIR"\n' >"$T/bin/gradlew"; chmod +x "$T/bin/gradlew"
  PATH="$T/bin:$PATH" run gate --class db -- gradlew test
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^heavy\ db=[0-9]+$ ]]
  [[ "$output" == *class-db* ]]
  [ "$(holders class-db)" -eq 0 ]
  [ "$(holders heavy)" -eq 0 ]
  # Its exit code passes through; a busy class holds it back like any gate.
  printf '#!/bin/sh\nexit 4\n' >"$T/bin/gradlew"
  PATH="$T/bin:$PATH" run gate --class db -- gradlew test
  [ "$status" -eq 4 ]
  gate --class db -- bash -c "$(held a)" &
  await 'started a'
  PATH="$T/bin:$PATH" run gate --class db --wait 1 -- gradlew test
  [ "$status" -eq 75 ]
  [[ "$output" == *"no class slot within 1s (class db held by"* ]]
  [ "$(holders heavy)" -eq 0 ]
}

@test "the class is documented where the gate wrappers are" {
  grep -q -- '--class' "$G"
  grep -q 'gate_class' "$SCRIPTS/../host-load.md"
  grep -q -- '--class' "$SCRIPTS/../../../README.md"
}
