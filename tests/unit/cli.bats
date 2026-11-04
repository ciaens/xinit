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
  mkdir -p "$BATS_TEST_TMPDIR/lib"
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
