#!/usr/bin/env bats
# The fault library itself: each fault has the symptom the xinit scenarios rely on, and each heal
# brings the instance back. These tests do not involve xinit.

load helpers

setup_file() {
  wait_healthy 300
  install_fault_page
}

teardown() {
  heal_all
}

@test "fault: slow page answers after the requested delay" {
  local start=$SECONDS
  run http_code "$(fault_url 'action=sleep&ms=4000')"
  [ "$output" = 200 ]
  [ $((SECONDS - start)) -ge 4 ]
}

@test "fault: status page answers the requested HTTP code" {
  run http_code "$(fault_url 'action=status&code=503')"
  [ "$output" = 503 ]
}

@test "fault: frozen JVM times out, then answers again once healed" {
  fault_freeze_jvm
  run env XT_HTTP_TIMEOUT=5 bash -c "source '$BATS_TEST_DIRNAME/helpers.bash'; http_code /bin/view/Main/"
  [ "$output" = 000 ]
  heal_freeze_jvm
  wait_healthy 60
}

@test "fault: killed JVM is restarted by systemd (Restart= in the package unit)" {
  local before
  before="$(jvm_pid)"
  fault_kill_jvm
  wait_healthy 300
  [ "$(jvm_pid)" != "$before" ]
}

@test "fault: stopped unit refuses connections" {
  fault_stop_unit
  run http_code /bin/view/Main/
  [ "$output" = 000 ]
  heal_stop_unit
  wait_healthy 300
}

@test "fault: stopped database makes XWiki answer an error" {
  fault_stop_db
  # A page that was never loaded: cached pages are still served without the database.
  run http_code "/bin/view/XinitTest/NotCached$RANDOM$RANDOM"
  [ "$output" != 200 ] && [ "$output" != 404 ]
  heal_stop_db
  wait_healthy 120
}

@test "fault: wrong database password keeps XWiki from starting properly" {
  fault_db_password
  run wait_healthy 120
  [ "$status" -ne 0 ]
  heal_db_password
  wait_healthy 300
}

@test "fault: deadlocked threads show in a thread dump" {
  run http_code "$(fault_url 'action=deadlock')"
  [ "$output" = 200 ]
  sleep 1
  in_env kill -3 "$(jvm_pid)"
  sleep 2
  run in_env_sh "journalctl -u $XT_UNIT --since '-1min' --no-pager | grep -c 'Found one Java-level deadlock'"
  [ "$output" -ge 1 ]
}

@test "fault: small heap + hog raises java.lang.OutOfMemoryError" {
  fault_small_heap 768m
  wait_healthy 300
  install_fault_page
  for _ in 1 2 3 4 5 6 7 8; do http_code "$(fault_url 'action=hog&mb=100')" >/dev/null; done
  run in_env_sh "journalctl -u $XT_UNIT --since '-10min' --no-pager | grep -c 'java.lang.OutOfMemoryError'"
  [ "$output" -ge 1 ]
}

@test "fault: cgroup memory limit gets the JVM killed by the kernel OOM killer" {
  fault_cgroup_memory 1200M
  wait_healthy 300
  install_fault_page
  local before
  before="$(jvm_pid)"
  for _ in $(seq 1 15); do XT_HTTP_TIMEOUT=20 http_code "$(fault_url 'action=hog&mb=100')" >/dev/null; done
  run in_env_sh "journalctl --since '-10min' --no-pager | grep -E 'oom-kill|OOM killer|Out of memory: Killed process'"
  echo "$output" >&2
  [ -n "$output" ]
  wait_healthy 300
  [ "$(jvm_pid)" != "$before" ]
}
