#!/usr/bin/env bats
# What xinit does to XWiki when the periodic job is not root, and the commands the systemd units
# run: `xinit act`, `xinit notify` and `xinit warmup`.

load helpers

setup() {
  use_fixture tomcat10-pgsql
  use_state
  RUN="$XINIT_RUN_DIR/default"
}

w() { json "d['watch']['$1']"; }
restarts() { calls systemctl | grep -c '^restart ' || true; }

@test "act: a job that is not root asks for the thread dumps and the restart, and waits for them" {
  export FAKE_UID=995 FAKE_STATE_OWNER=995:995 FAKE_USER=xinit FAKE_ACT=1 FAKE_CURL_EXIT=28
  export FAKE_JOURNAL_UNIT="$FIXTURES/journal/thread-dumps-unit.txt"
  conf <<<"RESTART_AFTER=1"
  run --separate-stderr "$XINIT" watch --format json
  [ "$status" -eq 0 ]
  [ "$(w action)" = restart ]
  [ "$(w restart_ok)" = True ]
  [ -e "$(w report)" ]
  # It did neither itself.
  [ "$(restarts)" = 0 ]
  [ -z "$(calls kill)" ]
  [ "$(cat "$FAKEBIN/requests.log")" = "request-thread-dump
request-thread-dump
request-thread-dump
request-restart" ]
  [ "$(ls "$RUN")" = lock ]
}

@test "act: when nothing answers the request, the restart has failed and the request is withdrawn" {
  export FAKE_UID=995 FAKE_STATE_OWNER=995:995 FAKE_CURL_EXIT=28
  conf <<<"RESTART_AFTER=1"
  run --separate-stderr "$XINIT" watch --format json
  [ "$status" -eq 3 ]
  [ "$(w action)" = restart ]
  [ "$(w restart_ok)" = False ]
  # The report is there, without the thread dumps.
  tar -xzOf "$(w report)" --wildcards '*/summary.txt' | grep -q "^  threads: the JVM could not be sent a signal: nothing answered the request"
  # shellcheck disable=SC2154  # $stderr is set by bats' run
  [[ "$stderr" == *"nothing answered the request"*"xinit setup"* ]]
  [ "$(ls "$RUN")" = lock ]
}

@test "act: a restart that root could not do has failed" {
  export FAKE_UID=995 FAKE_STATE_OWNER=995:995 FAKE_ACT=1 FAKE_ACT_STATE=failed FAKE_CURL_EXIT=28
  conf <<<"RESTART_AFTER=1"
  run --separate-stderr "$XINIT" watch --format json
  [ "$status" -eq 3 ]
  [ "$(w restart_ok)" = False ]
}

@test "act: a job that is not root asks root also when RESTART_CMD is set" {
  export FAKE_UID=995 FAKE_STATE_OWNER=995:995 FAKE_ACT=1 FAKE_CURL_EXIT=28
  fake myrestart ''
  conf <<<"RESTART_AFTER=1
RESTART_CMD=myrestart wiki"
  run --separate-stderr "$XINIT" watch --format json
  [ "$(w restart_ok)" = True ]
  # Confined and without rights, it could not restart anything itself.
  [ -z "$(calls myrestart)" ]
  grep -qx request-restart "$FAKEBIN/requests.log"
}

@test "act: root restarts with RESTART_CMD when there is one" {
  mkdir -p "$RUN"
  touch "$RUN/request-restart"
  fake myrestart ''
  conf <<<"RESTART_CMD=myrestart wiki"
  run "$XINIT" act
  [ "$status" -eq 0 ]
  [ "$(calls myrestart)" = wiki ]
  [ "$(restarts)" = 0 ]
}

@test "act: root does what the requests are named after, and removes them" {
  mkdir -p "$RUN"
  echo "restart sshd.service; rm -rf /" >"$RUN/request-restart"
  touch "$RUN/request-thread-dump" "$RUN/request-something-else"
  run "$XINIT" act
  [ "$status" -eq 0 ]
  [ "$(calls kill)" = "-s QUIT 98" ]
  # Nothing is read from a request: the unit is the one of the installation.
  [ "$(calls systemctl | grep '^restart ')" = "restart -- tomcat10.service" ]
  [ "$(ls "$RUN")" = request-something-else ]
  [[ "$(calls logger)" == *"restarting tomcat10.service, on request"* ]]
}

@test "act: without a request it does nothing" {
  run "$XINIT" act
  [ "$status" -eq 0 ]
  [ "$(restarts)" = 0 ]
  [ -z "$(calls kill)" ]
}

@test "act: a request that is a link leading nowhere still counts, and is removed" {
  mkdir -p "$RUN"
  ln -s /nonexistent/target "$RUN/request-restart"
  run "$XINIT" act
  [ "$status" -eq 0 ]
  [ "$(restarts)" = 1 ]
  [ ! -L "$RUN/request-restart" ]
}

@test "act: a restart that fails is an error" {
  mkdir -p "$RUN"
  touch "$RUN/request-restart"
  FAKE_RESTART_ERROR="Unit is masked" run "$XINIT" act
  [ "$status" -eq 3 ]
  [ ! -e "$RUN/request-restart" ]
}

@test "act: only root, and no argument" {
  FAKE_UID=995 run "$XINIT" act
  [ "$status" -eq 3 ]
  run "$XINIT" act restart
  [ "$status" -eq 64 ]
  [ "$(restarts)" = 0 ]
}

@test "act: without an installation the requests are removed, not left to start it again" {
  mkdir -p "$RUN"
  touch "$RUN/request-restart"
  rm -rf "$XINIT_ROOT"
  mkdir -p "$XINIT_ROOT"
  fake dpkg-query ''
  run "$XINIT" act
  [ "$status" -eq 3 ]
  [ ! -e "$RUN/request-restart" ]
}

@test "notify: a crash is notified with what systemd said about it" {
  printf '%s\n' "tomcat10.service: Main process exited, code=killed, status=9/KILL" \
    "tomcat10.service: Failed with result 'signal'." >"$BATS_TEST_TMPDIR/journal"
  FAKE_JOURNAL_UNIT="$BATS_TEST_TMPDIR/journal" run "$XINIT" notify crash
  [ "$status" -eq 0 ]
  [[ "$(calls logger)" == *"instance default: notification (crash): tomcat10.service stopped unexpectedly: Failed with result 'signal'."* ]]
}

@test "notify: without a word from systemd, the crash is still notified" {
  FAKE_JOURNAL_DENIED=1 run "$XINIT" notify crash
  [ "$status" -eq 0 ]
  [[ "$(calls logger)" == *"notification (crash): tomcat10.service stopped unexpectedly" ]]
}

@test "notify: usage errors exit 64" {
  run "$XINIT" notify
  [ "$status" -eq 64 ]
  run "$XINIT" notify restart
  [ "$status" -eq 64 ]
}

@test "warmup: by default the page of the http check is requested" {
  run "$XINIT" warmup
  [ "$status" -eq 0 ]
  [[ "$(calls curl)" == *" -- http://localhost:8080/xwiki/bin/view/Main/" ]]
  [ "$(calls curl | wc -l)" -eq 1 ]
  [[ "$(calls logger)" == *"warm-up: 1 of 1 URLs answered"* ]]
}

@test "S-WARMUP-01 warmup: every URL of WARMUP_URLS is requested, a path under BASE_URL" {
  conf <<<"WARMUP_URLS=/bin/view/Main/ http://wiki2.example.org/xwiki/bin/view/Main/"
  run "$XINIT" warmup
  [ "$status" -eq 0 ]
  [[ "$(calls curl | sed -n 1p)" == *" -- http://localhost:8080/xwiki/bin/view/Main/" ]]
  [[ "$(calls curl | sed -n 2p)" == *" -- http://wiki2.example.org/xwiki/bin/view/Main/" ]]
}

@test "warmup: a URL that never answers 200 is tried until WARMUP_TIMEOUT, then it fails" {
  conf <<<"WARMUP_TIMEOUT=0"
  FAKE_CURL_CODE=503 run "$XINIT" warmup
  [ "$status" -eq 2 ]
  [[ "$(calls logger)" == *"warm-up: 0 of 1 URLs answered"* ]]
}

@test "warmup: what is not a URL, or a duration, is refused before any request" {
  conf <<<"WARMUP_URLS=ftp://example.org/ --output=/etc/passwd"
  run "$XINIT" warmup
  [ "$status" -eq 3 ]
  conf <<<"WARMUP_TIMEOUT=soon"
  run "$XINIT" warmup
  [ "$status" -eq 3 ]
  [ -z "$(calls curl)" ]
}
