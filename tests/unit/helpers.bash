# shellcheck shell=bash
# Helpers for the unit tests (`load helpers`). Unit tests run on the host, without Docker: the
# external commands xinit calls (systemctl, dpkg-query, curl, psql, jcmd...) are replaced by fakes,
# and their inputs are real files copied from the test images into tests/fixtures/.

# For run --separate-stderr.
bats_require_minimum_version 1.5.0

XINIT_REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
XINIT="$XINIT_REPO/bin/xinit"
FIXTURES="$XINIT_REPO/tests/fixtures"
export XINIT_REPO XINIT FIXTURES

# A directory for fake commands, first on PATH, fresh for every test.
setup_fakes() {
  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$FAKEBIN"
  PATH="$FAKEBIN:$PATH"
  export FAKEBIN PATH
}

# fake <command> <script body>: a fake command that runs the body with bash. Each call is
# appended to $FAKEBIN/<command>.calls (one line of arguments per call), so tests can assert how
# xinit called it.
fake() {
  local cmd="$1" body="$2"
  [ -n "${FAKEBIN:-}" ] || setup_fakes
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/%s.calls"\n%s\n' \
    "$FAKEBIN" "$cmd" "$body" > "$FAKEBIN/$cmd"
  chmod +x "$FAKEBIN/$cmd"
}

# calls <command>: the recorded calls of a fake, one per line.
calls() { cat "$FAKEBIN/$1.calls" 2>/dev/null || true; }

# use_fixture <variant>: run xinit against a copy of tests/fixtures/<variant>.
#   - XINIT_ROOT is the copy, so tests may change its files;
#   - systemctl and dpkg-query are fakes that replay the fixture's cmd/ outputs;
#   - the processes of cmd/ps-unit-user.txt exist under $XINIT_ROOT/proc;
#   - XINIT_CONF_DIR is an empty directory: no configuration;
#   - curl, ps, df and journalctl are fakes of a healthy instance, which these variables change:
#       FAKE_UNIT_STOPPED=1      systemctl reports every unit as stopped
#       FAKE_UNIT_STATE=<state>  systemctl reports this ActiveState
#       FAKE_JVM_AGE=<seconds>   ps: how long the JVM has been running (default: one day)
#       FAKE_CURL_EXIT / _ERROR  curl fails with this exit code and message
#       FAKE_CURL_CODE / _TIME / _REDIRECT   the answer to a page request (default: 200 in 0.25s)
#       FAKE_REST_CODE / _BODY   the answer to a /rest/ request (default: 200 and the version)
#       FAKE_DF_FREE / FAKE_DF_IFREE   free blocks and inodes, out of 1000000 (default: 500000)
#       FAKE_JOURNAL_UNIT=<file>     journalctl -u: the unit's messages (default: none)
#       FAKE_JOURNAL_SYSTEM=<file>   journalctl: the kernel's and systemd's messages
#       FAKE_JOURNAL_DENIED=1        journalctl answers as to a user who may not read the journal
#       FAKE_DB_TCP=refused|timeout|dns   the database port does not accept connections
#       FAKE_DB_LOGIN_ERROR=<message>     psql and mariadb fail with this message
use_fixture() {
  local variant="$1" pid _ppid _user comm
  XINIT_ROOT="$BATS_TEST_TMPDIR/root"
  XINIT_CONF_DIR="$BATS_TEST_TMPDIR/etc-xinit"
  FIXTURE="$FIXTURES/$variant"
  mkdir -p "$XINIT_CONF_DIR/instances"
  cp -r "$FIXTURE" "$XINIT_ROOT"
  export XINIT_ROOT XINIT_CONF_DIR FIXTURE
  while read -r pid _ppid _user comm; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    mkdir -p "$XINIT_ROOT/proc/$pid"
    echo "$comm" >"$XINIT_ROOT/proc/$pid/comm"
  done <"$FIXTURE/cmd/ps-unit-user.txt"

  fake dpkg-query 'cat "$XINIT_ROOT/cmd/dpkg-query.txt"'
  # systemctl show -p <property> --value <unit>
  fake systemctl '
    [ "$1" = show ] || exit 1
    shift
    property="" unit=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -p) property="$2"; shift 2 ;;
        --value) shift ;;
        *) unit="$1"; shift ;;
      esac
    done
    file="$XINIT_ROOT/cmd/systemctl-show-${unit%.service}.txt"
    if [ ! -f "$file" ]; then
      case "$property" in
        MainPID) echo 0 ;;
        LoadState) echo not-found ;;
        ActiveState) echo inactive ;;
        *) echo ;;
      esac
      exit 0
    fi
    if [ -n "${FAKE_UNIT_STOPPED:-}" ]; then
      case "$property" in
        MainPID) echo 0; exit 0 ;;
        ActiveState) echo inactive; exit 0 ;;
        SubState) echo dead; exit 0 ;;
      esac
    fi
    if [ -n "${FAKE_UNIT_STATE:-}" ] && [ "$property" = ActiveState ]; then
      echo "$FAKE_UNIT_STATE"
      exit 0
    fi
    sed -n "s/^$property=//p" "$file"'

  # ps -o etimes= -p <pid>
  fake ps 'echo "  ${FAKE_JVM_AGE:-86400}"'

  # curl: what xinit_http_get expects from the real one. The body goes to stdout unless
  # -o /dev/null is given, errors go to stderr, and the -w line comes last.
  fake curl '
    url="${!#}" body=1
    for arg in "$@"; do [ "$arg" = /dev/null ] && body=""; done
    if [ -n "${FAKE_CURL_EXIT:-}" ]; then
      echo "curl: ($FAKE_CURL_EXIT) ${FAKE_CURL_ERROR:-failed}" >&2
      printf "\nXINIT-HTTP\t000\t%s\t\n" "${FAKE_CURL_TIME:-0.001000}"
      exit "$FAKE_CURL_EXIT"
    fi
    case "$url" in
      */rest/)
        [ -n "$body" ] && printf "%s" "${FAKE_REST_BODY-{\"links\":[],\"version\":\"18.9.0\",\"syntaxes\":[]\}}"
        printf "\nXINIT-HTTP\t%s\t0.020000\t\n" "${FAKE_REST_CODE:-200}"
        ;;
      *)
        [ -n "$body" ] && printf "<html>a page</html>"
        printf "\nXINIT-HTTP\t%s\t%s\t%s\n" "${FAKE_CURL_CODE:-200}" "${FAKE_CURL_TIME:-0.250000}" \
          "${FAKE_CURL_REDIRECT:-}"
        ;;
    esac'

  # df -P -k <path> / df -P -i <path>
  fake df '
    case " $* " in
      *" -i "*)
        echo "Filesystem Inodes IUsed IFree IUse% Mounted on"
        echo "/dev/fake 1000000 x ${FAKE_DF_IFREE:-500000} x% /" ;;
      *)
        echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
        echo "/dev/fake 1000000 x ${FAKE_DF_FREE:-500000} x% /" ;;
    esac'
  mkdir -p "$XINIT_ROOT/var/lib/xwiki/data" "$XINIT_ROOT/var/lib/xwiki-war/data"

  # journalctl --no-pager -o cat -u <unit> --since ... | ... --since ... _TRANSPORT=kernel + _PID=1
  fake journalctl '
    if [ -n "${FAKE_JOURNAL_DENIED:-}" ]; then
      echo "No journal files were opened due to insufficient permissions." >&2
      exit 0
    fi
    # -n 0: no message, only what journalctl itself has to say.
    case " $* " in *" -n 0 "*) exit 0 ;; esac
    case " $* " in
      *" -u "*) [ -z "${FAKE_JOURNAL_UNIT:-}" ] || cat "$FAKE_JOURNAL_UNIT" ;;
      *" _TRANSPORT=kernel "*) [ -z "${FAKE_JOURNAL_SYSTEM:-}" ] || cat "$FAKE_JOURNAL_SYSTEM" ;;
    esac'

  # timeout <seconds> bash -c <open a TCP connection> _ <host> <port>: the database port probe.
  fake timeout '
    case "${FAKE_DB_TCP:-}" in
      refused) echo "bash: connect: Connection refused" >&2; exit 1 ;;
      dns) echo "bash: line 1: db.invalid: Name or service not known" >&2; exit 1 ;;
      timeout) exit 124 ;;
    esac'

  # The database clients: they answer 1 to SELECT 1, and record where the password came from.
  fake psql '
    echo "PGPASSFILE=${PGPASSFILE:-}" >>"$FAKEBIN/psql.env"
    if [ -n "${FAKE_DB_LOGIN_ERROR:-}" ]; then echo "$FAKE_DB_LOGIN_ERROR" >&2; exit 2; fi
    echo 1'
  fake mariadb '
    if [ -n "${FAKE_DB_LOGIN_ERROR:-}" ]; then echo "$FAKE_DB_LOGIN_ERROR" >&2; exit 1; fi
    echo 1'
}

# use_other_fixture <variant>: start again from another fixture, in the same test.
use_other_fixture() {
  rm -rf "$XINIT_ROOT" "$XINIT_CONF_DIR"
  rm -f "$FAKEBIN"/*.calls "$FAKEBIN"/*.env
  use_fixture "$1"
}

# use_state: give xinit an empty configuration, state and runtime directories of its own, a fixed
# clock ($NOW), and a fake logger. For the commands that need no XWiki installation.
use_state() {
  XINIT_CONF_DIR="$BATS_TEST_TMPDIR/etc-xinit"
  XINIT_STATE_DIR="$BATS_TEST_TMPDIR/state"
  XINIT_RUN_DIR="$BATS_TEST_TMPDIR/run"
  NOW=1800000000
  XINIT_TEST_NOW="$NOW"
  mkdir -p "$XINIT_CONF_DIR/instances"
  export XINIT_CONF_DIR XINIT_STATE_DIR XINIT_RUN_DIR XINIT_TEST_NOW NOW
  fake logger ''
}

# conf <<EOF ... : write the configuration, $XINIT_CONF_DIR/xinit.conf.
conf() { cat >"$XINIT_CONF_DIR/xinit.conf"; }

# json <python expression on d>: evaluate it on $output parsed as JSON, and print the result.
# A null prints as an empty line.
json() {
  # shellcheck disable=SC2154  # $output is set by bats' run
  printf '%s\n' "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
r = eval(sys.argv[1])
print("" if r is None else r)' "$1"
}
