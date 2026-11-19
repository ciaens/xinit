#!/usr/bin/env bats
# `xinit setup` on a real host: the units it installs, and what they do. Scenarios S-SETUP,
# S-PROC-02, S-WARMUP, S-SEC and S-MULTI of docs/TESTING.md.

load helpers

# The installed units read the real configuration, not the one of the other test files.
# shellcheck disable=SC2034  # read by the helpers
XT_XINIT_CONF_DIR=/etc/xinit
STUB_DIR=/opt/xinit-test-stub

setup_file() {
  wait_healthy 300
  install_fault_page
  XT_START="$(date +%s)"
  export XT_START
}

setup() {
  in_env rm -rf /var/lib/xinit /run/xinit
}

teardown() {
  xinit -i default setup --undo
  xinit -i stub setup --undo
  heal_all
  in_env_sh "systemctl stop xinit-stub.service 2>/dev/null
    rm -rf /etc/systemd/system/xinit-stub.service $STUB_DIR /var/lib/xinit /run/xinit /etc/xinit
    rm -f /root/xinit-test-password
    systemctl daemon-reload; systemctl reset-failed 2>/dev/null; true"
  # A JVM started with the options of a test is started again without them.
  if in_env_sh "tr '\\0' '\\n' </proc/\$(systemctl show -p MainPID --value $XT_UNIT)/environ |
    grep -q '^JDK_JAVA_OPTIONS=.*xinit.test'"; then
    in_env systemctl restart "$XT_UNIT"
  fi
  wait_healthy 300
}

# conf [lines...]: the configuration, with what makes the checks depend on XWiki alone (see
# 50-watch.bats). Before `xinit setup`: it starts /etc/xinit from scratch.
conf() {
  xinit_conf DISK_WARN=1 DISK_CRIT=0 STARTUP_GRACE=0 HTTP_TIMEOUT=5 \
    "OOM_WINDOW=$(($(date +%s) - XT_START + 1))" "$@"
}

# stored <KEY> [instance]: a value of the state of the periodic job.
stored() { in_env_sh "sed -n 's/^$1=//p' /var/lib/xinit/${2:-default}/state 2>/dev/null"; }

# wait_for <seconds> <command...>: until the command succeeds.
wait_for() {
  local end=$((SECONDS + $1))
  shift
  while ((SECONDS < end)); do
    "$@" && return 0
    sleep 1
  done
  echo "wait_for: never true: $*" >&2
  return 1
}

has_run() { [ -n "$(stored LAST_RUN "${1:-default}")" ]; }
has_restarted() { [ "$(stored LAST_RESTART "${1:-default}")" != 0 ] && has_run "${1:-default}"; }
# logged <since epoch> <text>: xinit logged this since then.
logged() { in_env_sh "journalctl -t xinit --since @$1 -o cat | grep -qF -- '$2'"; }
count_logged() { in_env_sh "journalctl -t xinit --since @$1 -o cat | grep -cF -- '$2' || true"; }
# as_job <command...>: run a command as the user of the periodic job.
as_job() { in_env setpriv --reuid=xinit --regid=xinit --init-groups "$@"; }

@test "S-SETUP-01 setup then setup --undo leave the unit of XWiki and the host as they were" {
  local before
  before="$(in_env systemctl cat "$XT_UNIT")"
  conf
  xinit setup --dry-run --format json
  [ "$status" -eq 0 ]
  [ "$(json 'd["dry_run"]')" = True ]
  run ! in_env test -e /etc/xinit/setup
  [ "$(in_env systemctl cat "$XT_UNIT")" = "$before" ]

  xinit setup --format json
  [ "$status" -eq 0 ]
  [ "$(json 'sorted(set(f["change"] for f in d["files"]))')" = "['create']" ]
  [ "$(in_env systemctl cat "$XT_UNIT")" != "$before" ]
  [ "$(in_env systemctl is-active "xinit-watch@default.timer")" = active ]
  [ "$(in_env systemctl is-active "xinit-act@default.path")" = active ]
  [ "$(in_env stat -c '%U %a' /etc/xinit/setup/default.manifest)" = "root 644" ]

  xinit setup --undo --format json
  [ "$status" -eq 0 ]
  [ "$(in_env systemctl cat "$XT_UNIT")" = "$before" ]
  [ -z "$(in_env_sh "ls /etc/systemd/system | grep -i xinit || true")" ]
  no_unit_left() { [ -z "$(in_env_sh "systemctl list-units --all --no-legend 'xinit-*' || true")" ]; }
  wait_for 20 no_unit_left
  run ! in_env test -e /etc/xinit/setup/default.manifest
  run ! in_env test -e /etc/sysusers.d/xinit.conf
}

@test "S-SETUP-03 the periodic job runs every minute as its own user, and sees what root sees" {
  local first results
  conf
  # A run by root before the setup leaves nothing that keeps the job out.
  xinit watch --format json
  [ "$status" -eq 0 ]
  [ "$(in_env stat -c '%U %a' /var/lib/xinit/default/state)" = "root 600" ]
  xinit setup --format json
  [ "$status" -eq 0 ]
  # The timer starts it at once, or two minutes after the start of the host.
  in_env rm -f /var/lib/xinit/default/state
  wait_for 180 has_run
  first="$(stored LAST_RUN)"
  [ "$(in_env systemctl show -p User --value xinit-watch@default.service)" = xinit ]
  [ "$(in_env stat -c '%U %a' /var/lib/xinit)" = "xinit 700" ]
  [ "$(in_env stat -c '%U %a' /var/lib/xinit/default/state)" = "xinit 600" ]
  [ "$(in_env stat -c '%U %a' /run/xinit/default)" = "xinit 700" ]
  # Each check could tell: the URL was found, the journal was read, the database was logged into.
  results=" $(stored RESULTS) "
  [[ "$results" == *" process:ok:running "* ]]
  [[ "$results" == *" http:ok:ok "* ]]
  [[ "$results" == *" rest:ok:ok "* ]]
  [[ "$results" == *" oom:ok:ok "* ]]
  [[ "$results" == *" db:ok:ok "* ]]
  [ "$(stored FAILURES)" = 0 ]
  # And again a minute later.
  later() { [ "$(stored LAST_RUN)" != "$first" ]; }
  wait_for 90 later
  # root's own commands still work, as the owner of the state.
  xinit maint on --for 5m --format json
  [ "$status" -eq 0 ]
  [ "$(in_env stat -c '%U %a' /var/lib/xinit/default/maintenance)" = "xinit 600" ]
  xinit watch --format json
  [ "$status" -eq 3 ]
  xinit watch --dry-run --format json
  [ "$status" -eq 0 ]
}

@test "S-SETUP-03 the job gets XWiki restarted through the path unit, and can do nothing else" {
  local pid start dump
  pid="$(jvm_pid)"
  start="$(date +%s)"
  conf "HTTP_PATH=$(fault_url 'action=status&code=503')" RESTART_AFTER=1
  xinit setup --format json
  [ "$status" -eq 0 ]
  # The first run finds the page failing, and has XWiki restarted.
  wait_for 210 has_restarted
  wait_for 60 logged "$start" "restarting $XT_UNIT, on request"
  logged "$start" "for a thread dump, on request"
  wait_healthy 300
  [ "$(jvm_pid)" != "$pid" ]
  dump="$(in_env_sh "ls /var/lib/xinit/default/threaddump-*.txt")"
  [ "$(in_env stat -c '%U %a' "$dump")" = "xinit 600" ]
  in_env grep -q "Full thread dump" "$dump"

  # The user of the job cannot restart a unit itself, this one or another.
  pid="$(jvm_pid)"
  run as_job systemctl restart "$XT_UNIT"
  [ "$status" -ne 0 ]
  run as_job systemctl restart "$XT_DB_UNIT"
  [ "$status" -ne 0 ]
  # A request by another name is not one.
  as_job touch /run/xinit/default/request-stop
  sleep 3
  in_env test -e /run/xinit/default/request-stop
  [ "$(jvm_pid)" = "$pid" ]
  # What a request file holds is not read.
  in_env systemctl stop xinit-watch@default.timer
  start="$(date +%s)"
  as_job sh -c "echo '$XT_DB_UNIT' > /run/xinit/default/request-restart"
  wait_for 60 logged "$start" "restarting $XT_UNIT, on request"
  [ "$(in_env systemctl is-active "$XT_DB_UNIT")" = active ]
}

@test "S-PROC-02 a killed JVM is restarted by systemd, and the crash is notified once" {
  local pid start
  conf
  xinit setup --format json
  [ "$status" -eq 0 ]
  wait_for 180 has_run
  pid="$(jvm_pid)"
  start="$(date +%s)"
  fault_kill_jvm
  restarted() { local now; now="$(jvm_pid)"; [ -n "$now" ] && [ "$now" != "$pid" ]; }
  wait_for 90 restarted
  wait_for 30 logged "$start" "notification (crash): $XT_UNIT stopped unexpectedly"
  wait_healthy 300
  [ "$(count_logged "$start" "notification (crash)")" = 1 ]
  # systemd did it: xinit watch restarted nothing.
  [ "$(stored LAST_RESTART)" = 0 ]
  # A restart someone asks for is not a crash.
  in_env systemctl restart "$XT_UNIT"
  wait_healthy 300
  [ "$(count_logged "$start" "notification (crash)")" = 1 ]
}

@test "S-PROC-04 once set up, an XWiki that the kernel kills for memory is started again and notified" {
  local before start
  conf
  xinit setup --format json
  [ "$status" -eq 0 ]
  # The job would restart XWiki too, later: here systemd has to.
  in_env systemctl stop xinit-watch@default.timer
  fault_cgroup_memory 1200M
  wait_healthy 300
  install_fault_page
  before="$(jvm_pid)"
  start="$(date +%s)"
  for _ in $(seq 1 15); do XT_HTTP_TIMEOUT=20 http_code "$(fault_url 'action=hog&mb=100')" >/dev/null; done
  # With the unit of the package alone, cgroup v2 leaves it down (S-OOM-03).
  run after_kill "$before" 180
  in_env systemctl show -p ActiveState,SubState,Result,NRestarts "$XT_UNIT" >&2
  [ "$output" = restarted ]
  wait_for 30 logged "$start" "notification (crash): $XT_UNIT stopped unexpectedly"
  wait_healthy 300
}

@test "S-WARMUP-01 the first requests are made after each start, to every URL" {
  local start
  conf "WARMUP_URLS=/bin/view/Main/ /bin/view/Sandbox/"
  xinit setup --format json
  [ "$status" -eq 0 ]
  start="$(date +%s)"
  in_env systemctl restart "$XT_UNIT"
  wait_for 300 logged "$start" "warm-up: 2 of 2 URLs answered"
  # Also when systemd starts it again after a crash.
  start="$(date +%s)"
  fault_kill_jvm
  wait_for 300 logged "$start" "warm-up: 2 of 2 URLs answered"
}

@test "S-SETUP-02 JVM_OPTS_APPEND reaches the JVM, on top of the options it already had" {
  local before start
  before="$(in_env_sh "tr '\\0' ' ' </proc/$(jvm_pid)/cmdline")"
  conf "JVM_OPTS_APPEND=-Dxinit.test=present"
  xinit setup --format json
  [ "$status" -eq 0 ]
  [[ "$(json 'd["warnings"]')" == *"applies at the next start"* ]]
  start="$(date +%s)"
  in_env systemctl restart "$XT_UNIT"
  wait_healthy 300
  in_env_sh "tr '\\0' '\\n' </proc/$(jvm_pid)/environ | grep -qxF 'JDK_JAVA_OPTIONS=-Dxinit.test=present'"
  # The JVM says so itself when it takes them.
  in_env_sh "journalctl -u $XT_UNIT --since @$start -o cat | grep -qF 'Picked up JDK_JAVA_OPTIONS: -Dxinit.test=present'"
  [ "$(in_env_sh "tr '\\0' ' ' </proc/$(jvm_pid)/cmdline")" = "$before" ]
}

@test "S-SEC-01 nothing xinit wrote lets another user read a secret, and no password is on a command line" {
  local password seen=0
  conf
  xinit setup --format json
  [ "$status" -eq 0 ]
  wait_for 180 has_run
  # What holds a secret, or the state, is for its owner only.
  [ -z "$(in_env_sh "find /var/lib/xinit /run/xinit/* /etc/xinit/credentials -perm /o+rwx")" ]
  [ "$(in_env_sh "stat -c '%U %a' /etc/xinit/credentials/default.*")" = "xinit 600" ]

  password="$(in_env cat "$XT_CONFIG_DIR/hibernate.cfg.xml" | python3 -c '
import re, sys
text = re.sub(r"<!--.*?-->", "", sys.stdin.read(), flags=re.S)
print(re.findall(r"connection\.password\">([^<]*)<", text)[0])')"
  [ "${#password}" -ge 8 ] ||
    skip "the database password of this variant is too common a word to search for"
  # shellcheck disable=SC2154  # $stderr is set by bats' run
  [[ "$output$stderr" != *"$password"* ]]
  # In a file, for grep -f: on grep's own command line, the test would find itself.
  printf '%s\n' "$password" | in_env_sh "umask 077 && cat > /root/xinit-test-password"
  # Run the job a few more times, looking at every command line meanwhile.
  for _ in 1 2 3; do
    in_env systemctl start --no-block xinit-watch@default.service
    for _ in $(seq 20); do
      if in_env_sh "cat /proc/[0-9]*/cmdline 2>/dev/null | tr '\\0' ' ' | grep -qFf /root/xinit-test-password"; then
        seen=1
      fi
    done
  done
  [ "$seen" -eq 0 ]
  # The password is in the credentials file, and nowhere else xinit wrote.
  [ -z "$(in_env_sh "grep -rlFf /root/xinit-test-password /etc/systemd/system /etc/sysusers.d /etc/xinit/setup /var/lib/xinit /run/xinit || true")" ]
  [ "$(in_env_sh "journalctl -t xinit --since @$XT_START -o cat | grep -cFf /root/xinit-test-password || true")" = 0 ]
  in_env_sh "grep -qFf /root/xinit-test-password /etc/xinit/credentials/default.*"
}

@test "S-MULTI-01 two instances on one host each have their job, their state and their restarts" {
  local pid stub_pid start
  # The second "wiki" is a small HTTP service, whose process is named java as a JVM is.
  in_env_sh "mkdir -p $STUB_DIR/webapp/WEB-INF && cp /usr/bin/perl $STUB_DIR/java
    printf '%s\n' '[Service]' \
      'ExecStart=$STUB_DIR/java /src/xinit/tests/integration/stub-wiki.pl 8099 $STUB_DIR/broken' \
      > /etc/systemd/system/xinit-stub.service
    systemctl daemon-reload && systemctl start xinit-stub.service"
  conf
  in_env_sh "printf '%s\n' PROFILE=war UNIT=xinit-stub.service WEBAPP_DIR=$STUB_DIR/webapp \
    BASE_URL=http://localhost:8099/stub 'CHECKS=process http' 'ACT_ON=process http' \
    RESTART_AFTER=1 > /etc/xinit/instances/stub.conf"
  xinit -i default setup --format json
  [ "$status" -eq 0 ]
  xinit -i stub setup --format json
  [ "$status" -eq 0 ]
  wait_for 180 has_run default
  wait_for 180 has_run stub
  [[ " $(stored RESULTS stub) " == *" http:ok:ok "* ]]

  # The stub fails: it alone is restarted.
  pid="$(jvm_pid)"
  stub_pid="$(in_env systemctl show -p MainPID --value xinit-stub.service)"
  start="$(date +%s)"
  in_env touch "$STUB_DIR/broken"
  wait_for 210 has_restarted stub
  wait_for 60 logged "$start" "instance stub: restarting xinit-stub.service, on request"
  [ "$(in_env systemctl show -p MainPID --value xinit-stub.service)" != "$stub_pid" ]
  [ "$(jvm_pid)" = "$pid" ]
  [ "$(stored LAST_RESTART default)" = 0 ]
  [ "$(stored FAILURES default)" = 0 ]
  [ "$(count_logged "$start" "instance default: restarting")" = 0 ]

  # A maintenance of one is not a maintenance of the other.
  xinit -i default maint on --format json
  xinit -i stub maint status --format json
  [ "$(json 'd["maintenance"]')" = False ]
  # Undoing one leaves the other running.
  xinit -i stub setup --undo --format json
  [ "$status" -eq 0 ]
  [ "$(in_env systemctl is-active xinit-watch@default.timer)" = active ]
  in_env test -e /etc/sysusers.d/xinit.conf
}
