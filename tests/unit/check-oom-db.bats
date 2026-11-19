#!/usr/bin/env bats
# The oom and db checks, against stubbed journalctl and database clients, and real journal lines
# (tests/fixtures/journal/).

load helpers

setup() {
  use_fixture tomcat10-pgsql
}

check() { run --separate-stderr "$XINIT" check --format json "$@"; }
of() {
  case "$2" in
    metrics.*) json "[r for r in d['results'] if r['check'] == '$1'][0]['metrics'].get('${2#metrics.}')" ;;
    *) json "[r for r in d['results'] if r['check'] == '$1'][0]['$2']" ;;
  esac
}
expect() {
  local got
  got="$(of "$1" status) $(of "$1" reason)"
  [ "$got" = "$2 $3" ] || { echo "$1: expected '$2 $3', got '$got': $(of "$1" message)"; return 1; }
}

# kernel_oom_journal: the kernel's and systemd's messages of a real OOM kill, with the control
# group of the fixture's unit. Prints the file's path.
kernel_oom_journal() {
  local cgroup file="$BATS_TEST_TMPDIR/kernel-oom.txt"
  cgroup="$(sed -n 's/^ControlGroup=//p' "$XINIT_ROOT/cmd/systemctl-show-tomcat10.txt")"
  [ -n "$cgroup" ]
  sed "s#/docker/[0-9a-f]*/system.slice/tomcat10.service#$cgroup#g" \
    "$FIXTURES/journal/kernel-oom-system.txt" >"$file"
  echo "$file"
}

# journal_reads: the journalctl calls that read messages, without the ones that only ask
# journalctl whether it may read (-n 0).
journal_reads() { calls journalctl | grep -v -- ' -n 0 '; }

# ---- oom

@test "oom: a journal without out-of-memory errors is ok" {
  check oom
  [ "$status" -eq 0 ]
  expect oom ok ok
  [ "$(of oom metrics.heap_errors)" = 0 ]
  [ "$(of oom metrics.kernel_kills)" = 0 ]
  # The unit's log, then the kernel's and systemd's messages, both bounded in time.
  [[ "$(journal_reads | sed -n 1p)" == "--no-pager -o cat -u tomcat10.service --since -3600s" ]]
  [[ "$(journal_reads | sed -n 2p)" == "--no-pager -o cat --since -3600s _TRANSPORT=kernel + _PID=1" ]]
}

@test "S-OOM-01 oom: java.lang.OutOfMemoryError in the unit's log is crit, heap" {
  FAKE_JOURNAL_UNIT="$FIXTURES/journal/heap-oom-unit.txt" check oom
  [ "$status" -eq 2 ]
  expect oom crit heap
  [ "$(of oom metrics.heap_errors)" = 4 ]
  [[ "$(of oom message)" == *"Java heap space"* ]]
}

@test "S-OOM-02 oom: only the log since the JVM started is searched" {
  FAKE_JVM_AGE=125 check oom
  [[ "$(journal_reads | sed -n 1p)" == *"-u tomcat10.service --since -125s" ]]
  # The kernel's messages are searched over the whole window: the kill is why the JVM is young.
  [[ "$(journal_reads | sed -n 2p)" == *"--since -3600s _TRANSPORT=kernel"* ]]
  FAKE_JVM_AGE=125 check oom -o OOM_WINDOW=60
  [[ "$(journal_reads | sed -n 3p)" == *"-u tomcat10.service --since -60s" ]]
}

@test "S-OOM-03 oom: a kill by the kernel's OOM killer is warn, kernel" {
  FAKE_JOURNAL_SYSTEM="$(kernel_oom_journal)" check oom
  [ "$status" -eq 1 ]
  expect oom warn kernel
  [ "$(of oom metrics.kernel_kills)" = 1 ]
}

@test "oom: systemd's own message about the unit counts as a kernel kill" {
  # What systemd logs on a cgroup v2 host.
  printf '%s\n' "tomcat10.service: A process of this unit has been killed by the OOM killer." \
    "tomcat10.service: Failed with result 'oom-kill'." >"$BATS_TEST_TMPDIR/systemd.txt"
  FAKE_JOURNAL_SYSTEM="$BATS_TEST_TMPDIR/systemd.txt" check oom
  expect oom warn kernel
  [ "$(of oom metrics.kernel_kills)" = 1 ]
}

@test "oom: a kill on cgroup v2 is seen in systemd's words, whatever the control group of the stopped unit" {
  # Lines of a real kill. The unit has failed, so systemd no longer tells its control group.
  export FAKE_UNIT_STOPPED=1
  sed -i 's/^ControlGroup=.*/ControlGroup=/' "$XINIT_ROOT/cmd/systemctl-show-tomcat10.txt"
  FAKE_JOURNAL_SYSTEM="$FIXTURES/journal/kernel-oom-cgroup2-system.txt" check oom
  [ "$status" -eq 1 ]
  expect oom warn kernel
  [ "$(of oom metrics.kernel_kills)" = 1 ]
  # systemd 259 says it in other words.
  FAKE_JOURNAL_SYSTEM="$FIXTURES/journal/kernel-oom-systemd259-system.txt" check oom
  expect oom warn kernel
  [ "$(of oom metrics.kernel_kills)" = 1 ]
}

@test "oom: a unit that systemd ended for an OOM kill counts, whatever the journal says" {
  export FAKE_UNIT_STOPPED=1
  sed -i 's/^Result=.*/Result=oom-kill/' "$XINIT_ROOT/cmd/systemctl-show-tomcat10.txt"
  check oom
  [ "$status" -eq 1 ]
  expect oom warn kernel
  [ "$(of oom metrics.kernel_kills)" = 1 ]
  [[ "$(of oom message)" == *"still down"* ]]
  # Started again, the result is no longer that one.
  unset FAKE_UNIT_STOPPED
  sed -i 's/^Result=.*/Result=success/' "$XINIT_ROOT/cmd/systemctl-show-tomcat10.txt"
  check oom
  expect oom ok ok
}

@test "oom: without a JVM, heap errors are looked for since the unit last started, not before" {
  # The unit started its main process 315 s after the boot, and the host has been up for 1000 s.
  export FAKE_UNIT_STOPPED=1
  mkdir -p "$XINIT_ROOT/proc"
  echo "1000.50 9000.00" >"$XINIT_ROOT/proc/uptime"
  FAKE_JOURNAL_UNIT="$FIXTURES/journal/heap-oom-unit.txt" check oom
  expect oom crit heap
  [[ "$(of oom message)" == *"the last JVM of tomcat10.service logged 4 "*"no longer running"* ]]
  [[ "$(journal_reads | sed -n 1p)" == *"-u tomcat10.service --since -685s"* ]]
  # When that cannot be told, the whole window is searched.
  rm -f "$FAKEBIN/journalctl.calls" "$XINIT_ROOT/proc/uptime"
  check oom
  [[ "$(journal_reads | sed -n 1p)" == *"--since -3600s"* ]]
}

@test "oom: one kill reported by both the kernel and systemd is counted once" {
  { cat "$(kernel_oom_journal)"
    echo "tomcat10.service: A process of this unit has been killed by the OOM killer."
  } >"$BATS_TEST_TMPDIR/both.txt"
  FAKE_JOURNAL_SYSTEM="$BATS_TEST_TMPDIR/both.txt" check oom
  expect oom warn kernel
  [ "$(of oom metrics.kernel_kills)" = 1 ]
}

@test "oom: a unit of the same name in a container of this host is not ours" {
  # On a host, the unit's control group has no container prefix.
  sed -i 's#^ControlGroup=.*#ControlGroup=/system.slice/tomcat10.service#' \
    "$XINIT_ROOT/cmd/systemctl-show-tomcat10.txt"
  FAKE_JOURNAL_SYSTEM="$FIXTURES/journal/kernel-oom-system.txt" check oom
  expect oom ok ok
  sed 's#task_memcg=/docker/[0-9a-f]*/system.slice#task_memcg=/system.slice#' \
    "$FIXTURES/journal/kernel-oom-system.txt" >"$BATS_TEST_TMPDIR/host.txt"
  FAKE_JOURNAL_SYSTEM="$BATS_TEST_TMPDIR/host.txt" check oom
  expect oom warn kernel
}

@test "oom: an OOM kill in another unit or container is not ours" {
  sed 's#system.slice/tomcat10.service#system.slice/other.service#g' "$(kernel_oom_journal)" \
    >"$BATS_TEST_TMPDIR/other.txt"
  FAKE_JOURNAL_SYSTEM="$BATS_TEST_TMPDIR/other.txt" check oom
  expect oom ok ok
  # The same unit name, in another container.
  FAKE_JOURNAL_SYSTEM="$FIXTURES/journal/kernel-oom-system.txt" check oom
  expect oom ok ok
}

@test "oom: the words of an out-of-memory error inside a logged message are not one" {
  # What XWiki logs about a request can hold any text: only the JVM's own lines count.
  printf '%s\n' \
    '2026-11-18 10:07:26,404 [http-nio-8080-exec-1 - http://localhost:8080/xwiki/bin/view/A/java.lang.OutOfMemoryError: Java heap space] WARN  o.x.s.Thing - Not found' \
    '  java.lang.OutOfMemoryError: Java heap space, said a page' \
    'Reason: Exception in thread "x" java.lang.OutOfMemoryError: Java heap space' >"$BATS_TEST_TMPDIR/journal"
  FAKE_JOURNAL_UNIT="$BATS_TEST_TMPDIR/journal" check oom
  [ "$status" -eq 0 ]
  expect oom ok ok
  [ "$(of oom metrics.heap_errors)" = 0 ]
  # The cause at the end of a stack trace is the JVM's.
  printf '%s\n' 'java.lang.RuntimeException: Failed' '        at org.xwiki.Thing.run(Thing.java:1)' \
    'Caused by: java.lang.OutOfMemoryError: Metaspace' >"$BATS_TEST_TMPDIR/journal"
  FAKE_JOURNAL_UNIT="$BATS_TEST_TMPDIR/journal" check oom
  expect oom crit heap
  [[ "$(of oom message)" == *"Metaspace"* ]]
}

@test "oom: a heap error and a kernel kill together are crit, with both counted" {
  FAKE_JOURNAL_UNIT="$FIXTURES/journal/heap-oom-unit.txt" FAKE_JOURNAL_SYSTEM="$(kernel_oom_journal)" \
    check oom
  expect oom crit heap
  [ "$(of oom metrics.kernel_kills)" = 1 ]
}

@test "oom: a logged line about permissions is not taken for a journal that cannot be read" {
  { cat "$FIXTURES/journal/heap-oom-unit.txt"
    echo "LDAP bind failed: insufficient permissions for cn=xwiki"
  } >"$BATS_TEST_TMPDIR/unit.txt"
  FAKE_JOURNAL_UNIT="$BATS_TEST_TMPDIR/unit.txt" check oom
  [ "$status" -eq 2 ]
  expect oom crit heap
}

@test "oom: OOM_WINDOW with leading zeros is a decimal number" {
  check oom disk -o OOM_WINDOW=0900
  [ "$status" -eq 0 ]
  expect oom ok ok
  expect disk ok ok
  [[ "$(journal_reads | sed -n 1p)" == *"--since -900s" ]]
}

@test "oom: a journal that cannot be read is unknown, not ok" {
  FAKE_JOURNAL_DENIED=1 check oom
  [ "$status" -eq 3 ]
  expect oom unknown no-access
  fake journalctl 'echo "Failed to open journal" >&2; exit 1'
  check oom
  expect oom unknown no-access
}

@test "oom: a log that is not the journal, or a bad window, is unknown" {
  check oom -o LOG_SOURCE=file:/var/log/xwiki.log
  expect oom unknown no-journal
  check oom -o OOM_WINDOW=1h
  expect oom unknown bad-config
}

# ---- db

@test "db: without credentials, a port that accepts connections is ok, login not checked" {
  check db
  [ "$status" -eq 0 ]
  expect db ok port-only
  [[ "$(calls timeout)" == "10 bash -c "*" _ localhost 5432" ]]
  [ -z "$(calls psql)" ]
}

@test "S-DB-01 db: a database that refuses connections is crit" {
  FAKE_DB_TCP=refused check db
  [ "$status" -eq 2 ]
  expect db crit refused
  FAKE_DB_TCP=timeout check db
  expect db crit timeout
}

@test "db: a database host name that does not resolve is unknown" {
  FAKE_DB_TCP=dns check db -o DB_HOST=db.invalid
  [ "$status" -eq 3 ]
  expect db unknown dns
}

@test "db: with a credentials file, PostgreSQL is logged into, the password staying in the file" {
  mkdir -p "$XINIT_CONF_DIR/credentials"
  echo "localhost:5432:xwiki:xwiki:s3cret" >"$XINIT_CONF_DIR/credentials/default.pgpass"
  check db
  expect db ok ok
  [ "$(calls psql)" = "-X -w -At -h localhost -p 5432 -U xwiki -d xwiki -c SELECT 1" ]
  [ "$(cat "$FAKEBIN/psql.env")" = "PGPASSFILE=$XINIT_CONF_DIR/credentials/default.pgpass" ]
  # shellcheck disable=SC2154  # $stderr is set by bats' run
  [[ "$output$stderr$(calls psql)" != *s3cret* ]]
}

@test "db: a failed login or query is crit, with the client's message" {
  mkdir -p "$XINIT_CONF_DIR/credentials"
  echo "localhost:5432:xwiki:xwiki:wrong" >"$XINIT_CONF_DIR/credentials/default.pgpass"
  FAKE_DB_LOGIN_ERROR='psql: error: FATAL:  password authentication failed for user "xwiki"' check db
  [ "$status" -eq 2 ]
  expect db crit login-failed
  [[ "$(of db message)" == *"password authentication failed"* ]]
}

@test "db: a database that goes down between the test of its port and the login is refused, not a failed login" {
  mkdir -p "$XINIT_CONF_DIR/credentials"
  echo "*:*:*:xwiki:secret" >"$XINIT_CONF_DIR/credentials/default.pgpass"
  FAKE_DB_LOGIN_ERROR='psql: error: connection to server at "localhost" (127.0.0.1), port 5432 failed: Connection refused' \
    check db
  [ "$status" -eq 2 ]
  expect db crit refused
  FAKE_DB_LOGIN_ERROR="ERROR 2002 (HY000): Can't connect to server on 'localhost' (111)" check db
  expect db crit refused
  # PostgreSQL still answers while it stops, or starts: what a CI run got.
  FAKE_DB_LOGIN_ERROR='psql: error: connection to server at "localhost" (::1), port 5432 failed: FATAL:  the database system is shutting down' \
    check db
  expect db crit refused
  FAKE_DB_LOGIN_ERROR="ERROR 1053 (08S01): Server shutdown in progress" check db
  expect db crit refused
  # A real refusal of this user stays one.
  FAKE_DB_LOGIN_ERROR='psql: error: connection to server at "localhost" (::1), port 5432 failed: FATAL:  password authentication failed for user "xwiki"' \
    check db
  expect db crit login-failed
}

@test "db: MariaDB is logged into with a defaults file, over TCP" {
  use_other_fixture tomcat11-mariadb
  mkdir -p "$XINIT_CONF_DIR/credentials"
  printf '[client]\npassword=s3cret\n' >"$XINIT_CONF_DIR/credentials/default.my.cnf"
  check db
  expect db ok ok
  [ "$(calls mariadb)" = "--defaults-file=$XINIT_CONF_DIR/credentials/default.my.cnf --protocol=tcp -h localhost -P 3306 -u xwiki --connect-timeout=10 -N -B -e SELECT 1 xwiki" ]
  [[ "$(calls timeout)" == *" _ localhost 3306" ]]
}

@test "db: DB_CREDENTIALS and DB_TIMEOUT are used" {
  echo "localhost:5432:xwiki:xwiki:s3cret" >"$BATS_TEST_TMPDIR/my.pgpass"
  check db -o "DB_CREDENTIALS=$BATS_TEST_TMPDIR/my.pgpass" -o DB_TIMEOUT=3
  expect db ok ok
  [ "$(cat "$FAKEBIN/psql.env")" = "PGPASSFILE=$BATS_TEST_TMPDIR/my.pgpass" ]
  [[ "$(calls timeout)" == "3 bash "* ]]
}

@test "db: a database or user name that a client could misread is not passed to it" {
  mkdir -p "$XINIT_CONF_DIR/credentials"
  echo "localhost:5432:*:xwiki:s3cret" >"$XINIT_CONF_DIR/credentials/default.pgpass"
  check db -o "DB_NAME=xwiki sslmode=disable"
  expect db ok port-only
  check db -o DB_USER=-xwiki
  expect db ok port-only
  [ -z "$(calls psql)" ]
}

@test "db: DB_TIMEOUT and DB_PORT that are not numbers are unknown, not a database failure" {
  check db -o DB_TIMEOUT=abc
  [ "$status" -eq 3 ]
  expect db unknown bad-config
  check db -o DB_PORT=5432x
  expect db unknown bad-config
  [ -z "$(calls timeout)" ]
}

@test "S-DB-02 db: a database with no client to log in with is checked on its port only" {
  echo "x" >"$BATS_TEST_TMPDIR/credentials"
  check db process -o DB_TYPE=oracle -o DB_PORT=1521 -o "DB_CREDENTIALS=$BATS_TEST_TMPDIR/credentials"
  [ "$status" -eq 0 ]
  expect db ok port-only
  expect process ok running
}

@test "db: an embedded database is ok; an unknown one is unknown" {
  check db -o DB_TYPE=hsqldb
  expect db ok embedded
  rm "$XINIT_ROOT/etc/xwiki/hibernate.cfg.xml"
  check db
  [ "$status" -eq 3 ]
  expect db unknown no-db
  check db -o DB_TYPE=postgresql
  expect db unknown no-db
  check db -o DB_TYPE=postgresql -o DB_HOST=localhost -o DB_PORT=5432
  expect db ok port-only
}

@test "db: the port probe tells an open port from a closed one, for real" {
  # shellcheck source=../../lib/xinit/core.sh
  source "$XINIT_REPO/lib/xinit/core.sh"
  # shellcheck source=../../lib/xinit/config.sh
  source "$XINIT_REPO/lib/xinit/config.sh"
  # shellcheck source=../../lib/xinit/checks/db.sh
  source "$XINIT_REPO/lib/xinit/checks/db.sh"
  # The real `timeout`, not the fake.
  PATH="${PATH#"$FAKEBIN":}"
  local port
  python3 -c '
import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(5)
print(s.getsockname()[1], flush=True)
time.sleep(20)' >"$BATS_TEST_TMPDIR/port" 3>&- &
  local listener=$!
  while [ ! -s "$BATS_TEST_TMPDIR/port" ]; do sleep 0.1; done
  port="$(cat "$BATS_TEST_TMPDIR/port")"
  _xinit_tcp_probe 127.0.0.1 "$port" 5
  _xinit_tcp_probe "[127.0.0.1]" "$port" 5
  kill "$listener"
  wait "$listener" 2>/dev/null || true
  run _xinit_tcp_probe 127.0.0.1 "$port" 5
  [ "$status" -eq 1 ]
  _xinit_tcp_probe 127.0.0.1 "$port" 5 || [ "$XINIT_TCP_ERROR" = refused ]
  _xinit_tcp_probe no-such-host.invalid 5432 5 || [ "$XINIT_TCP_ERROR" = dns ]
}
