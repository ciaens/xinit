#!/usr/bin/env bats
# etc/xinit.conf.example is the reference of the configuration keys: it has to match the code.

load helpers

setup() {
  local lib
  for lib in core config parse result layout check checks/process checks/http checks/rest \
    checks/oom checks/db checks/disk; do
    # shellcheck disable=SC1090  # the libraries, as bin/xinit sources them
    source "$XINIT_REPO/lib/xinit/$lib.sh"
  done
  EXAMPLE="$XINIT_REPO/etc/xinit.conf.example"
}

@test "example: every configuration key is listed, with its real default" {
  local key
  # What xinit knows, and what the example documents in its commented-out KEY=value lines.
  diff \
    <(for key in "${XINIT_CFG_KEYS[@]}"; do echo "$key=${XINIT_CFG[$key]-}"; done | sort) \
    <(sed -n 's/^#\([A-Z_]*=.*\)$/\1/p' "$EXAMPLE" | sort)
}

@test "example: no key has the environment name of one of xinit's own variables" {
  # XINIT_<KEY> is how the environment sets a key: a shell variable of that name would shadow it.
  local key ref
  for key in "${XINIT_CFG_KEYS[@]}"; do
    ref="XINIT_$key"
    [[ ! -v "$ref" ]] || { echo "$ref is a variable of xinit"; false; }
  done
}

@test "example: once uncommented, it is a valid configuration with no unknown key" {
  export XINIT_CONF_DIR="$BATS_TEST_TMPDIR/etc"
  mkdir -p "$XINIT_CONF_DIR"
  sed 's/^#\([A-Z_]*=\)/\1/' "$EXAMPLE" >"$XINIT_CONF_DIR/xinit.conf"
  run --separate-stderr xinit_config_load
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}
