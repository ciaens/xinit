#!/usr/bin/env bats
# `xinit layout` on a real installation. Scenarios S-LAYOUT-* of docs/TESTING.md.

load helpers

setup_file() {
  wait_healthy 300
}

setup() {
  xinit_conf
}

teardown() {
  # S-LAYOUT-04 and 05 change the installation: put it back whatever happened.
  local dir="/etc/${XT_UNIT%.service}/Catalina/localhost"
  if in_env test -e "$dir/ROOT.xml"; then
    in_env systemctl stop "$XT_UNIT"
    in_env mv "$dir/ROOT.xml" "$dir/xwiki.xml"
  fi
  if [ "$(in_env systemctl is-active "$XT_UNIT")" != active ]; then
    in_env systemctl start "$XT_UNIT"
    wait_healthy 300
  fi
}

value() { json "d['layout']['$1']['value']"; }
source_of() { json "d['layout']['$1']['source']"; }

# expect <KEY> <value> [source, default "detected"]
expect() {
  local got
  got="$(value "$1")"
  [ "$got" = "$2" ] || { echo "$1: expected '$2', got '$got'"; return 1; }
  got="$(source_of "$1")"
  [ "$got" = "${3:-detected}" ] || { echo "$1: expected source '${3:-detected}', got '$got'"; return 1; }
}

# expected_db_type: the DB_TYPE of this variant.
expected_db_type() {
  case "$XT_VARIANT" in
    *-pgsql | *-pgsql-*) echo postgresql ;;
    *-mariadb | *-mariadb-*) echo mariadb ;;
    *-mysql | *-mysql-*) echo mysql ;;
  esac
}

@test "S-LAYOUT-01 a Debian package installation is found with no configuration" {
  is_war && skip "not a package installation"
  [ -z "$(in_env cat "$XT_XINIT_CONF_DIR/xinit.conf")" ]
  xinit layout --format json
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  case "$XT_VARIANT" in
    xjetty-*) expect PROFILE debian-xjetty ;;
    *) expect PROFILE debian-tomcat ;;
  esac
  expect UNIT "$XT_UNIT"
  expect WEBAPP_DIR /usr/lib/xwiki
  expect CONFIG_DIR /etc/xwiki
  expect PERMDIR /var/lib/xwiki/data
  expect BASE_URL "$XT_BASE_URL"
  expect DB_TYPE "$(expected_db_type)"
  expect DB_HOST localhost
  expect DB_NAME xwiki
  expect DB_USER xwiki
  # shellcheck disable=SC2016  # ${Version} is dpkg-query's own format syntax
  expect VERSION "$(in_env dpkg-query -W -f '${Version}' xwiki-common)"
  expect VERSION "$(rest_version)"
  expect JVM_PID "$(jvm_pid)"
  expect LOG_SOURCE "journal:$XT_UNIT" default
}

@test "S-LAYOUT-02 a configured value wins, and its source is config" {
  xinit_conf "UNIT=other.service" "BASE_URL=http://localhost:9999/elsewhere/"
  xinit layout --format json
  [ "$status" -eq 0 ]
  expect UNIT other.service config
  expect BASE_URL http://localhost:9999/elsewhere config
  expect DB_TYPE "$(expected_db_type)"
  # The other unit does not exist: no JVM, and no error.
  [ -z "$(value JVM_PID)" ]
}

@test "S-LAYOUT-03 a WAR installation is complete with three lines of configuration" {
  is_war || skip "not a WAR installation"
  [ "$(in_env_sh "wc -l < $XT_XINIT_CONF_DIR/xinit.conf")" -eq 3 ]
  xinit layout --format json
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  expect PROFILE war
  expect UNIT "$XT_UNIT" config
  expect WEBAPP_DIR "$XT_WAR_WEBAPP_DIR" config
  expect BASE_URL "$XT_BASE_URL" config
  expect CONFIG_DIR "$XT_WAR_WEBAPP_DIR/WEB-INF" default
  expect PERMDIR /var/lib/xwiki-war/data
  expect DB_TYPE "$(expected_db_type)"
  expect DB_HOST localhost
  expect DB_NAME xwiki
  expect VERSION "$(rest_version)"
  expect JVM_PID "$(jvm_pid)"
}

@test "S-LAYOUT-03 a WAR installation with no configuration says what to configure" {
  is_war || skip "not a WAR installation"
  in_env_sh ": > $XT_XINIT_CONF_DIR/xinit.conf"
  xinit layout --format json
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"set UNIT, WEBAPP_DIR and BASE_URL"* ]]
  [ -z "$(value PROFILE)" ]
}

@test "S-LAYOUT-04 XWiki served at / (ROOT.xml) has no /xwiki in BASE_URL" {
  [[ "$XT_VARIANT" == tomcat* ]] || skip "only for the Tomcat packages"
  local dir="/etc/${XT_UNIT%.service}/Catalina/localhost" root_url="${XT_BASE_URL%/xwiki}"
  in_env systemctl stop "$XT_UNIT"
  in_env mv "$dir/xwiki.xml" "$dir/ROOT.xml"
  xinit layout --format json
  [ "$status" -eq 0 ]
  expect BASE_URL "$root_url"
  # Tomcat agrees: XWiki answers there.
  in_env systemctl start "$XT_UNIT"
  XT_BASE_URL="$root_url" wait_healthy 300
}

@test "S-LAYOUT-05 with the unit stopped, the layout resolves and JVM_PID is empty" {
  in_env systemctl stop "$XT_UNIT"
  xinit layout --format json
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ -z "$(value JVM_PID)" ]
  [ "$(source_of JVM_PID)" = unknown ]
  expect UNIT "$XT_UNIT" "$(is_war && echo config || echo detected)"
  [ "$(value BASE_URL)" = "$XT_BASE_URL" ]
  [ -n "$(value VERSION)" ]
}

@test "S-LAYOUT-06 an unknown key gives a warning naming it, and exit 0" {
  xinit_conf "BASE_ULR=http://typo"
  xinit layout --format json
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"warning: $XT_XINIT_CONF_DIR/xinit.conf:"*": unknown key BASE_ULR"* ]]
  [ "$(value BASE_URL)" = "$XT_BASE_URL" ]
}
