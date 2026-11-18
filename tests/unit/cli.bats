#!/usr/bin/env bats
# The command-line entry point.

load helpers

@test "cli: version prints the version" {
  run "$XINIT" version
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^xinit\ [0-9]+\.[0-9]+\.[0-9]+ ]]
}

@test "cli: help lists the commands, and is the default" {
  run "$XINIT"
  [ "$status" -eq 0 ]
  for cmd in layout check watch report maint setup; do
    [[ "$output" == *"  $cmd "* ]]
  done
}

@test "cli: an unknown command is a usage error (64), not a check result" {
  run "$XINIT" no-such-command
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown command: no-such-command"* ]]
}

@test "cli: a command that is not implemented yet exits unknown (3)" {
  run "$XINIT" check
  [ "$status" -eq 3 ]
}

@test "cli: works through a symlink, as when installed with one" {
  ln -s "$XINIT" "$BATS_TEST_TMPDIR/xinit"
  run "$BATS_TEST_TMPDIR/xinit" version
  [ "$status" -eq 0 ]
}

@test "cli: XINIT_LIB_DIR overrides where the libraries are read from" {
  cp -r "$XINIT_REPO/lib/xinit" "$BATS_TEST_TMPDIR/lib"
  sed 's/^XINIT_VERSION=.*/XINIT_VERSION="9.9.9-test"/' "$XINIT_REPO/lib/xinit/core.sh" \
    > "$BATS_TEST_TMPDIR/lib/core.sh"
  XINIT_LIB_DIR="$BATS_TEST_TMPDIR/lib" run "$XINIT" version
  [ "$output" = "xinit 9.9.9-test" ]
}

@test "helpers: a fake command shadows the real one and records its calls" {
  fake systemctl 'echo "fake: $1"'
  run systemctl is-active tomcat10
  [ "$output" = "fake: is-active" ]
  [ "$(calls systemctl)" = "is-active tomcat10" ]
}

@test "cli: -i and -o are accepted before and after the command" {
  export XINIT_CONF_DIR="$BATS_TEST_TMPDIR/etc"
  mkdir -p "$XINIT_CONF_DIR/instances"
  touch "$XINIT_CONF_DIR/instances/wiki1.conf"
  run "$XINIT" -i wiki1 version
  [ "$status" -eq 0 ]
  run "$XINIT" version --instance wiki1
  [ "$status" -eq 0 ]
}

@test "cli: a bad -i or -o is a usage error (64)" {
  export XINIT_CONF_DIR="$BATS_TEST_TMPDIR/etc"
  run "$XINIT" layout -i
  [ "$status" -eq 64 ]
  run "$XINIT" layout -i no-such-instance
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown instance no-such-instance"* ]]
  run "$XINIT" -o NOVALUE layout
  [ "$status" -eq 64 ]
  run "$XINIT" -o NO_SUCH_KEY=1 layout
  [ "$status" -eq 64 ]
}

@test "cli: a malformed configuration file stops a command with its file and line" {
  export XINIT_CONF_DIR="$BATS_TEST_TMPDIR/etc"
  mkdir -p "$XINIT_CONF_DIR"
  printf '# ok\nthis is not a setting\n' >"$XINIT_CONF_DIR/xinit.conf"
  run "$XINIT" layout
  [ "$status" -eq 3 ]
  [[ "$output" == *"$XINIT_CONF_DIR/xinit.conf:2: expected KEY=value"* ]]
}
