#!/usr/bin/env bats
# `xinit check`: the result model, the output formats, and the process, http, rest and disk
# checks, against stubbed curl, systemctl, ps and df.

load helpers

setup() {
  use_fixture tomcat10-pgsql
}

# check [args...]: run `xinit check --format json`, keeping stderr apart.
check() { run --separate-stderr "$XINIT" check --format json "$@"; }
# of <check> <field>: a field of a check's result. of <check> metrics.<name>: one of its metrics.
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

# ---- the command and its formats

@test "S-CHECK-00 check: a healthy instance is ok on every check, exit 0" {
  check
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(json "d['status']")" = ok ]
  [ "$(json "d['instance']")" = default ]
  [ "$(json "' '.join(r['check'] for r in d['results'])")" = "process http rest disk" ]
  [ "$(json "' '.join(sorted(set(r['status'] for r in d['results'])))")" = ok ]
}

@test "check: the checks to run come from the command line, else from CHECKS" {
  check http disk
  [ "$(json "' '.join(r['check'] for r in d['results'])")" = "http disk" ]
  check -o CHECKS=disk,process
  [ "$(json "' '.join(r['check'] for r in d['results'])")" = "disk process" ]
  check nosuchcheck
  [ "$status" -eq 64 ]
  check --nosuchoption
  [ "$status" -eq 64 ]
  run "$XINIT" check --format yaml
  [ "$status" -eq 64 ]
}

@test "check: the exit code is the worst status: crit over warn over unknown over ok" {
  # warn (slow) + unknown (no PERMDIR) + ok
  FAKE_CURL_TIME=15.000000 check -o PERMDIR=/nowhere
  [ "$status" -eq 1 ]
  [ "$(json "d['status']")" = warn ]
  # unknown + ok
  check -o PERMDIR=/nowhere
  [ "$status" -eq 3 ]
  [ "$(json "d['status']")" = unknown ]
  # crit + warn + unknown
  FAKE_UNIT_STOPPED=1 FAKE_CURL_TIME=15.000000 check -o PERMDIR=/nowhere
  [ "$status" -eq 2 ]
  [ "$(json "d['status']")" = crit ]
}

@test "check: with no installation detected, the result is unknown in the requested format" {
  rm -rf "$XINIT_ROOT"
  mkdir -p "$XINIT_ROOT/cmd"
  : >"$XINIT_ROOT/cmd/dpkg-query.txt"
  check
  [ "$status" -eq 3 ]
  expect layout unknown no-installation
  [ "$(json "len(d['results'])")" -eq 1 ]
}

@test "S-FMT-01 check: the nagios format has the status line, performance data and exit code" {
  run "$XINIT" check --format nagios
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^XINIT\ OK\ -\ 4\ checks\ passed\ \|\  ]]
  # label=value[unit] pairs after the |
  local perfdata="${lines[0]#*| }" item
  for item in $perfdata; do
    [[ "$item" =~ ^[a-z_]+=[0-9.]+(s|%|B)?$ ]] || { echo "bad perfdata: $item"; false; }
  done
  [[ " $perfdata " == *" http_time=0.250000s "* ]]
  [[ " $perfdata " == *" disk_free=50% "* ]]
  [ "${#lines[@]}" -eq 5 ]

  FAKE_UNIT_STOPPED=1 FAKE_CURL_EXIT=7 run "$XINIT" check --format nagios
  [ "$status" -eq 2 ]
  [[ "${lines[0]}" =~ ^XINIT\ CRITICAL\ -\ process:\ .*\;\ http:\ .*\ \|\  ]]
  # One | only: the one before the performance data.
  [ "$(tr -cd '|' <<<"${lines[0]}" | wc -c)" -eq 1 ]

  FAKE_CURL_TIME=15.000000 run "$XINIT" check --format nagios http
  [ "$status" -eq 1 ]
  [[ "${lines[0]}" == "XINIT WARNING - http: "* ]]
  FAKE_CURL_EXIT=6 run "$XINIT" check --format nagios http
  [ "$status" -eq 3 ]
  [[ "${lines[0]}" == "XINIT UNKNOWN - http: "* ]]
}

@test "check: the text format has one line per check and the overall status" {
  run "$XINIT" check
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 5 ]
  [ "${lines[4]}" = "overall: ok" ]
}

# ---- process

@test "process: a running unit with its JVM is ok, with the uptime and the restart count" {
  FAKE_JVM_AGE=4242 check process
  expect process ok running
  [ "$(of process metrics.uptime_seconds)" = 4242 ]
  [ "$(of process metrics.restarts)" = 0 ]
}

@test "S-PROC-01 process: a stopped unit is crit" {
  FAKE_UNIT_STOPPED=1 check process
  [ "$status" -eq 2 ]
  expect process crit stopped
}

@test "process: a failed unit is crit; a starting or stopping one is warn" {
  FAKE_UNIT_STATE=failed check process
  expect process crit failed
  FAKE_UNIT_STATE=activating check process
  expect process warn starting
  [ "$status" -eq 1 ]
  FAKE_UNIT_STATE=deactivating check process
  expect process warn stopping
}

@test "process: a unit that does not exist is unknown" {
  check process -o UNIT=nosuch.service
  [ "$status" -eq 3 ]
  expect process unknown no-unit
}

@test "process: a running unit whose main process is not java is still ok" {
  echo bash >"$XINIT_ROOT/proc/98/comm"
  check process
  expect process ok running
  [ -z "$(of process metrics.uptime_seconds)" ]
}

@test "process: without systemd, PID_FILE tells whether the JVM runs" {
  fake systemctl 'echo "System has not been booted with systemd as init system" >&2; exit 1'
  check process
  expect process unknown no-unit
  mkdir -p "$XINIT_ROOT/run"
  echo 98 >"$XINIT_ROOT/run/xwiki.pid"
  check process -o PID_FILE=/run/xwiki.pid
  expect process ok running
  echo 99 >"$XINIT_ROOT/run/xwiki.pid"
  check process -o PID_FILE=/run/xwiki.pid
  expect process crit stopped
}

# ---- http

@test "http: an expected code in time is ok, with the code and the duration as metrics" {
  check http
  expect http ok ok
  [ "$(of http metrics.code)" = 200 ]
  [ "$(of http metrics.time_seconds)" = 0.25 ]
  # The request: BASE_URL + HTTP_PATH, no redirect followed, a timeout, no password argument.
  local call
  call="$(calls curl)"
  [[ "$call" == *" -- http://localhost:8080/xwiki/bin/view/Main/" ]]
  [[ "$call" == *"--max-time 30"* ]]
  [[ "$call" != *"-L"* && "$call" != *"--location"* && "$call" != *"--insecure"* ]]
  [[ "$call" != *"-u "* && "$call" != *"--user "* ]]
}

@test "http: HTTP_PATH, HTTP_EXPECT and HTTP_TIMEOUT are used" {
  FAKE_CURL_CODE=401 check http -o HTTP_PATH=/bin/login/XWiki/XWikiLogin -o "HTTP_EXPECT=200, 401" \
    -o HTTP_TIMEOUT=7
  expect http ok ok
  [[ "$(calls curl)" == *"--max-time 7 "*" -- http://localhost:8080/xwiki/bin/login/XWiki/XWikiLogin" ]]
}

@test "S-HTTP-01 http: a refused connection is crit" {
  FAKE_CURL_EXIT=7 FAKE_CURL_ERROR="Failed to connect to localhost port 8080" check http
  [ "$status" -eq 2 ]
  expect http crit refused
  [ "$(of http metrics.code)" = 0 ]
}

@test "S-HTTP-02 http: an unexpected status code is crit, with the code" {
  FAKE_CURL_CODE=503 check http
  [ "$status" -eq 2 ]
  expect http crit status
  [ "$(of http metrics.code)" = 503 ]
}

@test "S-HTTP-03 http: an answer slower than HTTP_SLOW is warn, with the duration" {
  FAKE_CURL_TIME=10.000000 check http
  [ "$status" -eq 1 ]
  expect http warn slow
  [ "$(of http metrics.time_seconds)" = 10.0 ]
  FAKE_CURL_TIME=9.999999 check http
  expect http ok ok
  FAKE_CURL_TIME=2.500000 check http -o HTTP_SLOW=2
  expect http warn slow
}

@test "http: no answer within HTTP_TIMEOUT is crit" {
  FAKE_CURL_EXIT=28 FAKE_CURL_ERROR="Operation timed out after 30001 milliseconds" check http
  expect http crit timeout
}

@test "S-HTTP-04 http: the redirect of a fresh installation is warn, Distribution Wizard pending" {
  # The Location a fresh XWiki 18.9.0 answers with (HTTP 302).
  FAKE_CURL_CODE=302 \
    FAKE_CURL_REDIRECT='http://localhost:8080/xwiki/bin/distribution/XWiki/Distribution?xredirect=%2Fxwiki%2Fbin%2Fview%2FMain%2F' \
    check http
  [ "$status" -eq 1 ]
  expect http warn wizard
}

@test "http: any other redirect is crit, unless its code is expected" {
  FAKE_CURL_CODE=302 FAKE_CURL_REDIRECT='http://localhost:8080/xwiki/bin/login/XWiki/XWikiLogin' check http
  expect http crit redirect
  FAKE_CURL_CODE=302 FAKE_CURL_REDIRECT='http://localhost:8080/xwiki/bin/login/XWiki/XWikiLogin' \
    check http -o "HTTP_EXPECT=200 302"
  expect http ok ok
}

@test "S-HTTP-05 http: XWiki still initializing (HTTP 202) is warn, not crit" {
  FAKE_CURL_CODE=202 check http rest
  [ "$status" -eq 1 ]
  expect http warn initializing
  FAKE_REST_CODE=202 check rest
  expect rest warn initializing
}

@test "S-HTTP-05 http: no answer from a JVM that just started is warn, not crit" {
  FAKE_JVM_AGE=20 FAKE_CURL_EXIT=7 check http rest
  [ "$status" -eq 1 ]
  expect http warn starting
  expect rest warn starting
  FAKE_JVM_AGE=20 FAKE_CURL_EXIT=28 check http
  expect http warn starting
  # After STARTUP_GRACE, it is a failure.
  FAKE_JVM_AGE=300 FAKE_CURL_EXIT=7 check http
  expect http crit refused
  FAKE_JVM_AGE=20 FAKE_CURL_EXIT=7 check http -o STARTUP_GRACE=10
  expect http crit refused
  # Without a JVM, nothing is starting.
  FAKE_UNIT_STOPPED=1 FAKE_CURL_EXIT=7 check http
  expect http crit refused
  # A wrong status code is never excused.
  FAKE_JVM_AGE=20 FAKE_CURL_CODE=500 check http
  expect http crit status
}

@test "S-HTTP-06 http: a host name that does not resolve is unknown, not crit" {
  FAKE_CURL_EXIT=6 FAKE_CURL_ERROR="Could not resolve host: wiki.invalid" check http \
    -o BASE_URL=http://wiki.invalid/xwiki
  [ "$status" -eq 3 ]
  expect http unknown dns
}

@test "http: a TLS error is crit; HTTP_INSECURE=yes accepts any certificate" {
  FAKE_CURL_EXIT=60 FAKE_CURL_ERROR="SSL certificate problem: self-signed certificate" check http
  expect http crit error
  [[ "$(of http message)" == *"self-signed certificate"* ]]
  check http -o HTTP_INSECURE=yes
  [[ "$(calls curl | tail -n 1)" == *"--insecure"* ]]
}

@test "S-HTTP-07 http: credentials are passed as a netrc file, never as arguments" {
  mkdir -p "$XINIT_CONF_DIR/credentials"
  echo "machine localhost login Admin password s3cret" >"$XINIT_CONF_DIR/credentials/default.netrc"
  check http
  expect http ok ok
  [[ "$(calls curl)" == *"--netrc-file $XINIT_CONF_DIR/credentials/default.netrc"* ]]
  [[ "$(calls curl)" != *s3cret* ]]
  [[ "$output$stderr" != *s3cret* ]]
  # HTTP_NETRC names another file.
  cp "$XINIT_CONF_DIR/credentials/default.netrc" "$BATS_TEST_TMPDIR/other.netrc"
  check http -o "HTTP_NETRC=$BATS_TEST_TMPDIR/other.netrc"
  [[ "$(calls curl | tail -n 1)" == *"--netrc-file $BATS_TEST_TMPDIR/other.netrc"* ]]
}

@test "http: without BASE_URL the check is unknown; without curl too" {
  rm "$XINIT_ROOT/etc/tomcat10/Catalina/localhost/xwiki.xml"
  check http rest
  expect http unknown no-url
  expect rest unknown no-url
}

@test "http: any other curl failure is crit, with curl's message" {
  FAKE_CURL_EXIT=52 FAKE_CURL_ERROR="Empty reply from server" check http
  expect http crit error
  [[ "$(of http message)" == *"Empty reply from server"* ]]
}

# ---- rest

@test "S-REST-01 rest: the REST API answers with the installed version" {
  check rest
  expect rest ok ok
  [[ "$(of rest message)" == *18.9.0* ]]
  [[ "$(calls curl)" == *"-H Accept: application/json -- http://localhost:8080/xwiki/rest/" ]]
}

@test "rest: a running version that differs from the installed one is warn, restart pending" {
  FAKE_REST_BODY='{"version":"18.8.0"}' check rest
  [ "$status" -eq 1 ]
  expect rest warn restart-pending
}

@test "rest: an answer that is not the REST API is crit; an error code too" {
  FAKE_REST_BODY='<html>some proxy page</html>' check rest
  expect rest crit not-rest
  FAKE_REST_CODE=500 check rest
  expect rest crit status
  FAKE_CURL_EXIT=7 check rest
  expect rest crit refused
}

# ---- disk

@test "disk: enough free space and inodes is ok, with metrics" {
  check disk
  expect disk ok ok
  [ "$(of disk metrics.free_percent)" = 50 ]
  [ "$(of disk metrics.free_bytes)" = 512000000 ]
  [ "$(of disk metrics.inodes_free_percent)" = 50 ]
  [[ "$(calls df)" == *"$XINIT_ROOT/var/lib/xwiki/data"* ]]
}

@test "S-DISK-01 disk: free space below DISK_WARN is warn, below DISK_CRIT is crit" {
  FAKE_DF_FREE=90000 check disk
  [ "$status" -eq 1 ]
  expect disk warn low
  FAKE_DF_FREE=100000 check disk
  expect disk ok ok
  FAKE_DF_FREE=49999 check disk
  [ "$status" -eq 2 ]
  expect disk crit low
  check disk -o DISK_WARN=60% -o DISK_CRIT=20
  expect disk warn low
}

@test "disk: inodes count like space; a file system without inodes is not checked for them" {
  FAKE_DF_IFREE=40000 check disk
  expect disk crit low
  FAKE_DF_IFREE=0 fake df '
    case " $* " in
      *" -i "*) echo "Filesystem Inodes IUsed IFree IUse% Mounted on"; echo "/dev/fake 0 0 0 - /" ;;
      *) echo "Filesystem 1024-blocks Used Available Capacity Mounted on"; echo "/dev/fake 1000000 x 500000 x% /" ;;
    esac'
  check disk
  expect disk ok ok
  [ -z "$(of disk metrics.inodes_free_percent)" ]
}

@test "disk: an unknown or missing permanent directory, or bad thresholds, is unknown" {
  check disk -o PERMDIR=/nowhere
  expect disk unknown no-dir
  check disk -o DISK_WARN=lots
  expect disk unknown bad-config
  sed -i 's/^environment.permanentDirectory/#&/' "$XINIT_ROOT/etc/xwiki/xwiki.properties"
  check disk
  expect disk unknown no-permdir
}
