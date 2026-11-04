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
