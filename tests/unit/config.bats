#!/usr/bin/env bats
# The configuration: file grammar, layers, instances.

load helpers

setup() {
  # shellcheck source=../../lib/xinit/core.sh
  source "$XINIT_REPO/lib/xinit/core.sh"
  # shellcheck source=../../lib/xinit/config.sh
  source "$XINIT_REPO/lib/xinit/config.sh"
  export XINIT_CONF_DIR="$BATS_TEST_TMPDIR/etc"
  mkdir -p "$XINIT_CONF_DIR/instances"
  CONF="$XINIT_CONF_DIR/xinit.conf"
  xinit_config_define UNIT
  xinit_config_define BASE_URL
  xinit_config_define HTTP_TIMEOUT 30
}

# conf <<EOF ... : write xinit.conf.
conf() { cat >"$CONF"; }

# load_dump [instance]: load every layer, then print "KEY<tab>source<tab>value" lines.
load_dump() {
  xinit_instance_resolve "${1:-}"
  xinit_config_load
  xinit_config_dump
}

# value <KEY>: the value of a key in $output (the lines of xinit_config_dump).
value() { printf '%s\n' "$output" | awk -F'\t' -v k="$1" '$1 == k { print $3 }'; }
# source_of <KEY>: its source.
source_of() { printf '%s\n' "$output" | awk -F'\t' -v k="$1" '$1 == k { print $2 }'; }

@test "config: a bare value runs to the end of the line and is trimmed" {
  printf 'UNIT=tomcat10.service\n  BASE_URL =  http://localhost:8080/xwiki  \n' >"$CONF"
  run load_dump
  [ "$status" -eq 0 ]
  [ "$(value UNIT)" = "tomcat10.service" ]
  [ "$(value BASE_URL)" = "http://localhost:8080/xwiki" ]
}

@test "config: a quoted value is literal, spaces and # included" {
  conf <<'CONF'
UNIT="my unit # not a comment"
BASE_URL='http://localhost/a "b"'
CONF
  run load_dump
  [ "$status" -eq 0 ]
  [ "$(value UNIT)" = "my unit # not a comment" ]
  [ "$(value BASE_URL)" = 'http://localhost/a "b"' ]
}

@test "config: blank lines and # lines are ignored; a # inside a bare value is kept" {
  conf <<'CONF'

# a comment
   # an indented comment
BASE_URL=http://localhost:8080/xwiki/#fragment # kept too
CONF
  run load_dump
  [ "$status" -eq 0 ]
  [ "$(value BASE_URL)" = "http://localhost:8080/xwiki/#fragment # kept too" ]
}

@test "config: nothing is expanded or executed" {
  local marker="$BATS_TEST_TMPDIR/executed"
  cat >"$CONF" <<CONF
UNIT=\$(touch $marker)
BASE_URL="\`touch $marker\` \$HOME \\\\n"
CONF
  run --separate-stderr load_dump
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
  [ "$(value UNIT)" = "\$(touch $marker)" ]
  [ "$(value BASE_URL)" = "\`touch $marker\` \$HOME \\\\n" ]
  # A hint for a file that used to be sourced by a shell.
  [[ "$stderr" == *"$CONF:1: UNIT is taken literally"* ]]
  [[ "$stderr" == *"$CONF:2: BASE_URL is taken literally"* ]]
}

@test "config: a single-quoted value with a \$ gives no warning" {
  conf <<'CONF'
UNIT='$weird'
CONF
  run --separate-stderr load_dump
  [ "$status" -eq 0 ]
  [ "$(value UNIT)" = '$weird' ]
  [ -z "$stderr" ]
}

@test "config: Windows line endings and a missing final newline are accepted" {
  printf 'UNIT=a.service\r\nBASE_URL="http://x"\r\nHTTP_TIMEOUT=5' >"$CONF"
  run load_dump
  [ "$status" -eq 0 ]
  [ "$(value UNIT)" = "a.service" ]
  [ "$(value BASE_URL)" = "http://x" ]
  [ "$(value HTTP_TIMEOUT)" = "5" ]
}

@test "config: an empty value is a value" {
  conf <<'CONF'
HTTP_TIMEOUT=
CONF
  run load_dump
  [ "$status" -eq 0 ]
  [[ "$output" == *$'HTTP_TIMEOUT\tfile:'"$CONF"$'\t' ]]
}

@test "config: a malformed line is fatal and names the file and the line" {
  local bad
  for bad in 'just some text' 'UNIT="unterminated' "UNIT='a' b" 'UNIT="a"b"' '1UNIT=x' '=x' \
    'export UNIT=x'; do
    printf 'HTTP_TIMEOUT=5\n\n%s\n' "$bad" >"$CONF"
    run load_dump
    [ "$status" -eq 3 ] || { echo "accepted: $bad"; false; }
    [[ "$output" == *"error: $CONF:3: "* ]] || { echo "no file:line for: $bad"; false; }
  done
}

@test "config: an unknown key gives a warning naming it, and is ignored" {
  conf <<'CONF'
UNIT=a.service
UNTI=typo.service
lowercase=x
CONF
  run --separate-stderr load_dump
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"warning: $CONF:2: unknown key UNTI"* ]]
  [[ "$stderr" == *"warning: $CONF:3: unknown key lowercase"* ]]
  [[ "$output" != *UNTI* ]]
  [ "$(value UNIT)" = "a.service" ]
}

@test "config: a key set twice in a file keeps the last value, with a warning" {
  conf <<'CONF'
UNIT=first.service
UNIT=second.service
CONF
  run --separate-stderr load_dump
  [ "$status" -eq 0 ]
  [ "$(value UNIT)" = "second.service" ]
  [[ "$stderr" == *"$CONF:2: UNIT is set again, replacing line 1"* ]]
}

@test "config: a configuration file that cannot be read is fatal" {
  mkdir "$CONF"
  run load_dump
  [ "$status" -eq 3 ]
  [[ "$output" == *"cannot read the configuration file $CONF"* ]]
}

@test "config: with no file at all, the defaults apply" {
  rm -rf "$XINIT_CONF_DIR"
  run load_dump
  [ "$status" -eq 0 ]
  [ "$output" = $'HTTP_TIMEOUT\tdefault\t30' ]
}

@test "config: layers are defaults < xinit.conf < instance < environment < command line" {
  local inst="$XINIT_CONF_DIR/instances/wiki1.conf"
  printf 'HTTP_TIMEOUT=1\nUNIT=global.service\nBASE_URL=http://global\n' >"$CONF"
  printf 'UNIT=instance.service\nBASE_URL=http://instance\n' >"$inst"

  run load_dump wiki1
  [ "$(value HTTP_TIMEOUT)" = 1 ] && [ "$(source_of HTTP_TIMEOUT)" = "file:$CONF" ]
  [ "$(value UNIT)" = instance.service ] && [ "$(source_of UNIT)" = "file:$inst" ]

  export XINIT_UNIT=env.service XINIT_BASE_URL=http://env
  run load_dump wiki1
  [ "$(value UNIT)" = env.service ] && [ "$(source_of UNIT)" = env ]

  XINIT_CLI_OVERRIDES=("UNIT=cli.service" "HTTP_TIMEOUT=a=b")
  run load_dump wiki1
  [ "$status" -eq 0 ]
  [ "$(value UNIT)" = cli.service ] && [ "$(source_of UNIT)" = cli ]
  [ "$(value BASE_URL)" = http://env ] && [ "$(source_of BASE_URL)" = env ]
  [ "$(value HTTP_TIMEOUT)" = "a=b" ]
}

@test "config: only exported XINIT_<KEY> variables of known keys count as environment" {
  # shellcheck disable=SC2034  # read through an indirect reference
  XINIT_UNIT=not-exported.service
  export XINIT_UNKNOWN_KEY=x
  run --separate-stderr load_dump
  [ "$status" -eq 0 ]
  [ "$output" = $'HTTP_TIMEOUT\tdefault\t30' ]
  [ -z "$stderr" ]
}

@test "config: an unknown key in -o is a usage error" {
  # shellcheck disable=SC2034  # read by xinit_config_load
  XINIT_CLI_OVERRIDES=("UNTI=x")
  run load_dump
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown key UNTI"* ]]
}

@test "config: a key named like one of xinit's own environment variables is refused" {
  run xinit_config_define ROOT
  [ "$status" -ne 0 ]
  [[ "$output" == *"ROOT is reserved"* ]]
}

@test "instance: 'default' when there is no instance file" {
  xinit_instance_resolve
  [ "$XINIT_INSTANCE" = default ]
}

@test "instance: the only instance file is chosen without -i" {
  printf 'UNIT=one.service\n' >"$XINIT_CONF_DIR/instances/wiki1.conf"
  run load_dump
  [ "$status" -eq 0 ]
  [ "$(value UNIT)" = one.service ]
}

@test "instance: with several instances, one must be chosen" {
  touch "$XINIT_CONF_DIR/instances/a.conf" "$XINIT_CONF_DIR/instances/b.conf"
  run xinit_instance_resolve
  [ "$status" -eq 64 ]
  [[ "$output" == *"several instances exist (a b)"* ]]
  xinit_instance_resolve b
  [ "$XINIT_INSTANCE" = b ]
  # "default" is always there: it is xinit.conf alone.
  xinit_instance_resolve default
  [ "$XINIT_INSTANCE" = default ]
}

@test "instance: an unknown or invalid name is a usage error" {
  local name
  for name in nope ../etc/passwd 'a b' .hidden; do
    run xinit_instance_resolve "$name"
    [ "$status" -eq 64 ] || { echo "accepted: $name"; false; }
  done
}
