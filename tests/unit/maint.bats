#!/usr/bin/env bats
# `xinit maint`: the maintenance mode.

load helpers

setup() {
  use_state
}

# maint <args...>: run `xinit maint`, with its result in JSON.
maint() { run --separate-stderr "$XINIT" maint "$@" --format json; }

MAINT_FILE() { echo "$XINIT_STATE_DIR/${1:-default}/maintenance"; }

@test "maint: without a maintenance, status says off and writes nothing" {
  maint status
  [ "$status" -eq 0 ]
  [ "$(json 'd["instance"]')" = default ]
  [ "$(json 'd["maintenance"]')" = False ]
  [ "$(json 'd["until"]')" = "" ]
  [ ! -e "$XINIT_STATE_DIR" ]
  [ ! -e "$XINIT_RUN_DIR" ]
}

@test "maint: on lasts MAINT_DURATION by default, two hours" {
  maint on
  [ "$status" -eq 0 ]
  [ "$(json 'd["maintenance"]')" = True ]
  [ "$(json 'd["until"]')" = "$((NOW + 7200))" ]
  [ "$(json 'd["remaining_seconds"]')" = 7200 ]
  [ "$(json 'd["since"]')" = "$NOW" ]
  [ "$(json 'd["reason"]')" = "" ]
  maint status
  [ "$(json 'd["maintenance"]')" = True ]
  [ "$(json 'd["until"]')" = "$((NOW + 7200))" ]
  conf <<<"MAINT_DURATION=30min"
  maint on
  [ "$(json 'd["until"]')" = "$((NOW + 1800))" ]
}

@test "maint: on --for and --reason set the end and the reason" {
  maint on --for 1h30m --reason "upgrade to 18.10"
  [ "$status" -eq 0 ]
  [ "$(json 'd["until"]')" = "$((NOW + 5400))" ]
  [ "$(json 'd["reason"]')" = "upgrade to 18.10" ]
  maint on --for=45 --reason=short
  [ "$(json 'd["until"]')" = "$((NOW + 45))" ]
  [ "$(json 'd["reason"]')" = short ]
}

@test "maint: it records who set it, the sudo user when there is one" {
  SUDO_USER=alice maint on
  [ "$(json 'd["by"]')" = alice ]
  unset SUDO_USER
  maint on
  [ "$(json 'd["by"]')" = "$(id -un)" ]
}

@test "maint: the file is for its owner only" {
  umask 022
  maint on
  [ "$(stat -c %a "$(MAINT_FILE)")" = 600 ]
  [ "$(stat -c %a "$XINIT_STATE_DIR/default")" = 700 ]
}

@test "maint: a maintenance ends by itself" {
  maint on --for 10m
  XINIT_TEST_NOW=$((NOW + 599)) maint status
  [ "$(json 'd["maintenance"]')" = True ]
  [ "$(json 'd["remaining_seconds"]')" = 1 ]
  XINIT_TEST_NOW=$((NOW + 600)) maint status
  [ "$status" -eq 0 ]
  [ "$(json 'd["maintenance"]')" = False ]
  [ "$(json 'd["until"]')" = "" ]
}

@test "maint: on again replaces the end and the reason" {
  maint on --for 1d --reason first
  XINIT_TEST_NOW=$((NOW + 60)) maint on --for 5m
  [ "$(json 'd["until"]')" = "$((NOW + 360))" ]
  [ "$(json 'd["since"]')" = "$((NOW + 60))" ]
  [ "$(json 'd["reason"]')" = "" ]
}

@test "maint: off ends it, and off again is not an error" {
  maint on
  maint off
  [ "$status" -eq 0 ]
  [ "$(json 'd["maintenance"]')" = False ]
  [ ! -e "$(MAINT_FILE)" ]
  maint status
  [ "$(json 'd["maintenance"]')" = False ]
  maint off
  [ "$status" -eq 0 ]
}

@test "maint: each instance has its own maintenance" {
  touch "$XINIT_CONF_DIR/instances/wiki1.conf" "$XINIT_CONF_DIR/instances/wiki2.conf"
  maint -i wiki1 on
  [ "$(json 'd["instance"]')" = wiki1 ]
  [ -e "$(MAINT_FILE wiki1)" ]
  maint -i wiki2 status
  [ "$(json 'd["maintenance"]')" = False ]
  maint -i wiki1 status
  [ "$(json 'd["maintenance"]')" = True ]
}

@test "maint: a reason is kept on one line and never run" {
  maint on --reason $'line one\nUNTIL=9999999999\t"quoted" $(touch '"$BATS_TEST_TMPDIR"'/ran)'
  [ "$status" -eq 0 ]
  [ "$(json 'd["until"]')" = "$((NOW + 7200))" ]
  [ "$(json 'd["reason"]')" = "line one UNTIL=9999999999 \"quoted\" \$(touch $BATS_TEST_TMPDIR/ran)" ]
  [ "$(wc -l <"$(MAINT_FILE)")" -eq 4 ]
  [ ! -e "$BATS_TEST_TMPDIR/ran" ]
}

@test "maint: a long reason is cut to 200 characters" {
  maint on --reason "$(printf 'x%.0s' {1..300})"
  [ "$(json 'len(d["reason"])')" = 200 ]
}

@test "maint: on and off are recorded in the system log, status is not" {
  maint on --for 30m --reason "disk swap"
  [[ "$(calls logger)" == *"instance default: maintenance on for 30m, by "*": disk swap"* ]]
  maint status
  [ "$(calls logger | wc -l)" -eq 1 ]
  maint off
  [[ "$(calls logger)" == *"instance default: maintenance off, by "* ]]
  # Nothing was on: nothing to record.
  maint off
  [ "$(calls logger | wc -l)" -eq 2 ]
}

@test "maint: text output says on or off" {
  run "$XINIT" maint status
  [ "$output" = "maintenance: off" ]
  run "$XINIT" maint on --for 90m --reason why
  [ "$status" -eq 0 ]
  [[ "$output" == "maintenance: on until "*" (1h30m left), set by "*": why" ]]
}

@test "maint: usage errors exit 64 and change nothing" {
  local args
  for args in "" "pause" "on off" "on --for" "on --for soon" "on --for 0" "on --reason" \
    "on --bogus" "status --for 1h" "off --reason x" "status --format xml"; do
    # shellcheck disable=SC2086  # the arguments, split on purpose
    run "$XINIT" maint $args
    [ "$status" -eq 64 ] || { echo "'$args': status $status"; false; }
  done
  [ ! -e "$XINIT_STATE_DIR" ]
}

@test "maint: a MAINT_DURATION that is not a duration is a configuration error" {
  conf <<<"MAINT_DURATION=a while"
  maint on
  [ "$status" -eq 3 ]
  [ ! -e "$(MAINT_FILE)" ]
  # --for does not need it.
  maint on --for 1h
  [ "$status" -eq 0 ]
}

@test "maint: a stored maintenance that makes no sense is an error, not 'off'" {
  mkdir -p "$XINIT_STATE_DIR/default"
  echo "UNTIL=tomorrow" >"$(MAINT_FILE)"
  maint status
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  # on replaces it.
  maint on
  [ "$status" -eq 0 ]
  [ "$(json 'd["maintenance"]')" = True ]
}

@test "maint: when the state cannot be written, it says who can" {
  touch "$BATS_TEST_TMPDIR/a-file"
  XINIT_STATE_DIR="$BATS_TEST_TMPDIR/a-file" maint on
  [ "$status" -eq 3 ]
  # shellcheck disable=SC2154  # $stderr is set by bats' run
  [[ "$stderr" == *"run this as root, or as the user who owns"* ]]
  XINIT_STATE_DIR="relative" maint on
  [ "$status" -eq 3 ]
}

@test "maint: root writes as the owner of the state directory, not as root" {
  mkdir -p "$XINIT_STATE_DIR"
  fake id 'case "$1" in -u) echo 0 ;; *) echo root ;; esac'
  fake stat 'echo 990:985'
  fake setsid '[ "$1" = --wait ] && shift; exec "$@"'
  # The path is written out: that user gets no variable of the test's environment.
  fake setpriv "env >'$FAKEBIN/setpriv.env'; echo 'said by the owner'; echo 'an error' >&2; exit 7"
  export SECRET_OF_ROOT=hunter2
  SUDO_USER=alice run --separate-stderr "$XINIT" -i default maint on --for 1h --reason "why not"
  # What that user said, and how it ended.
  [ "$status" -eq 7 ]
  [ "$output" = "said by the owner" ]
  # shellcheck disable=SC2154  # $stderr is set by bats' run
  [ "$stderr" = "an error" ]
  [ "$(calls setpriv)" = "--reuid=990 --regid=985 --clear-groups -- $XINIT -i default maint on --for 1h --reason why not" ]
  [ "$(calls setsid | cut -d' ' -f1-2)" = "--wait setpriv" ]
  # It runs with what configures xinit, and nothing else of root's environment.
  grep -qx "XINIT_INVOKER=alice" "$FAKEBIN/setpriv.env"
  grep -qx "XINIT_STATE_DIR=$XINIT_STATE_DIR" "$FAKEBIN/setpriv.env"
  grep -q "^PATH=" "$FAKEBIN/setpriv.env"
  run ! grep -q "SECRET_OF_ROOT\|SUDO_USER\|^HOME=" "$FAKEBIN/setpriv.env"
  # Root itself wrote nothing.
  [ ! -e "$(MAINT_FILE)" ]
  # Reading needs no other user.
  rm -f "$FAKEBIN/setpriv.calls"
  run "$XINIT" maint status
  [ "$status" -eq 0 ]
  [ -z "$(calls setpriv)" ]
}

@test "maint: what is shown of a stored maintenance holds no control character" {
  mkdir -p "$XINIT_STATE_DIR/default"
  printf 'UNTIL=%s\nSINCE=%s\nBY=ro\033[2Jot\nREASON=a\033]0;title\007b\n' "$((NOW + 60))" "$NOW" >"$(MAINT_FILE)"
  run "$XINIT" maint status
  [ "$status" -eq 0 ]
  [[ "$output" != *[[:cntrl:]]* ]]
  [[ "$output" == *"set by ro"*"ot: a"*"b" ]]
}

@test "maint: root writes as root in a state directory that is root's, or that does not exist" {
  fake id 'case "$1" in -u) echo 0 ;; *) echo root ;; esac'
  fake setpriv 'exit 1'
  maint on
  [ "$status" -eq 0 ]
  fake stat 'echo 0:0'
  maint on
  [ "$status" -eq 0 ]
  [ -z "$(calls setpriv)" ]
}
