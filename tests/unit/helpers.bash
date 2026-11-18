# shellcheck shell=bash
# Helpers for the unit tests (`load helpers`). Unit tests run on the host, without Docker: the
# external commands xinit calls (systemctl, dpkg-query, curl, psql, jcmd...) are replaced by fakes,
# and their inputs are real files copied from the test images into tests/fixtures/.

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
#   - XINIT_CONF_DIR is an empty directory: no configuration.
# FAKE_UNIT_STOPPED=1 makes the fake systemctl report every unit as stopped.
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
    sed -n "s/^$property=//p" "$file"'
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
