#!/usr/bin/env bats
# `xinit watch` on a real installation, run by root. Scenarios S-WATCH-* of docs/TESTING.md.

load helpers

setup_file() {
  wait_healthy 300
  install_fault_page
  # Earlier test files leave out-of-memory errors in the journal: look no further back than now.
  XT_START="$(date +%s)"
  export XT_START
}

setup() {
  xinit_conf
  in_env rm -rf /var/lib/xinit /run/xinit
}

teardown() {
  heal_all
  in_env rm -rf /var/lib/xinit /run/xinit
  wait_healthy 300
}

# watch [args...]: `xinit watch --format json`, with what makes the result depend on XWiki alone:
#   - the host's disk may be nearly full: thresholds that it passes;
#   - a failure counts at once, even if the JVM just started;
#   - a frozen JVM is given up on after 5 seconds;
#   - the journal is searched back to the start of this file only.
watch() {
  xinit watch --format json -o DISK_WARN=1 -o DISK_CRIT=0 -o STARTUP_GRACE=0 -o HTTP_TIMEOUT=5 \
    -o "OOM_WINDOW=$(($(date +%s) - XT_START + 1))" "$@"
}

# watch_broken [args...]: the same, on a page that always answers 503 while the JVM is fine.
watch_broken() {
  watch -o "HTTP_PATH=$(fault_url 'action=status&code=503')" "$@"
}

# w <field>: a field of the "watch" member of the output.
w() { json "d['watch']['$1']"; }

@test "S-WATCH-07 watch: a healthy XWiki is left alone" {
  local pid
  pid="$(jvm_pid)"
  watch
  [ "$status" -eq 0 ]
  [ "$(w action)" = none ]
  [ "$(w reason)" = healthy ]
  watch
  [ "$(w reason)" = healthy ]
  [ "$(w failures)" = 0 ]
  [ "$(jvm_pid)" = "$pid" ]
  [ "$(in_env stat -c '%U %a' /var/lib/xinit/default/state)" = "root 600" ]
}

@test "S-WATCH-01 watch: a frozen JVM is restarted once, at the third failed run" {
  local pid
  pid="$(jvm_pid)"
  fault_freeze_jvm
  watch
  [ "$status" -eq 0 ]
  [ "$(w action)" = none ]
  [ "$(w reason)" = counting ]
  [ "$(w failed_checks)" = "['http']" ]
  watch
  [ "$(w reason)" = counting ]
  [ "$(w failures)" = 2 ]
  [ "$(jvm_pid)" = "$pid" ]
  watch
  [ "$status" -eq 0 ]
  [ "$(w action)" = restart ]
  [ "$(w reason)" = threshold ]
  [ "$(w restart_ok)" = True ]
  wait_healthy 300
  [ "$(jvm_pid)" != "$pid" ]
  in_env_sh "journalctl -t xinit --since '-5min' -o cat | grep -q 'notification (restart)'"
}

@test "S-WATCH-08 watch: the thread dump of a JVM that still runs is stored before the restart" {
  local dump
  watch_broken -o RESTART_AFTER=1
  [ "$status" -eq 0 ]
  [ "$(w action)" = restart ]
  dump="$(w thread_dump)"
  [[ "$dump" == /var/lib/xinit/default/threaddump-*.txt ]]
  [ "$(in_env stat -c '%U %a' "$dump")" = "root 600" ]
  in_env grep -q "Full thread dump" "$dump"
  # Taken before the restart: it shows the threads of a running XWiki.
  in_env grep -q "http-nio\|qtp" "$dump"
}

@test "S-WATCH-02 watch: during the cooldown there is no second restart" {
  local pid
  watch_broken -o RESTART_AFTER=1
  [ "$(w action)" = restart ]
  wait_healthy 300
  pid="$(jvm_pid)"
  watch_broken -o RESTART_AFTER=1
  [ "$status" -eq 0 ]
  [ "$(w action)" = none ]
  [ "$(w reason)" = cooldown ]
  [ "$(w cooldown_remaining_seconds)" -gt 0 ]
  [ "$(jvm_pid)" = "$pid" ]
}

@test "S-WATCH-03 watch: during a maintenance failures are counted, and nothing is restarted" {
  local pid
  pid="$(jvm_pid)"
  xinit maint on --for 10m
  watch_broken -o RESTART_AFTER=1
  [ "$status" -eq 0 ]
  [ "$(w action)" = none ]
  [ "$(w reason)" = maintenance ]
  [ "$(w failures)" = 1 ]
  [ "$(jvm_pid)" = "$pid" ]
}

@test "S-WATCH-04 watch: a maintenance that has ended by itself no longer holds a restart back" {
  xinit maint on --for 3s
  watch_broken -o RESTART_AFTER=1 --dry-run
  [ "$(w reason)" = maintenance ]
  sleep 4
  watch_broken -o RESTART_AFTER=1 --dry-run
  [ "$(w action)" = restart ]
  [ "$(w dry_run)" = True ]
}

@test "S-WATCH-05 watch: when restarts do not help, it stops after MAX_RESTARTS and says so" {
  local restarts=0 pid
  for _ in $(seq 40); do
    watch_broken -o RESTART_AFTER=1 -o COOLDOWN=0 -o MAX_RESTARTS=2
    [ "$status" -eq 0 ]
    [ "$(w action)" != restart ] || restarts=$((restarts + 1))
    [ "$(w reason)" != flapping ] || break
    sleep 3
  done
  [ "$(w reason)" = flapping ]
  [ "$restarts" -eq 2 ]
  wait_healthy 300
  pid="$(jvm_pid)"
  watch_broken -o RESTART_AFTER=1 -o COOLDOWN=0 -o MAX_RESTARTS=2
  [ "$(w action)" = none ]
  [ "$(w reason)" = flapping ]
  [ "$(jvm_pid)" = "$pid" ]
  [ "$(in_env_sh "journalctl -t xinit --since '-10min' -o cat | grep -c 'notification (flapping)'")" = 1 ]
}

@test "S-WATCH-06 watch: of two runs at once, one ends on the lock" {
  in_env_sh "mkdir -p /run/xinit/default && exec flock /run/xinit/default/lock sleep 8" &
  # Wait until the lock is held.
  for _ in $(seq 50); do
    in_env_sh "[ -e /run/xinit/default/lock ] && ! flock -n /run/xinit/default/lock true" && break
    sleep 0.2
  done
  watch
  [ "$status" -eq 0 ]
  [ "$(w action)" = none ]
  [ "$(w reason)" = locked ]
  [ "$(json 'len(d["results"])')" = 0 ]
  wait
  watch
  [ "$(w reason)" = healthy ]
}
