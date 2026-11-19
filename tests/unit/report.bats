#!/usr/bin/env bats
# `xinit report`: the diagnostics archive. Scenarios S-REPORT-* of docs/TESTING.md, on fakes.

load helpers

setup() {
  use_fixture tomcat10-pgsql
  use_state
  DUMPS="$FIXTURES/journal/thread-dumps-unit.txt"
  REPORTS="$XINIT_STATE_DIR/default/reports"
  TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  export TMPDIR FAKE_JOURNAL_UNIT="$DUMPS"
  # The process of the JVM of the fixture, and the host.
  PROC="$XINIT_ROOT/proc"
  printf '%s\0' /usr/bin/java -Xmx1024m -Dcatalina.base=/var/lib/tomcat10 \
    org.apache.catalina.startup.Bootstrap start >"$PROC/98/cmdline"
  printf 'Name:\tjava\nVmRSS:\t 1048576 kB\nThreads:\t213\n' >"$PROC/98/status"
  printf '0.50 0.40 0.30 2/345 6789\n' >"$PROC/loadavg"
  printf 'MemTotal:        8388608 kB\nMemFree:  1000 kB\nMemAvailable:    4194304 kB\n' >"$PROC/meminfo"
}

# report [arguments...]: one report, with its result in JSON.
report() { run --separate-stderr "$XINIT" report --format json "$@"; }

# unpack <archive>: extract it, and set R to its directory.
unpack() {
  rm -rf "$BATS_TEST_TMPDIR/unpacked"
  mkdir "$BATS_TEST_TMPDIR/unpacked"
  tar -xzf "$1" -C "$BATS_TEST_TMPDIR/unpacked"
  local found=("$BATS_TEST_TMPDIR"/unpacked/*)
  [ "${#found[@]}" -eq 1 ]
  R="${found[0]}"
}

# section <name>: what became of a section.
section() { json "d['sections'].get('$1')"; }

# credentials <password>: the credentials file of the database of the fixture.
credentials() {
  mkdir -p "$XINIT_CONF_DIR/credentials"
  printf '*:*:*:*:%s\n' "$1" >"$XINIT_CONF_DIR/credentials/default.pgpass"
}

@test "S-REPORT-01 report: an archive for its owner only, with every section" {
  credentials "s3cretPassw0rd"
  fake psql '
    case "$*" in
      *"SELECT 1") echo 1 ;;
      *sessions:*) echo "sessions: 12, active: 2, size: 150 MB" ;;
      *) echo "pid | user | state" ;;
    esac'
  report
  [ "$status" -eq 0 ]
  file="$(json 'd["report"]')"
  [ "$file" = "$REPORTS/report-20270115T080000Z.tar.gz" ]
  [ "$(stat -c %a "$file")" = 600 ]
  [ "$(stat -c %a "$REPORTS")" = 700 ]
  [ "$(stat -c %a "$XINIT_STATE_DIR/default")" = 700 ]
  [ "$(json 'd["instance"]')" = default ]
  [ "$(json 'd["status"]')" = ok ]
  [ "$(json 'd["oom"]')" = False ]
  [ "$(json 'd["thread_dumps"]')" = 3 ]
  for name in layout checks system jvm sockets database disk journal threads; do
    [ "$(section "$name")" = ok ]
  done
  [ "$(section dns)" = "" ]
  unpack "$file"
  [ "${R##*/}" = "xinit-report-default-20270115T080000Z" ]
  for name in summary.txt layout.txt config.txt checks.json system.txt jvm.txt sockets.txt \
    database.txt disk.txt journal.txt threads/dump-1.txt threads/dump-2.txt threads/dump-3.txt; do
    [ -s "$R/$name" ]
  done
  [ ! -e "$R/dns.txt" ]
  python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); assert len(d["results"]) == 6' "$R/checks.json"
  grep -q "^UNIT " "$R/layout.txt"
  grep -q "^STATE_DIR" "$R/config.txt"
  grep -q -- "-Xmx1024m" "$R/jvm.txt"
  grep -q "^JVM: PID 98, running for 1d, 213 threads, 1024 MB in memory$" "$R/summary.txt"
  grep -q "^Host: load 0.50 0.40 0.30, 4096 MB of memory available out of 8192 MB$" "$R/summary.txt"
  grep -q "^Database (postgresql): sessions: 12, active: 2, size: 150 MB$" "$R/summary.txt"
  grep -q "^  port 8080: 0 waiting to be accepted, of 100 at most, " "$R/summary.txt"
  grep -q "^  to port 5432 (the database): ESTAB 1$" "$R/summary.txt"
  # Each dump in its file, from its time on.
  [ "$(head -n 1 "$R/threads/dump-2.txt")" = "2026-11-19 11:58:00" ]
  [ "$(grep -c '^Full thread dump' "$R/threads/dump-2.txt")" = 1 ]
  # Nothing is left behind.
  [ -z "$(ls -A "$TMPDIR")" ]
  [ "$(ls -A "$REPORTS")" = "report-20270115T080000Z.tar.gz" ]
}

@test "S-REPORT-05 report: root asks the JVM with SIGQUIT, three times, and reads the journal" {
  report
  [ "$status" -eq 0 ]
  [ "$(calls kill)" = "-s QUIT 98
-s QUIT 98
-s QUIT 98" ]
  [[ "$(calls journalctl)" == *"-u tomcat10.service --since @"* ]]
  # The time between two dumps.
  [ "$(calls sleep | grep -cx 5)" = 2 ]
  conf <<<"THREADDUMP_INTERVAL=20s"
  rm -f "$FAKEBIN/sleep.calls"
  report
  [ "$(calls sleep | grep -cx 20)" = 2 ]
}

@test "S-REPORT-03 report: the summary names the deadlock" {
  report
  [ "$(json 'd["deadlock"]')" = True ]
  unpack "$(json 'd["report"]')"
  grep -q "^Deadlock, in dump 3:$" "$R/summary.txt"
  grep -q '^  "xinit-deadlock-1":$' "$R/summary.txt"
  grep -q '^    which is held by "xinit-deadlock-2"$' "$R/summary.txt"
  # Without their stacks, which are in the dumps.
  run ! grep -q "Java stack information" "$R/summary.txt"
}

@test "report: without a deadlock, the summary says so" {
  grep -v 'deadlock' "$DUMPS" >"$BATS_TEST_TMPDIR/dumps.txt"
  export FAKE_JOURNAL_UNIT="$BATS_TEST_TMPDIR/dumps.txt"
  report
  [ "$(json 'd["deadlock"]')" = False ]
  unpack "$(json 'd["report"]')"
  grep -qx "No deadlock." "$R/summary.txt"
}

@test "S-REPORT-04 report: the URLs most requests are on come first, without their query" {
  report
  unpack "$(json 'd["report"]')"
  grep -A 3 "^Requests being served, by URL" "$R/summary.txt" >"$BATS_TEST_TMPDIR/urls.txt"
  [ "$(sed -n 2p "$BATS_TEST_TMPDIR/urls.txt")" = "    3    3    3  /xwiki/bin/view/XinitTest/Faults" ]
  [ "$(sed -n 3p "$BATS_TEST_TMPDIR/urls.txt")" = "    1    1    0  /xwiki/bin/view/Main/" ]
  # A query string may hold a secret: it stays in the dumps.
  run ! grep -q "action=sleep" "$R/summary.txt"
  grep -q "action=sleep" "$R/threads/dump-1.txt"
}

@test "report: the threads that used the most CPU between the dumps come first" {
  report
  unpack "$(json 'd["report"]')"
  grep -A 2 "^Threads that used the most CPU" "$R/summary.txt" >"$BATS_TEST_TMPDIR/cpu.txt"
  [[ "$(sed -n 2p "$BATS_TEST_TMPDIR/cpu.txt")" == "   3958 ms in 10 s  C2 CompilerThread0  [RUNNABLE]" ]]
  [[ "$(sed -n 3p "$BATS_TEST_TMPDIR/cpu.txt")" == "   1438 ms in 10 s  http-nio-8080-exec-1  [WAITING]  "* ]]
  grep -q "^Thread dumps: 3 (threads in each: 18, 18, 18)$" "$R/summary.txt"
  grep -q "^Java threads by state, in the last dump: RUNNABLE 5, BLOCKED 2, WAITING 3, TIMED_WAITING 5$" "$R/summary.txt"
}

@test "report: a thread name, which a remote user chooses, is shown without control characters and cut" {
  long="$(printf 'A%.0s' {1..1500})"
  esc="$(printf '\033')"
  sed "s|/xwiki/bin/view/XinitTest/Faults?action=sleep|/xwiki/${esc}[2J${esc}]0:owned/$long?action=sleep|" \
    "$DUMPS" >"$BATS_TEST_TMPDIR/dumps.txt"
  export FAKE_JOURNAL_UNIT="$BATS_TEST_TMPDIR/dumps.txt"
  run --separate-stderr "$XINIT" report
  [ "$status" -eq 0 ]
  [[ "$output" == *"/xwiki/ [2J ]0:owned/AAAA"* ]]
  [[ "${output//$'\n'/}" != *[[:cntrl:]]* ]]
  while IFS= read -r line; do
    [ "${#line}" -le 900 ]
  done < <(printf '%s\n' "$output")
}

@test "S-REPORT-02 report: no password in the archive, wherever it showed" {
  credentials 's3cret\:Passw0rd'
  mkdir -p "$XINIT_CONF_DIR/credentials"
  printf 'machine localhost login Admin password adm1nPassw0rd\n' >"$XINIT_CONF_DIR/credentials/default.netrc"
  printf '%s\0' /usr/bin/java -Dxwiki.db.password=fromTheCommandLine -Dkeystore.Secret=other1 \
    --token following2 -Dharmless=shown "-Dnote=s3cret:Passw0rd in a value" >"$PROC/98/cmdline"
  { cat "$DUMPS"; echo "ERROR login of Admin with adm1nPassw0rd and of the database with s3cret:Passw0rd failed"; } \
    >"$BATS_TEST_TMPDIR/journal.txt"
  export FAKE_JOURNAL_UNIT="$BATS_TEST_TMPDIR/journal.txt"
  fake psql 'case "$*" in *"SELECT 1") echo 1 ;; *) echo "sessions: 1 for s3cret:Passw0rd" ;; esac'
  report
  [ "$status" -eq 0 ]
  unpack "$(json 'd["report"]')"
  run grep -rlE 's3cret:Passw0rd|adm1nPassw0rd|fromTheCommandLine|other1|following2' "$R"
  [ -z "$output" ]
  grep -qx "  -Dxwiki.db.password=<redacted>" "$R/jvm.txt"
  grep -qx "  -Dkeystore.Secret=<redacted>" "$R/jvm.txt"
  grep -qx "  -Dharmless=shown" "$R/jvm.txt"
  grep -qx "  -Dnote=<redacted> in a value" "$R/jvm.txt"
  grep -q "login of Admin with <redacted> and of the database with <redacted> failed" "$R/journal.txt"
  grep -q "sessions: 1 for <redacted>" "$R/summary.txt"
  # Nor on a command line.
  run grep -lE 's3cret|adm1nPassw0rd' "$FAKEBIN"/*.calls
  [ -z "$output" ]
}

@test "report: a password too short to be told from a word is left where it shows" {
  credentials 'xwiki'
  report
  unpack "$(json 'd["report"]')"
  grep -q "/xwiki/bin/view" "$R/summary.txt"
  run ! grep -rq "<redacted>" "$R"
}

@test "report: only the last REPORT_KEEP reports are kept" {
  conf <<<"REPORT_KEEP=2"
  XINIT_TEST_NOW=$((NOW + 60)) report
  first="$(json 'd["report"]')"
  XINIT_TEST_NOW=$((NOW + 120)) report
  XINIT_TEST_NOW=$((NOW + 180)) report
  [ "$status" -eq 0 ]
  [ "$(ls "$REPORTS" | wc -l)" = 2 ]
  [ ! -e "$first" ]
  [ -e "$(json 'd["report"]')" ]
  [ -z "$(find "$REPORTS" -mindepth 1 ! -name 'report-*.tar.gz')" ]
}

@test "report: --output writes the archive there, and never over a file" {
  out="$BATS_TEST_TMPDIR/out.tar.gz"
  report --output "$out"
  [ "$status" -eq 0 ]
  [ "$(json 'd["report"]')" = "$out" ]
  [ "$(stat -c %a "$out")" = 600 ]
  tar -tzf "$out" | grep -q "/summary.txt$"
  [ ! -e "$REPORTS" ]
  echo mine >"$BATS_TEST_TMPDIR/mine"
  report --output "$BATS_TEST_TMPDIR/mine"
  [ "$status" -eq 3 ]
  [ "$(cat "$BATS_TEST_TMPDIR/mine")" = mine ]
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$BATS_TEST_TMPDIR/link"
  report --output "$BATS_TEST_TMPDIR/link"
  [ "$status" -eq 3 ]
  [ ! -e "$BATS_TEST_TMPDIR/elsewhere" ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "report: without a JVM, the report holds the rest" {
  export FAKE_UNIT_STOPPED=1
  report
  [ "$status" -eq 0 ]
  [ "$(json 'd["status"]')" = crit ]
  [ "$(json 'd["thread_dumps"]')" = 0 ]
  [ "$(section threads)" = "skipped: no JVM is running" ]
  [ "$(section jvm)" = "skipped: no JVM is running" ]
  [ "$(section journal)" = ok ]
  [ -z "$(calls kill)" ]
  unpack "$(json 'd["report"]')"
  grep -qx "JVM: not running" "$R/summary.txt"
  grep -q "^  threads: no JVM is running$" "$R/summary.txt"
  [ ! -e "$R/threads" ]
}

@test "report: a JVM that writes no thread dump is asked once" {
  export FAKE_JOURNAL_UNIT="$FIXTURES/journal/heap-oom-unit.txt"
  report
  [ "$status" -eq 0 ]
  [ "$(json 'd["thread_dumps"]')" = 0 ]
  [ "$(section threads)" = "skipped: the JVM wrote no thread dump" ]
  [ "$(calls kill)" = "-s QUIT 98" ]
}

@test "report: a user who may not read the journal gets a report without it" {
  export FAKE_JOURNAL_DENIED=1
  report
  [ "$status" -eq 0 ]
  [[ "$(section journal)" == "skipped: the journal cannot be read: "* ]]
  [[ "$(section threads)" == "skipped: the journal cannot be read: "* ]]
}

@test "report: a job that is not root asks root for each thread dump" {
  export FAKE_UID=995 FAKE_STATE_OWNER=995:995 FAKE_USER=xinit FAKE_ACT=1
  report
  [ "$status" -eq 0 ]
  [ "$(json 'd["thread_dumps"]')" = 3 ]
  [ -z "$(calls kill)" ]
  [ "$(cat "$FAKEBIN/requests.log")" = "request-thread-dump
request-thread-dump
request-thread-dump" ]
  [ -e "$(json 'd["report"]')" ]
}

@test "report: root builds it, and the owner of the state directory stores it" {
  mkdir -p "$XINIT_STATE_DIR"
  export FAKE_STATE_OWNER=990:985
  fake setsid '[ "$1" = --wait ] && shift; exec "$@"'
  # The paths are written out: that user gets no variable of the test's environment.
  fake setpriv "cat >'$FAKEBIN/stored.tar.gz'; env >'$FAKEBIN/setpriv.env'; echo /somewhere/report-1.tar.gz"
  export SECRET_OF_ROOT=hunter2
  run --separate-stderr "$XINIT" -i default report --format json
  [ "$status" -eq 0 ]
  [ "$(json 'd["report"]')" = "/somewhere/report-1.tar.gz" ]
  [ "$(calls setpriv)" = "--reuid=990 --regid=985 --clear-groups -- $XINIT -i default report --format json --store" ]
  # The owner got the archive, and nothing of root's environment.
  tar -tzf "$FAKEBIN/stored.tar.gz" | grep -q "/threads/dump-3.txt$"
  run ! grep -q "SECRET_OF_ROOT\|^HOME=" "$FAKEBIN/setpriv.env"
  # Root itself wrote nothing there, and asked the JVM itself.
  [ -z "$(ls -A "$XINIT_STATE_DIR")" ]
  [ "$(calls kill | wc -l)" = 3 ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "report: when the owner cannot store it, there is no report" {
  mkdir -p "$XINIT_STATE_DIR"
  export FAKE_STATE_OWNER=990:985
  fake setsid '[ "$1" = --wait ] && shift; exec "$@"'
  fake setpriv 'cat >/dev/null; exit 3'
  report
  [ "$status" -eq 3 ]
  # shellcheck disable=SC2154  # $stderr is set by bats' run
  [[ "$stderr" == *"could not store the report"* ]]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "report: --store puts what it reads with the reports, and prints where" {
  conf <<<"REPORT_KEEP=1"
  mkdir -p "$REPORTS"
  echo old >"$REPORTS/report-20200101T000000Z.tar.gz"
  run --separate-stderr "$XINIT" report --store < <(echo "an archive")
  [ "$status" -eq 0 ]
  [ "$output" = "$REPORTS/report-20270115T080000Z.tar.gz" ]
  [ "$(cat "$output")" = "an archive" ]
  [ "$(stat -c %a "$output")" = 600 ]
  [ "$(ls "$REPORTS")" = "report-20270115T080000Z.tar.gz" ]
  [ -z "$(calls kill)$(calls curl)" ]
}

@test "report: when a host name does not resolve, the report says what the resolver answers" {
  export FAKE_CURL_EXIT=6 FAKE_CURL_ERROR="Could not resolve host: localhost"
  mkdir -p "$XINIT_ROOT/etc"
  printf '# a comment\nnameserver 192.0.2.53\n' >"$XINIT_ROOT/etc/resolv.conf"
  report
  [ "$status" -eq 0 ]
  [ "$(section dns)" = ok ]
  [ "$(calls getent)" = "ahosts localhost" ]
  unpack "$(json 'd["report"]')"
  grep -q "no answer: status 2" "$R/dns.txt"
  grep -qx "  nameserver 192.0.2.53" "$R/dns.txt"
  run ! grep -q "a comment" "$R/dns.txt"
}

@test "report: the text of the queries of PostgreSQL is only asked for with REPORT_DB_QUERIES" {
  credentials "s3cretPassw0rd"
  report
  [ "$(section database)" = ok ]
  [[ "$(calls psql)" == *"FROM pg_stat_activity"* ]]
  [[ "$(calls psql)" != *"AS query"* ]]
  [ "$(cat "$FAKEBIN/psql.env" | sort -u)" = "PGPASSFILE=$XINIT_CONF_DIR/credentials/default.pgpass" ]
  conf <<<"REPORT_DB_QUERIES=yes"
  report
  [[ "$(calls psql)" == *"AS query"* ]]
}

@test "report: the text of the queries of MariaDB is left out without REPORT_DB_QUERIES" {
  use_other_fixture tomcat11-mariadb
  mkdir -p "$XINIT_CONF_DIR/credentials"
  printf '[client]\npassword="s3cretPassw0rd"\n' >"$XINIT_CONF_DIR/credentials/default.my.cnf"
  fake mariadb '
    case "$*" in
      *PROCESSLIST*)
        printf "Id\tUser\tHost\tdb\tCommand\tTime\tState\tInfo\tProgress\n"
        printf "5\txwiki\tlocalhost\txwiki\tSleep\t12\t\tNULL\t0.000\n"
        printf "6\txwiki\tlocalhost\txwiki\tQuery\t42\tSending data\tSELECT secret_column FROM t\t0.000\n"
        printf "7\txwiki\tlocalhost\txwiki\tQuery\t0\tstarting\tSHOW FULL PROCESSLIST\t0.000\n" ;;
      *) printf "db\tsize_mb\nxwiki\t150\n" ;;
    esac'
  report
  [ "$status" -eq 0 ]
  [ "$(section database)" = ok ]
  unpack "$(json 'd["report"]')"
  grep -qx "Database (mariadb): sessions: 2, running a query: 1, longest for: 42 s" "$R/summary.txt"
  grep -q "Sending data" "$R/database.txt"
  grep -q "^xwiki.150$" "$R/database.txt"
  run ! grep -rq "secret_column" "$R"
  conf <<<"REPORT_DB_QUERIES=yes"
  report
  unpack "$(json 'd["report"]')"
  grep -q "SELECT secret_column FROM t" "$R/database.txt"
  run ! grep -q "secret_column" "$R/summary.txt"
}

@test "report: a database that does not answer leaves a report without it" {
  credentials "s3cretPassw0rd"
  export FAKE_DB_LOGIN_ERROR="psql: error: connection refused"
  report
  [ "$status" -eq 0 ]
  [ "$(section database)" = "skipped: the database did not answer: psql: error: connection refused" ]
  rm "$XINIT_CONF_DIR/credentials/default.pgpass"
  report
  [[ "$(section database)" == "skipped: no credentials file "* ]]
}

@test "report: an out-of-memory error shows in the result" {
  export FAKE_JOURNAL_UNIT="$FIXTURES/journal/heap-oom-unit.txt" FAKE_JVM_AGE=600
  report
  [ "$status" -eq 0 ]
  [ "$(json 'd["oom"]')" = True ]
}

@test "report: the text output is the summary, then the file" {
  run --separate-stderr "$XINIT" report
  [ "$status" -eq 0 ]
  [[ "$output" == "XWiki diagnostics report, by xinit "*"Instance: default"*"Checks:"*"overall: ok"* ]]
  [ "$(printf '%s\n' "$output" | tail -n 1)" = "report: $REPORTS/report-20270115T080000Z.tar.gz" ]
}

@test "report: a wrong configuration or argument stops it before anything is done" {
  for line in REPORT_KEEP=0 REPORT_KEEP=many REPORT_JOURNAL_LINES=all THREADDUMP_INTERVAL=1h \
    THREADDUMP_INTERVAL=soon REPORT_DB_QUERIES=maybe; do
    conf <<<"$line"
    report
    [ "$status" -eq 3 ]
    # shellcheck disable=SC2154  # $stderr is set by bats' run
    [[ "$stderr" == *"${line%%=*} has to be"* ]]
  done
  conf </dev/null
  report --format xml
  [ "$status" -eq 64 ]
  report --output
  [ "$status" -eq 64 ]
  report extra
  [ "$status" -eq 64 ]
  [ -z "$(calls kill)" ]
  [ ! -e "$REPORTS" ]
}

@test "report: without an installation there is nothing to report on" {
  rm -rf "$XINIT_ROOT/cmd/dpkg-query.txt" "$XINIT_ROOT"/cmd/systemctl-show-*
  : >"$XINIT_ROOT/cmd/dpkg-query.txt"
  report
  [ "$status" -eq 3 ]
  [ "$(json 'd["results"][0]["reason"]')" = no-installation ]
  [ ! -e "$REPORTS" ]
}
