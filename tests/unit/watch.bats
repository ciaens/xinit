#!/usr/bin/env bats
# `xinit watch`: the restart policy. Scenarios S-WATCH-* of docs/TESTING.md, on fakes.

load helpers

setup() {
  use_fixture tomcat10-pgsql
  use_state
  DUMP="$FIXTURES/journal/thread-dump-unit.txt"
  STATE_DIR="$XINIT_STATE_DIR/default"
}

# watch_at <seconds after $NOW> [xinit watch arguments...]: one run at that time, in JSON.
watch_at() {
  local offset="$1"
  shift
  XINIT_TEST_NOW=$((NOW + offset)) run --separate-stderr "$XINIT" watch --format json "$@"
}

# w <field>: a field of the "watch" member of the output.
w() { json "d['watch']['$1']"; }

# stored <KEY>: a value of the state file.
stored() { sed -n "s/^$1=//p" "$STATE_DIR/state"; }

# restarts: how many times XWiki was restarted.
restarts() { calls systemctl | grep -c '^restart ' || true; }

# failing: from now on, XWiki does not answer.
failing() { export FAKE_CURL_EXIT=28 FAKE_CURL_ERROR="Operation timed out"; }
healed() { unset FAKE_CURL_EXIT FAKE_CURL_ERROR; }

@test "S-WATCH-07 watch: a healthy XWiki is left alone, and the run is remembered" {
  watch_at 0
  [ "$status" -eq 0 ]
  [ "$(w action)" = none ]
  [ "$(w reason)" = healthy ]
  [ "$(w failures)" = 0 ]
  [ "$(w dry_run)" = False ]
  [ "$(json 'len(d["results"])')" = 6 ]
  [ "$(stored LAST_RUN)" = "$NOW" ]
  [ "$(stored FAILURES)" = 0 ]
  [ "$(restarts)" = 0 ]
  [ -z "$(calls kill)" ]
  [ -z "$(calls logger)" ]
  [ "$(stat -c %a "$STATE_DIR/state")" = 600 ]
}

@test "S-WATCH-01 watch: the third failed run in a row stores a thread dump and restarts once" {
  failing
  export FAKE_JOURNAL_UNIT="$DUMP"
  watch_at 0
  [ "$status" -eq 0 ]
  [ "$(w action)" = none ]
  [ "$(w reason)" = counting ]
  [ "$(w failures)" = 1 ]
  [ "$(w failed_checks)" = "['http']" ]
  watch_at 60
  [ "$(w reason)" = counting ]
  [ "$(w failures)" = 2 ]
  [ "$(restarts)" = 0 ]
  [ -z "$(calls kill)" ]

  watch_at 120
  [ "$status" -eq 0 ]
  [ "$(w action)" = restart ]
  [ "$(w reason)" = threshold ]
  [ "$(w failures)" = 3 ]
  [ "$(w restart_ok)" = True ]
  [ "$(w restarts)" = 1 ]
  [ "$(calls systemctl | grep '^restart ')" = "restart -- tomcat10.service" ]
  # The thread dump: the JVM of the fixture got SIGQUIT, and what it wrote is stored.
  [ "$(calls kill)" = "-s QUIT 98" ]
  dump="$(w thread_dump)"
  [[ "$dump" == "$STATE_DIR/threaddump-"*.txt ]]
  grep -q "Full thread dump" "$dump"
  [ "$(stat -c %a "$dump")" = 600 ]
  [ "$(stored LAST_RESTART)" = "$((NOW + 120))" ]
  [[ "$(calls logger)" == *"notification (restart): http (timeout) failed in 3 runs in a row"* ]]
}

@test "S-WATCH-02 watch: during the cooldown there is no second restart" {
  failing
  conf <<<"RESTART_AFTER=1"
  watch_at 0
  [ "$(w action)" = restart ]
  watch_at 60
  [ "$(w action)" = none ]
  [ "$(w reason)" = cooldown ]
  [ "$(w cooldown_remaining_seconds)" = 840 ]
  watch_at 899
  [ "$(w reason)" = cooldown ]
  [ "$(restarts)" = 1 ]
  watch_at 900
  [ "$(w action)" = restart ]
  [ "$(restarts)" = 2 ]
}

@test "S-WATCH-03 watch: during a maintenance failures are counted, and nothing is restarted" {
  failing
  run "$XINIT" maint on --for 10m
  watch_at 0
  watch_at 60
  watch_at 120
  [ "$status" -eq 0 ]
  [ "$(w action)" = none ]
  [ "$(w reason)" = maintenance ]
  [ "$(w failures)" = 3 ]
  [ "$(stored FAILURES)" = 3 ]
  [ "$(stored FAILED)" = "http (timeout)" ]
  [ "$(restarts)" = 0 ]
  # S-WATCH-04: once the maintenance has ended by itself, xinit acts again.
  watch_at 600
  [ "$(w action)" = restart ]
}

@test "watch: a maintenance that cannot be read is not taken for none" {
  failing
  conf <<<"RESTART_AFTER=1"
  mkdir -p "$STATE_DIR"
  echo "UNTIL=someday" >"$STATE_DIR/maintenance"
  watch_at 0
  [ "$status" -eq 0 ]
  [ "$(w action)" = none ]
  [ "$(w reason)" = maintenance-unknown ]
  [ "$(restarts)" = 0 ]
}

@test "S-WATCH-05 watch: after MAX_RESTARTS restarts it stops, and says so once" {
  failing
  conf <<<"RESTART_AFTER=1
COOLDOWN=0"
  watch_at 0
  watch_at 60
  watch_at 120
  [ "$(w action)" = restart ]
  [ "$(w restarts)" = 3 ]
  [ "$(restarts)" = 3 ]
  watch_at 180
  [ "$status" -eq 0 ]
  [ "$(w action)" = none ]
  [ "$(w reason)" = flapping ]
  [ "$(calls logger | grep -c 'notification (flapping)')" = 1 ]
  watch_at 240
  [ "$(w reason)" = flapping ]
  # Also once the restarts are older than the window: someone has to look first.
  watch_at 7200
  [ "$(w reason)" = flapping ]
  [ "$(restarts)" = 3 ]
  [ "$(calls logger | grep -c 'notification (flapping)')" = 1 ]

  # A healthy run ends it.
  healed
  watch_at 7260
  [ "$(w reason)" = healthy ]
  [ "$(stored ESCALATED)" = 0 ]
  failing
  watch_at 7320
  [ "$(w action)" = restart ]
  [ "$(restarts)" = 4 ]
}

@test "S-WATCH-07 watch: a healthy run starts the count again" {
  failing
  watch_at 0
  watch_at 60
  healed
  watch_at 120
  [ "$(w reason)" = healthy ]
  [ "$(w failures)" = 0 ]
  [[ "$(calls logger)" == *"healthy again, after 2 failed runs"* ]]
  failing
  watch_at 180
  watch_at 240
  [ "$(w reason)" = counting ]
  [ "$(w failures)" = 2 ]
  [ "$(restarts)" = 0 ]
}

@test "watch: a warning is not a failure" {
  # A JVM that just started and refuses connections: http is 'warn starting'.
  export FAKE_CURL_EXIT=7 FAKE_JVM_AGE=10
  conf <<<"RESTART_AFTER=1"
  watch_at 0
  [ "$(json '[r["status"] for r in d["results"] if r["check"] == "http"][0]')" = warn ]
  [ "$(w action)" = none ]
  [ "$(w reason)" = healthy ]
  [ "$(restarts)" = 0 ]
}

@test "watch: a check that could not tell neither counts nor clears the count" {
  failing
  watch_at 0
  [ "$(w failures)" = 1 ]
  # The host name of the URL does not resolve: http is unknown.
  export FAKE_CURL_EXIT=6
  watch_at 60
  [ "$(json '[r["status"] for r in d["results"] if r["check"] == "http"][0]')" = unknown ]
  [ "$(w action)" = none ]
  [ "$(w reason)" = unknown ]
  [ "$(w failures)" = 1 ]
  [ "$(restarts)" = 0 ]
}

@test "watch: a database failure does not count, unless ACT_ON says so" {
  export FAKE_DB_TCP=refused
  conf <<<"RESTART_AFTER=1"
  watch_at 0
  [ "$(json 'd["status"]')" = crit ]
  [ "$(w action)" = none ]
  [ "$(w reason)" = healthy ]
  conf <<<"RESTART_AFTER=1
ACT_ON=http db"
  watch_at 60
  [ "$(w action)" = restart ]
  [ "$(w failed_checks)" = "['db']" ]
}

@test "watch: a heap out-of-memory error counts, and a missing thread dump does not stop the restart" {
  export FAKE_JOURNAL_UNIT="$FIXTURES/journal/heap-oom-unit.txt"
  conf <<<"RESTART_AFTER=1"
  watch_at 0
  [ "$status" -eq 0 ]
  [ "$(w action)" = restart ]
  [ "$(w failed_checks)" = "['oom']" ]
  [ "$(w thread_dump)" = "" ]
  [ "$(w restart_ok)" = True ]
  [[ "$(calls logger)" == *"no thread dump: the JVM wrote no thread dump"* ]]
}

@test "watch: a stopped XWiki counts, and is restarted without a thread dump" {
  export FAKE_UNIT_STOPPED=1 FAKE_CURL_EXIT=7
  conf <<<"RESTART_AFTER=1"
  watch_at 0
  [ "$(w action)" = restart ]
  [[ "$(w failed_checks)" == "['process', 'http']" ]]
  [ -z "$(calls kill)" ]
  [ "$(w thread_dump)" = "" ]
  [ "$(restarts)" = 1 ]
}

@test "watch: --dry-run says what it would do, and does nothing" {
  failing
  watch_at 0
  watch_at 60
  cp "$STATE_DIR/state" "$BATS_TEST_TMPDIR/state.before"
  rm -f "$FAKEBIN"/logger.calls
  watch_at 120 --dry-run
  [ "$status" -eq 0 ]
  [ "$(w action)" = restart ]
  [ "$(w dry_run)" = True ]
  [ "$(w failures)" = 3 ]
  [ "$(w restart_ok)" = "" ]
  [ "$(restarts)" = 0 ]
  [ -z "$(calls kill)" ]
  [ -z "$(calls logger)" ]
  diff "$STATE_DIR/state" "$BATS_TEST_TMPDIR/state.before"
}

@test "watch: --dry-run writes nothing at all" {
  watch_at 0 --dry-run
  [ "$status" -eq 0 ]
  [ "$(w reason)" = healthy ]
  [ ! -e "$XINIT_STATE_DIR" ]
  [ ! -e "$XINIT_RUN_DIR" ]
}

@test "S-WATCH-06 watch: a run that finds the lock held ends at once" {
  mkdir -p "$XINIT_RUN_DIR/default"
  mkfifo "$BATS_TEST_TMPDIR/release"
  flock "$XINIT_RUN_DIR/default/lock" cat "$BATS_TEST_TMPDIR/release" &
  # Wait until the lock is held.
  while flock -n "$XINIT_RUN_DIR/default/lock" true; do :; done
  failing
  watch_at 0
  echo go >"$BATS_TEST_TMPDIR/release"
  wait
  [ "$status" -eq 0 ]
  [ "$(w action)" = none ]
  [ "$(w reason)" = locked ]
  [ "$(json 'len(d["results"])')" = 0 ]
  [ -z "$(calls curl)" ]
  [ ! -e "$STATE_DIR/state" ]
}

@test "watch: a restart that fails is an error, and still counts as a restart" {
  failing
  export FAKE_RESTART_ERROR="Access denied"
  conf <<<"RESTART_AFTER=1"
  watch_at 0
  [ "$status" -eq 3 ]
  [ "$(w action)" = restart ]
  [ "$(w restart_ok)" = False ]
  [ "$(stored LAST_RESTART)" = "$NOW" ]
  [[ "$(calls logger)" == *"the restart failed: systemctl failed with status 1: Access denied"* ]]
  # shellcheck disable=SC2154  # $stderr is set by bats' run
  [[ "$stderr" == *"the restart failed"* ]]
  watch_at 60
  [ "$(w reason)" = cooldown ]
}

@test "watch: RESTART_CMD replaces systemctl, and is not run by a shell" {
  failing
  fake myrestart ''
  conf <<<"RESTART_AFTER=1
RESTART_CMD=myrestart --now wiki; touch $BATS_TEST_TMPDIR/ran \$(id)"
  watch_at 0
  [ "$(w action)" = restart ]
  [ "$(w restart_ok)" = True ]
  [ "$(calls myrestart)" = "--now wiki; touch $BATS_TEST_TMPDIR/ran \$(id)" ]
  [ ! -e "$BATS_TEST_TMPDIR/ran" ]
  [ "$(restarts)" = 0 ]
}

@test "watch: a RESTART_CMD that is only spaces restarts nothing, and says so" {
  failing
  conf <<<'RESTART_AFTER=1
RESTART_CMD="   "'
  watch_at 0
  [ "$status" -eq 3 ]
  [ "$(w restart_ok)" = False ]
  [[ "$(calls logger)" == *"the restart failed: RESTART_CMD is empty"* ]]
}

@test "watch: a RESTART_CMD that leaves a process behind neither keeps the run waiting nor the lock" {
  local real_sleep
  failing
  real_sleep="$(type -aP sleep | grep -vF "$FAKEBIN/" | head -n 1)"
  # As a start script does: the process it starts keeps its output and every descriptor it got.
  fake start-wiki "$real_sleep 20 &
echo \$! >'$BATS_TEST_TMPDIR/left-behind'"
  conf <<<"RESTART_AFTER=1
RESTART_CMD=start-wiki"
  SECONDS=0
  watch_at 0
  [ "$status" -eq 0 ]
  [ "$(w restart_ok)" = True ]
  [ "$SECONDS" -lt 15 ]
  # The lock is free while that process still runs.
  kill -0 "$(cat "$BATS_TEST_TMPDIR/left-behind")"
  flock -n "$XINIT_RUN_DIR/default/lock" true
  kill "$(cat "$BATS_TEST_TMPDIR/left-behind")"
}

@test "watch: without a unit and without RESTART_CMD, the restart fails with that reason" {
  use_other_fixture war-tomcat10-pgsql
  use_state
  conf <<<"WEBAPP_DIR=/var/lib/tomcat10/webapps/xwiki
BASE_URL=http://localhost:8080/xwiki
RESTART_AFTER=1
ACT_ON=http"
  failing
  watch_at 0
  [ "$status" -eq 3 ]
  [ "$(w action)" = restart ]
  [ "$(w restart_ok)" = False ]
  [[ "$(calls logger)" == *"neither UNIT nor RESTART_CMD is known"* ]]
}

@test "watch: a lock that has been held for too long is an error, not a quiet end" {
  mkdir -p "$XINIT_RUN_DIR/default" "$STATE_DIR"
  echo "LAST_RUN=$((NOW - 1300))" >"$STATE_DIR/state"
  mkfifo "$BATS_TEST_TMPDIR/release"
  flock "$XINIT_RUN_DIR/default/lock" cat "$BATS_TEST_TMPDIR/release" &
  while flock -n "$XINIT_RUN_DIR/default/lock" true; do :; done
  watch_at 0
  echo go >"$BATS_TEST_TMPDIR/release"
  wait
  [ "$status" -eq 3 ]
  [ "$(w reason)" = locked ]
  [[ "$(calls logger)" == *"has held the lock for more than 20m"* ]]
}

@test "watch: only the last five thread dumps are kept" {
  local i dumps
  failing
  export FAKE_JOURNAL_UNIT="$DUMP"
  conf <<<"RESTART_AFTER=1"
  mkdir -p "$STATE_DIR"
  for i in 1 2 3 4 5 6; do
    echo old >"$STATE_DIR/threaddump-2020010${i}T000000.txt"
  done
  watch_at 0
  [ -n "$(w thread_dump)" ]
  dumps=("$STATE_DIR"/threaddump-*.txt)
  [ "${#dumps[@]}" = 5 ]
  [ ! -e "$STATE_DIR/threaddump-20200101T000000.txt" ]
  [ ! -e "$STATE_DIR/threaddump-20200102T000000.txt" ]
  [ -e "$STATE_DIR/threaddump-20200103T000000.txt" ]
  [ -e "$(w thread_dump)" ]
}

@test "watch: with an empty ACT_ON nothing is ever restarted" {
  failing
  conf <<<"RESTART_AFTER=1
ACT_ON="
  watch_at 0
  [ "$status" -eq 0 ]
  [ "$(json 'd["status"]')" = crit ]
  [ "$(w action)" = none ]
  [ "$(restarts)" = 0 ]
}

@test "watch: a check of ACT_ON runs also when CHECKS leaves it out" {
  failing
  conf <<<"CHECKS=disk"
  watch_at 0
  [ "$(w reason)" = counting ]
  [ "$(json '[r["check"] for r in d["results"]]')" = "['disk', 'process', 'http', 'oom']" ]
}

@test "watch: a configuration that makes no sense stops it before anything runs" {
  local line
  failing
  for line in "RESTART_AFTER=0" "RESTART_AFTER=soon" "MAX_RESTARTS=0" "COOLDOWN=a while" \
    "MAX_RESTARTS_WINDOW=" "ACT_ON=http nope" "CHECKS=nope"; do
    conf <<<"$line"
    watch_at 0
    [ "$status" -eq 3 ] || { echo "$line: status $status"; false; }
    [ -z "$output" ]
  done
  [ -z "$(calls curl)" ]
  [ ! -e "$XINIT_STATE_DIR" ]
}

@test "watch: usage errors exit 64" {
  run "$XINIT" watch --format nagios
  [ "$status" -eq 64 ]
  run "$XINIT" watch http
  [ "$status" -eq 64 ]
  run "$XINIT" watch --format
  [ "$status" -eq 64 ]
}

@test "watch: without an installation there is nothing to watch" {
  rm -rf "$XINIT_ROOT"
  mkdir -p "$XINIT_ROOT"
  fake dpkg-query ''
  watch_at 0
  [ "$status" -eq 3 ]
  [ "$(w action)" = none ]
  [ "$(w reason)" = no-installation ]
}

@test "watch: a state that makes no sense starts again from nothing" {
  failing
  mkdir -p "$STATE_DIR"
  printf '%s\n' "FAILURES=many" "LAST_RESTART=\$(id)" "RESTARTS=1 two 3" >"$STATE_DIR/state"
  watch_at 0
  [ "$status" -eq 0 ]
  [ "$(w failures)" = 1 ]
  [ "$(w reason)" = counting ]
}

@test "watch: a state that cannot be read stops it before it acts" {
  failing
  conf <<<"RESTART_AFTER=1"
  mkdir -p "$STATE_DIR/state"
  watch_at 0
  [ "$status" -eq 3 ]
  [ "$(restarts)" = 0 ]
  [ -z "$(calls curl)" ]
}

@test "watch: each instance has its own count" {
  failing
  touch "$XINIT_CONF_DIR/instances/wiki1.conf" "$XINIT_CONF_DIR/instances/wiki2.conf"
  watch_at 0 -i wiki1
  watch_at 60 -i wiki1
  [ "$(w failures)" = 2 ]
  watch_at 120 -i wiki2
  [ "$(json 'd["instance"]')" = wiki2 ]
  [ "$(w failures)" = 1 ]
  [ -e "$XINIT_STATE_DIR/wiki1/state" ]
  [ -e "$XINIT_STATE_DIR/wiki2/state" ]
}

@test "watch: text output ends with what the run did" {
  failing
  XINIT_TEST_NOW="$NOW" run "$XINIT" watch
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == "watch: none, http (timeout) failed: run 1 of 3 before a restart" ]]
  XINIT_TEST_NOW="$NOW" run "$XINIT" watch --dry-run
  [[ "${lines[-1]}" == *"(dry run: nothing was done)" ]]
}
