#!/usr/bin/env bats
# The state library: durations, state files and the lock.
# shellcheck disable=SC2034  # XINIT_INSTANCE and XINIT_CFG are read by the sourced libraries

load helpers

setup() {
  local lib
  use_state
  for lib in core config result state; do
    # shellcheck disable=SC1090  # the libraries, as bin/xinit sources them
    source "$XINIT_REPO/lib/xinit/$lib.sh"
  done
  XINIT_INSTANCE=default
  xinit_config_load
}

@test "state: a duration is a number of seconds, or numbers with units" {
  local case
  for case in 90=90 90s=90 10sec=10 15m=900 15min=900 2h=7200 1d=86400 1h30m=5400 \
    1d2h3m4s=93784 1m30=90 0=0 010=10; do
    run xinit_duration_seconds "${case%%=*}"
    [ "$status" -eq 0 ] || { echo "$case: status $status"; false; }
    [ "$output" = "${case#*=}" ] || { echo "$case: got $output"; false; }
  done
}

@test "state: what is not a duration is refused" {
  local text
  for text in "" h 5ms 1.5h -5 "1h 30m" 2w forever 1234567890; do
    run xinit_duration_seconds "$text"
    [ "$status" -eq 1 ] || { echo "'$text' was accepted: $output"; false; }
  done
}

@test "state: a duration is shown with its two largest units" {
  [ "$(xinit_duration_text 0)" = 0s ]
  [ "$(xinit_duration_text 45)" = 45s ]
  [ "$(xinit_duration_text 7200)" = 2h ]
  [ "$(xinit_duration_text 7199)" = 1h59m ]
  [ "$(xinit_duration_text 93784)" = 1d2h ]
  [ "$(xinit_duration_text 86405)" = 1d ]
}

@test "state: each instance has its own state and runtime directories" {
  [ "$(xinit_state_dir)" = "$XINIT_STATE_DIR/default" ]
  [ "$(xinit_run_dir)" = "$XINIT_RUN_DIR/default" ]
  XINIT_INSTANCE=wiki2
  [ "$(xinit_state_dir)" = "$XINIT_STATE_DIR/wiki2" ]
  XINIT_CFG[STATE_DIR]="/var/lib/xinit//"
  [ "$(xinit_state_dir)" = /var/lib/xinit/wiki2 ]
}

@test "state: STATE_DIR and RUN_DIR have to be absolute paths" {
  XINIT_CFG[STATE_DIR]="relative/dir"
  run xinit_state_dir
  [ "$status" -eq 3 ]
  XINIT_CFG[RUN_DIR]=""
  run xinit_run_dir
  [ "$status" -eq 3 ]
}

@test "state: a state file is written for its owner only, and read back" {
  local file
  local -A read=()
  file="$(xinit_state_dir)/test"
  umask 022
  xinit_state_write "$file" "A=1" "TEXT=a = \"b\" 'c' \$d" "EMPTY="
  [ "$(stat -c %a "$file")" = 600 ]
  [ "$(stat -c %a "$(xinit_state_dir)")" = 700 ]
  [ "$(stat -c %a "$XINIT_STATE_DIR")" = 700 ]
  xinit_state_read "$file" read
  [ "${read[A]}" = 1 ]
  [ "${read[TEXT]}" = "a = \"b\" 'c' \$d" ]
  [ "${read[EMPTY]}" = "" ]
  [ "${#read[@]}" -eq 3 ]
}

@test "state: writing replaces the file and leaves no temporary file" {
  local file
  local -A read=()
  file="$(xinit_state_dir)/test"
  xinit_state_write "$file" "A=1" "B=2"
  xinit_state_write "$file" "A=3"
  xinit_state_read "$file" read
  [ "${read[A]}" = 3 ]
  [ -z "${read[B]+x}" ]
  [ "$(ls -A "$(xinit_state_dir)")" = test ]
}

@test "state: a state file is parsed, never run, and its odd lines are ignored" {
  local file
  local -A read=()
  mkdir -p "$(xinit_state_dir)"
  file="$(xinit_state_dir)/test"
  printf '%s\n' 'A=$(touch '"$BATS_TEST_TMPDIR"'/ran)' 'lower=1' 'no equal sign' '' 'B=2' >"$file"
  xinit_state_read "$file" read
  [ "${read[A]}" = "\$(touch $BATS_TEST_TMPDIR/ran)" ]
  [ "${read[B]}" = 2 ]
  [ "${#read[@]}" -eq 2 ]
  [ ! -e "$BATS_TEST_TMPDIR/ran" ]
}

@test "state: reading tells a missing file from one that cannot be read" {
  local -A read=()
  run xinit_state_read "$(xinit_state_dir)/missing" read
  [ "$status" -eq 1 ]
  mkdir -p "$(xinit_state_dir)/a-directory"
  run xinit_state_read "$(xinit_state_dir)/a-directory" read
  [ "$status" -eq 2 ]
}

@test "state: a file in a directory this user may not enter is not taken for a missing one" {
  local -A read=()
  [ "$(id -u)" -ne 0 ] || skip "root may enter every directory; S-MAINT-01 covers it"
  mkdir -p "$XINIT_STATE_DIR/default"
  chmod 000 "$XINIT_STATE_DIR"
  run xinit_state_read "$XINIT_STATE_DIR/default/test" read
  chmod 700 "$XINIT_STATE_DIR"
  [ "$status" -eq 2 ]
}

@test "state: writing where no directory can be made fails without ending xinit" {
  touch "$BATS_TEST_TMPDIR/a-file"
  run xinit_state_write "$BATS_TEST_TMPDIR/a-file/sub/test" "A=1"
  [ "$status" -eq 1 ]
}

@test "state: a text is stored on one line, without control characters, and cut" {
  [ "$(xinit_state_text $'two\nlines\tand\ra bell\a' 100)" = "two lines and a bell " ]
  [ "$(xinit_state_text "abcdefgh" 3)" = abc ]
}

@test "state: the lock is held by one process at a time, until it ends" {
  local holder="$BATS_TEST_TMPDIR/holder.sh"
  cat >"$holder" <<SCRIPT
set -euo pipefail
for lib in core config result state; do . "$XINIT_REPO/lib/xinit/\$lib.sh"; done
XINIT_INSTANCE=default
xinit_config_load
xinit_lock_acquire || exit 7
touch "$BATS_TEST_TMPDIR/held"
[ "\${1:-}" != wait ] || read -r _ <"$BATS_TEST_TMPDIR/release"
SCRIPT
  mkfifo "$BATS_TEST_TMPDIR/release"
  bash "$holder" wait &
  while [ ! -e "$BATS_TEST_TMPDIR/held" ]; do sleep 0.05; done
  # Held: a second process does not get it, and does not wait for it.
  run bash "$holder"
  [ "$status" -eq 7 ]
  # Another instance has its own lock.
  XINIT_INSTANCE=wiki2 run xinit_lock_acquire
  [ "$status" -eq 0 ]
  echo go >"$BATS_TEST_TMPDIR/release"
  wait
  run bash "$holder"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$XINIT_RUN_DIR/default")" = 700 ]
}

@test "state: the clock can be set for the tests, and only to a time" {
  [ "$(xinit_now)" = "$NOW" ]
  XINIT_TEST_NOW="soon" run xinit_now
  [ "$status" -eq 3 ]
  unset XINIT_TEST_NOW
  [ "$(xinit_now)" -gt 1700000000 ]
}
