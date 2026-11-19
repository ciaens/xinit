#!/usr/bin/env bats
# `xinit check` on a real installation, healthy and with faults. Scenarios S-CHECK, S-PROC,
# S-HTTP, S-REST, S-DB, S-DISK, S-OOM and S-FMT of docs/TESTING.md.

load helpers

setup_file() {
  wait_healthy 300
  install_fault_page
  # Earlier test files leave out-of-memory kills in the journal: look no further back than now.
  XT_START="$(date +%s)"
  export XT_START
}

setup() {
  xinit_conf
}

teardown() {
  heal_all
  wait_healthy 300
}

# check [args...]: `xinit check --format json`, with what makes the result depend on XWiki alone:
#   - the host's disk may be nearly full: thresholds that it passes;
#   - a failure counts at once, even if the JVM just started;
#   - the journal is searched back to the start of this file only.
check() {
  xinit check --format json -o DISK_WARN=1 -o DISK_CRIT=0 -o STARTUP_GRACE=0 \
    -o "OOM_WINDOW=$(($(date +%s) - XT_START + 1))" "$@"
}

of() {
  case "$2" in
    metrics.*) json "[r for r in d['results'] if r['check'] == '$1'][0]['metrics'].get('${2#metrics.}')" ;;
    *) json "[r for r in d['results'] if r['check'] == '$1'][0]['$2']" ;;
  esac
}
# expect <check> <status> <reason>
expect() {
  local got
  got="$(of "$1" status) $(of "$1" reason)"
  [ "$got" = "$2 $3" ] || { echo "$1: expected '$2 $3', got '$got': $(of "$1" message)"; return 1; }
}

# db_credentials [password]: write the credentials files of the db check, with the password of
# hibernate.cfg.xml unless another one is given.
db_credentials() {
  local password="${1:-}"
  [ -n "$password" ] || password="$(in_env cat "$XT_CONFIG_DIR/hibernate.cfg.xml" | python3 -c '
import re, sys
text = re.sub(r"<!--.*?-->", "", sys.stdin.read(), flags=re.S)
print(re.findall(r"connection\.password\">([^<]*)<", text)[0])')"
  [ -n "$password" ]
  printf '*:*:*:xwiki:%s\n' "$password" | in_env_sh "mkdir -p $XT_XINIT_CONF_DIR/credentials &&
    umask 077 && cat > $XT_XINIT_CONF_DIR/credentials/default.pgpass"
  printf '[client]\npassword=%s\n' "$password" | in_env_sh "umask 077 &&
    cat > $XT_XINIT_CONF_DIR/credentials/default.my.cnf"
}

@test "S-CHECK-00 a healthy instance is ok on every check, on a read-only file system" {
  check
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(json "d['status']")" = ok ]
  [ "$(json "' '.join(r['check'] for r in d['results'])")" = "process http rest oom db disk" ]
  [ "$(json "' '.join(sorted(set(r['status'] for r in d['results'])))")" = ok ]
  expect process ok running
  [ "$(of process metrics.uptime_seconds)" -gt 0 ]

  # Nothing is written: the same run with every file system read-only, /tmp included.
  run in_env systemd-run --quiet --wait --pipe -p ProtectSystem=strict -p ProtectHome=read-only \
    -E "XINIT_CONF_DIR=$XT_XINIT_CONF_DIR" /src/xinit/bin/xinit check --format json \
    -o DISK_WARN=1 -o DISK_CRIT=0 -o "OOM_WINDOW=$(($(date +%s) - XT_START + 1))"
  [ "$status" -eq 0 ]
  [ "$(json "d['status']")" = ok ]
  run in_env systemd-run --quiet --wait --pipe -p ProtectSystem=strict -p ProtectHome=read-only \
    -E "XINIT_CONF_DIR=$XT_XINIT_CONF_DIR" /src/xinit/bin/xinit layout --format json
  [ "$status" -eq 0 ]
  # And xinit left nothing of its own behind.
  run in_env_sh "ls -d /var/lib/xinit /run/xinit /etc/xinit 2>/dev/null"
  [ -z "$output" ]
}

@test "S-FMT-01 the json format parses; the nagios format is a plugin output" {
  check
  [ "$(json "sorted(d.keys())")" = "['instance', 'results', 'status']" ]
  [ "$(json "sorted(d['results'][0].keys())")" = "['check', 'message', 'metrics', 'reason', 'status']" ]
  xinit check --format nagios -o DISK_WARN=1 -o DISK_CRIT=0 -o "OOM_WINDOW=$(($(date +%s) - XT_START + 1))"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^XINIT\ OK\ -\ 6\ checks\ passed\ \|\ [a-z_]+=[0-9.]+ ]]
  xinit check --format nagios -o DISK_WARN=100 http disk
  [ "$status" -eq 1 ]
  [[ "${lines[0]}" == "XINIT WARNING - disk: "* ]]
  xinit check --format nagios -o DISK_CRIT=100 http disk
  [ "$status" -eq 2 ]
  [[ "${lines[0]}" == "XINIT CRITICAL - disk: "* ]]
}

@test "S-REST-01 the REST API answers with the installed version" {
  check rest
  [ "$status" -eq 0 ]
  expect rest ok ok
  [[ "$(of rest message)" == *"$(rest_version)"* ]]
}

@test "S-DISK-01 free space below DISK_WARN is warn, below DISK_CRIT is crit" {
  xinit check --format json disk -o DISK_WARN=100 -o DISK_CRIT=0
  [ "$status" -eq 1 ]
  expect disk warn low
  [ "$(of disk metrics.free_percent)" -lt 100 ]
  [ "$(of disk metrics.free_bytes)" -gt 0 ]
  xinit check --format json disk -o DISK_CRIT=100
  [ "$status" -eq 2 ]
  expect disk crit low
}

@test "S-HTTP-02 an unexpected status code is crit, with the code" {
  check http -o "HTTP_PATH=$(fault_url 'action=status&code=503')"
  [ "$status" -eq 2 ]
  expect http crit status
  [ "$(of http metrics.code)" = 503 ]
}

@test "S-HTTP-03 an answer slower than HTTP_SLOW is warn, with the duration" {
  check http -o "HTTP_PATH=$(fault_url 'action=sleep&ms=3000')" -o HTTP_SLOW=2 -o HTTP_TIMEOUT=20
  [ "$status" -eq 1 ]
  expect http warn slow
  [ "$(json "[r for r in d['results'] if r['check'] == 'http'][0]['metrics']['time_seconds'] >= 3")" = True ]
}

@test "S-HTTP-04 the redirect of a fresh installation is warn, Distribution Wizard pending" {
  skip "needs an installation that was never set up: covered by the unit test, from a real capture"
}

@test "S-HTTP-06 a host name that does not resolve is unknown, not crit" {
  check http process -o BASE_URL=http://no-such-host.invalid/xwiki
  [ "$status" -eq 3 ]
  expect http unknown dns
  expect process ok running
}

@test "S-HTTP-07 credentials come from a netrc file, and are not on the command line" {
  local admin=/bin/admin/XWiki/XWikiPreferences
  # A guest is sent to the login page.
  check http -o "HTTP_PATH=$admin"
  expect http crit redirect
  in_env_sh "mkdir -p $XT_XINIT_CONF_DIR/credentials && umask 077 &&
    echo 'machine localhost login Admin password admin' > $XT_XINIT_CONF_DIR/credentials/default.netrc"
  check http -o "HTTP_PATH=$admin"
  [ "$status" -eq 0 ]
  expect http ok ok
  [ "$(of http metrics.code)" = 200 ]
  # While a slow request runs, its command line shows the file, not what is in it.
  check http -o "HTTP_PATH=$(fault_url 'action=sleep&ms=4000')" -o HTTP_TIMEOUT=20 &
  sleep 2
  run in_env_sh "ps -eo args | grep '[c]url '"
  wait
  [[ "$output" == *"--netrc-file $XT_XINIT_CONF_DIR/credentials/default.netrc"* ]]
  [[ "$output" != *"-u "* && "$output" != *"--user"* && "${output,,}" != *"password"* ]]
  [[ "${output,,}" != *admin* ]]
}

@test "S-DB-02 without credentials the port is checked; with them, a login and a query" {
  check db http
  [ "$status" -eq 0 ]
  expect db ok port-only
  expect http ok ok
  db_credentials
  check db
  [ "$status" -eq 0 ]
  expect db ok ok
  db_credentials wrong-password
  check db
  [ "$status" -eq 2 ]
  expect db crit login-failed
  [[ "$output$stderr" != *wrong-password* ]]
}

@test "S-DB-01 a database that is down is crit" {
  db_credentials
  fault_stop_db
  check db
  [ "$status" -eq 2 ]
  expect db crit refused
  heal_stop_db
  check db
  expect db ok ok
}

@test "S-OOM-04 a user who may not read the journal gets unknown, not ok" {
  run --separate-stderr docker exec -u nobody -e "XINIT_CONF_DIR=$XT_XINIT_CONF_DIR" \
    "$XT_CONTAINER" /src/xinit/bin/xinit check --format json oom
  [ "$status" -eq 3 ]
  expect oom unknown no-access
}

@test "S-PROC-03 a frozen JVM: the process is running, but http gets no answer" {
  fault_freeze_jvm
  check process http -o HTTP_TIMEOUT=5
  [ "$status" -eq 2 ]
  expect process ok running
  expect http crit timeout
  heal_freeze_jvm
  check process http
  [ "$status" -eq 0 ]
}

@test "S-PROC-01 S-HTTP-01 a stopped unit: process is crit, http is refused" {
  fault_stop_unit
  check process http rest
  [ "$status" -eq 2 ]
  expect process crit stopped
  expect http crit refused
  expect rest crit refused
  [ "$(of http metrics.code)" = 0 ]
}

@test "S-HTTP-05 right after a restart, http is warn until XWiki answers, never crit" {
  local seen="" end=$((SECONDS + 300)) state
  in_env systemctl restart "$XT_UNIT"
  while ((SECONDS < end)); do
    # The default STARTUP_GRACE applies here.
    xinit check --format json http
    state="$(of http status):$(of http reason)"
    [[ " $seen " == *" $state "* ]] || seen+=" $state"
    [ "$state" = ok:ok ] && break
    sleep 1
  done
  echo "states seen:$seen"
  [ "$state" = ok:ok ]
  [[ "$seen" != *crit* && "$seen" != *unknown* ]]
  [[ "$seen" == *warn:starting* || "$seen" == *warn:initializing* ]]
}

@test "S-OOM-01 S-OOM-02 a heap OutOfMemoryError is crit until the JVM is restarted" {
  fault_small_heap 768m
  wait_healthy 300
  install_fault_page
  provoke_heap_oom
  check oom
  [ "$status" -eq 2 ]
  expect oom crit heap
  [ "$(of oom metrics.heap_errors)" -ge 1 ]
  # S-OOM-02: the restart starts a new JVM, which has not run out of memory.
  heal_small_heap
  wait_healthy 300
  check oom
  [ "$status" -eq 0 ]
  expect oom ok ok
  [ "$(of oom metrics.heap_errors)" = 0 ]
}

@test "S-OOM-03 a kill by the kernel's OOM killer is warn" {
  local before outcome
  fault_cgroup_memory 1200M
  wait_healthy 300
  install_fault_page
  before="$(jvm_pid)"
  for _ in $(seq 1 15); do XT_HTTP_TIMEOUT=20 http_code "$(fault_url 'action=hog&mb=100')" >/dev/null; done
  outcome="$(after_kill "$before")"
  in_env systemctl show -p ActiveState,SubState,Result,NRestarts "$XT_UNIT" >&2
  if [ "$outcome" = failed ]; then
    # cgroup v2: systemd knows of the kill, and the unit of the package is left down.
    check oom process
    echo "$output" >&2
    [ "$status" -eq 2 ]
    expect oom warn kernel
    [ "$(of oom metrics.kernel_kills)" -ge 1 ]
    expect process crit failed
  else
    # cgroup v1: systemd saw a process killed by a signal, and started XWiki again.
    wait_healthy 300
    check oom process
    echo "$output" >&2
    [ "$status" -eq 1 ]
    expect oom warn kernel
    [ "$(of oom metrics.kernel_kills)" -ge 1 ]
    expect process ok running
  fi
}
