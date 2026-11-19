#!/usr/bin/env bats
# `xinit report` on a real installation, run by root. Scenarios S-REPORT-* of docs/TESTING.md.

load helpers

setup_file() {
  wait_healthy 300
  install_fault_page
  XT_START="$(date +%s)"
  export XT_START
}

setup() {
  xinit_conf
  db_credentials
  in_env rm -rf /var/lib/xinit /run/xinit
}

teardown() {
  heal_all
  in_env rm -rf /var/lib/xinit /run/xinit /root/xinit-test-report
  wait_healthy 300
}

# report [args...]: `xinit report --format json`, with what makes the checks depend on XWiki
# alone (see 50-watch.bats).
report() {
  xinit report --format json -o DISK_WARN=1 -o DISK_CRIT=0 \
    -o "OOM_WINDOW=$(($(date +%s) - XT_START + 1))" "$@"
}

# slow_requests <count> <query>: that many requests on the fault page, which answers after 30
# seconds. They are left running.
slow_requests() {
  in_env_sh "for i in \$(seq $1); do
      curl -s -o /dev/null --max-time 60 '$XT_BASE_URL$(fault_url "action=sleep&ms=30000$2")' &
    done; sleep 3" >/dev/null 2>&1
}

@test "S-REPORT-01 a report on a healthy XWiki is an archive for root only, with every section" {
  local file name
  report
  [ "$status" -eq 0 ]
  file="$(json 'd["report"]')"
  [[ "$file" == /var/lib/xinit/default/reports/report-*.tar.gz ]]
  [ "$(in_env stat -c '%U %a' "$file")" = "root 600" ]
  [ "$(in_env stat -c '%U %a' /var/lib/xinit/default/reports)" = "root 700" ]
  [ "$(json 'd["status"]')" = ok ]
  [ "$(json 'd["oom"]')" = False ]
  [ "$(json 'd["deadlock"]')" = False ]
  for name in layout checks system jvm sockets database disk journal threads; do
    [ "$(json "d['sections']['$name']")" = ok ]
  done
  [ "$(json 'd["sections"].get("dns")')" = "" ]
  unpack "$file"
  for name in summary.txt layout.txt config.txt checks.json system.txt jvm.txt sockets.txt \
    database.txt disk.txt journal.txt threads/dump-1.txt; do
    in_env test -s "$R/$name"
  done
  in_env grep -q "^Database (.*): sessions: [1-9]" "$R/summary.txt"
  in_env grep -q "^JVM: PID $(jvm_pid), running for .* threads, .* MB in memory$" "$R/summary.txt"
  in_env grep -q "^  port .*waiting to be accepted" "$R/summary.txt"
  in_env grep -q "^No deadlock.$" "$R/summary.txt"
  # No text of a query without REPORT_DB_QUERIES.
  run in_env grep -qi "select " "$R/database.txt"
  [ "$status" -ne 0 ]
  [ -z "$(in_env_sh "ls -d /tmp/xinit-report.* 2>/dev/null")" ]
}

@test "S-REPORT-05 without jcmd, three thread dumps are taken with SIGQUIT and read from the journal" {
  local n
  run in_env_sh "command -v jcmd"
  [ "$status" -ne 0 ]
  report
  [ "$status" -eq 0 ]
  [ "$(json 'd["thread_dumps"]')" = 3 ]
  unpack "$(json 'd["report"]')"
  for n in 1 2 3; do
    [ "$(in_env grep -c "^Full thread dump" "$R/threads/dump-$n.txt")" = 1 ]
  done
  in_env grep -q "^Thread dumps: 3 " "$R/summary.txt"
  in_env grep -q "^Java threads by state, in the last dump: RUNNABLE " "$R/summary.txt"
  in_env grep -q "^Threads that used the most CPU between two dumps:$" "$R/summary.txt"
}

@test "S-REPORT-04 the page that 30 requests wait on comes first in the summary" {
  local first
  slow_requests 30 ""
  report
  [ "$status" -eq 0 ]
  unpack "$(json 'd["report"]')"
  first="$(in_env grep -A 1 "^Requests being served, by URL" "$R/summary.txt" | tail -n 1)"
  [[ "$first" == *"/bin/view/XinitTest/Faults" ]]
  # Most of the 30, in each of the three dumps.
  read -r one two three _ <<<"$first"
  [ "$one" -ge 20 ] && [ "$two" -ge 20 ] && [ "$three" -ge 20 ]
  run in_env grep -q "action=sleep" "$R/summary.txt"
  [ "$status" -ne 0 ]
}

@test "S-REPORT-02 the password of the database shows nowhere in a report" {
  local password
  password="$(db_password)"
  [ "${#password}" -ge 8 ] ||
    skip "the database password of this variant is too common a word to search for"
  # A request brings it in the thread dumps: the name of its thread holds its URL.
  slow_requests 2 "&leak=$password"
  # In a file, for grep -f: no command line of this test holds it for long.
  printf '%s\n' "$password" | in_env_sh "umask 077 && cat > /root/xinit-test-password"
  report -o REPORT_DB_QUERIES=yes
  [ "$status" -eq 0 ]
  # shellcheck disable=SC2154  # $stderr is set by bats' run
  [[ "$output$stderr" != *"$password"* ]]
  unpack "$(json 'd["report"]')"
  [ -z "$(in_env_sh "grep -rlFf /root/xinit-test-password $R || true")" ]
  in_env grep -q "leak=<redacted>" "$R/threads/dump-1.txt"
  in_env rm -f /root/xinit-test-password
}

@test "S-REPORT-03 a deadlock is named in the summary" {
  http_code "$(fault_url 'action=deadlock')" >/dev/null
  sleep 2
  report
  [ "$status" -eq 0 ]
  [ "$(json 'd["deadlock"]')" = True ]
  unpack "$(json 'd["report"]')"
  in_env grep -q "^Deadlock, in dump 3:$" "$R/summary.txt"
  in_env grep -q '^  "xinit-deadlock-1":$' "$R/summary.txt"
  # The two threads stay until the JVM ends.
  in_env systemctl restart "$XT_UNIT"
}

@test "S-REPORT-01 a report on a stopped XWiki holds what can still be read" {
  fault_stop_unit
  report
  [ "$status" -eq 0 ]
  [ "$(json 'd["status"]')" = crit ]
  [ "$(json 'd["thread_dumps"]')" = 0 ]
  [ "$(json 'd["sections"]["threads"]')" = "skipped: no JVM is running" ]
  [ "$(json 'd["sections"]["journal"]')" = ok ]
  [ "$(json 'd["sections"]["database"]')" = ok ]
}

@test "S-REPORT-01 --output writes the archive where asked, and the last REPORT_KEEP are kept" {
  report --output /root/xinit-test-report.tar.gz -o THREADDUMP_INTERVAL=1
  [ "$status" -eq 0 ]
  [ "$(in_env stat -c '%U %a' /root/xinit-test-report.tar.gz)" = "root 600" ]
  in_env test ! -e /var/lib/xinit/default/reports
  report --output /root/xinit-test-report.tar.gz
  [ "$status" -eq 3 ]
  in_env rm -f /root/xinit-test-report.tar.gz
  report -o REPORT_KEEP=1 -o THREADDUMP_INTERVAL=1
  sleep 1
  report -o REPORT_KEEP=1 -o THREADDUMP_INTERVAL=1
  [ "$status" -eq 0 ]
  [ "$(in_env_sh "ls /var/lib/xinit/default/reports | wc -l")" = 1 ]
  in_env test -e "$(json 'd["report"]')"
}
