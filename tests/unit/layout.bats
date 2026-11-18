#!/usr/bin/env bats
# `xinit layout` on the real files of each test image (tests/fixtures/).

load helpers

# layout [args...]: run `xinit layout --format json`, keeping stderr apart.
layout() { run --separate-stderr "$XINIT" layout --format json "$@"; }
# value <KEY> / source_of <KEY>: from the layout in $output.
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

@test "S-LAYOUT-01 layout: tomcat10-pgsql is found with no configuration" {
  use_fixture tomcat10-pgsql
  layout
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(json "d['instance']")" = default ]
  expect PROFILE debian-tomcat
  expect UNIT tomcat10.service
  expect WEBAPP_DIR /usr/lib/xwiki
  expect CONFIG_DIR /etc/xwiki
  expect PERMDIR /var/lib/xwiki/data
  expect BASE_URL http://localhost:8080/xwiki
  expect LOG_SOURCE journal:tomcat10.service default
  expect DB_TYPE postgresql
  expect DB_HOST localhost
  expect DB_PORT 5432
  expect DB_NAME xwiki
  expect DB_USER xwiki
  expect VERSION 18.9.0
  expect JVM_PID 98
}

@test "S-LAYOUT-01 layout: tomcat11-mariadb is found with no configuration" {
  use_fixture tomcat11-mariadb
  layout
  [ "$status" -eq 0 ]
  expect PROFILE debian-tomcat
  expect UNIT tomcat11.service
  expect BASE_URL http://localhost:8080/xwiki
  expect DB_TYPE mariadb
  expect DB_PORT 3306
  expect VERSION 18.9.0
  [ -n "$(value JVM_PID)" ]
}

@test "S-LAYOUT-01 layout: the LTS on Debian 12 is found with no configuration" {
  use_fixture tomcat10-mariadb-lts-debian12
  layout
  [ "$status" -eq 0 ]
  expect PROFILE debian-tomcat
  expect UNIT tomcat10.service
  expect PERMDIR /var/lib/xwiki/data
  expect DB_TYPE mariadb
  expect VERSION 17.10.14
}

@test "S-LAYOUT-01 layout: xjetty-pgsql is found with no configuration" {
  use_fixture xjetty-pgsql
  layout
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  expect PROFILE debian-xjetty
  expect UNIT xwiki.service
  expect WEBAPP_DIR /usr/lib/xwiki
  expect CONFIG_DIR /etc/xwiki
  expect PERMDIR /var/lib/xwiki/data
  expect BASE_URL http://localhost:8080/xwiki
  expect LOG_SOURCE journal:xwiki.service default
  expect DB_TYPE postgresql
  expect VERSION 18.9.0
  # The unit's main process is the JVM; its bash and sleep children are not.
  expect JVM_PID 76
}

@test "layout: xjetty's port comes from -p in ExecStart, else from JETTY_PORT" {
  use_fixture xjetty-pgsql
  local show="$XINIT_ROOT/cmd/systemctl-show-xwiki.txt"
  sed -i 's/^Environment=.*//' "$show"
  echo 'Environment=FOO=1 JETTY_PORT=8081 BAR=2' >>"$show"
  layout
  expect BASE_URL http://localhost:8081/xwiki
  sed -i 's#start_xwiki.sh --noninteractive ;#start_xwiki.sh --noninteractive -p 9090 ;#' "$show"
  grep -q -- '-p 9090 ;' "$show"
  layout
  expect BASE_URL http://localhost:9090/xwiki
}

@test "S-LAYOUT-02 layout: a configured value wins, and its source is config" {
  use_fixture tomcat10-pgsql
  conf <<'CONF'
UNIT=mytomcat
BASE_URL=https://wiki.example.org/
DB_HOST=db.example.org
CONF
  layout -o PERMDIR=/srv/xwiki/
  [ "$status" -eq 0 ]
  # A unit name without a suffix is a service; a trailing / is dropped.
  expect UNIT mytomcat.service config
  expect BASE_URL https://wiki.example.org config
  expect DB_HOST db.example.org config
  expect PERMDIR /srv/xwiki config
  # What is not configured is still detected.
  expect DB_TYPE postgresql
  expect DB_PORT 5432
  expect LOG_SOURCE journal:mytomcat.service default
}

@test "S-LAYOUT-03 layout: a WAR installation is complete with three lines of configuration" {
  use_fixture war-tomcat10-pgsql
  conf <<'CONF'
UNIT=tomcat10.service
WEBAPP_DIR=/var/lib/tomcat10/webapps/xwiki
BASE_URL=http://localhost:8080/xwiki
CONF
  layout
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  expect PROFILE war
  expect UNIT tomcat10.service config
  expect WEBAPP_DIR /var/lib/tomcat10/webapps/xwiki config
  expect CONFIG_DIR /var/lib/tomcat10/webapps/xwiki/WEB-INF default
  expect PERMDIR /var/lib/xwiki-war/data
  expect BASE_URL http://localhost:8080/xwiki config
  expect LOG_SOURCE journal:tomcat10.service default
  expect DB_TYPE postgresql
  expect DB_HOST localhost
  expect DB_PORT 5432
  expect DB_NAME xwiki
  expect VERSION 18.9.0
  expect JVM_PID 103
}

@test "layout: with no package and no configuration, it says what to configure (exit 3)" {
  use_fixture war-tomcat10-pgsql
  layout
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"no XWiki installation was detected"* ]]
  [[ "$stderr" == *"UNIT, WEBAPP_DIR and BASE_URL in $XINIT_CONF_DIR/xinit.conf"* ]]
  # The output is still a valid layout, with nothing known.
  [ "$(source_of PROFILE)" = unknown ]
  [ -z "$(value PROFILE)" ]
  [ "$(json "len(d['layout'])")" -eq 14 ]
}

@test "layout: an incomplete WAR configuration names the missing keys (exit 3)" {
  use_fixture war-tomcat10-pgsql
  conf <<'CONF'
WEBAPP_DIR=/var/lib/tomcat10/webapps/xwiki
CONF
  layout
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"war installation is incomplete: set UNIT BASE_URL in"* ]]
  expect PROFILE war
  expect VERSION 18.9.0
}

@test "S-LAYOUT-04 layout: XWiki served at / (ROOT.xml) has no /xwiki in BASE_URL" {
  use_fixture tomcat10-pgsql
  local dir="$XINIT_ROOT/etc/tomcat10/Catalina/localhost"
  mv "$dir/xwiki.xml" "$dir/ROOT.xml"
  layout
  [ "$status" -eq 0 ]
  expect BASE_URL http://localhost:8080
}

@test "layout: the context path and the port follow Tomcat's files" {
  use_fixture tomcat10-pgsql
  local dir="$XINIT_ROOT/etc/tomcat10/Catalina/localhost"
  # Another webapp's context file must not be taken for XWiki's.
  echo '<Context docBase="/usr/share/other"/>' >"$dir/aaa.xml"
  mv "$dir/xwiki.xml" "$dir/wiki#prod.xml"
  sed -i 's/<Connector port="8080"/<Connector port="9090"/' "$XINIT_ROOT/etc/tomcat10/server.xml"
  layout
  expect BASE_URL http://localhost:9090/wiki/prod
  sed -i 's/<Connector port="9090"/<Connector port="80"/' "$XINIT_ROOT/etc/tomcat10/server.xml"
  layout
  expect BASE_URL http://localhost/wiki/prod
}

@test "layout: an AJP or TLS connector is not taken for the HTTP port" {
  use_fixture tomcat10-pgsql
  cat >"$XINIT_ROOT/etc/tomcat10/server.xml" <<'XML'
<Server><Service name="Catalina">
  <Connector protocol="AJP/1.3" port="8009" />
  <Connector port="8443" protocol="org.apache.coyote.http11.Http11NioProtocol" SSLEnabled="true" />
  <Connector port="${http.port}" />
  <Connector port="8181" protocol="org.apache.coyote.http11.Http11NioProtocol" />
</Service></Server>
XML
  layout
  expect BASE_URL http://localhost:8181/xwiki
}

@test "layout: without XWiki's context file, BASE_URL is asked for (exit 3)" {
  use_fixture tomcat10-pgsql
  rm "$XINIT_ROOT/etc/tomcat10/Catalina/localhost/xwiki.xml"
  layout
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"debian-tomcat installation is incomplete: set BASE_URL in"* ]]
  expect UNIT tomcat10.service
  layout -o BASE_URL=http://localhost:8080/xwiki
  [ "$status" -eq 0 ]
}

@test "S-LAYOUT-05 layout: with the unit stopped, the layout resolves and JVM_PID is empty" {
  use_fixture tomcat10-pgsql
  export FAKE_UNIT_STOPPED=1
  layout
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ -z "$(value JVM_PID)" ]
  [ "$(source_of JVM_PID)" = unknown ]
  expect UNIT tomcat10.service
  expect BASE_URL http://localhost:8080/xwiki
}

@test "layout: a main process that is not java is not the JVM; PID_FILE can name it" {
  use_fixture tomcat10-pgsql
  echo bash >"$XINIT_ROOT/proc/98/comm"
  layout
  [ "$status" -eq 0 ]
  [ -z "$(value JVM_PID)" ]
  mkdir -p "$XINIT_ROOT/proc/4242" "$XINIT_ROOT/run"
  echo java >"$XINIT_ROOT/proc/4242/comm"
  echo 4242 >"$XINIT_ROOT/run/xwiki.pid"
  layout -o PID_FILE=/run/xwiki.pid
  expect JVM_PID 4242
  # A stale PID file, whose process is gone, gives nothing.
  echo 4243 >"$XINIT_ROOT/run/xwiki.pid"
  layout -o PID_FILE=/run/xwiki.pid
  [ -z "$(value JVM_PID)" ]
}

@test "S-LAYOUT-06 layout: an unknown key gives a warning naming it, and exit 0" {
  use_fixture tomcat10-pgsql
  conf <<'CONF'
BASE_ULR=http://typo
CONF
  layout
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"warning: $XINIT_CONF_DIR/xinit.conf:1: unknown key BASE_ULR"* ]]
  expect BASE_URL http://localhost:8080/xwiki
}

@test "layout: a hibernate.cfg.xml that cannot be read leaves the database unknown, not an error" {
  use_fixture tomcat10-pgsql
  rm "$XINIT_ROOT/etc/xwiki/hibernate.cfg.xml"
  layout
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(source_of DB_TYPE)" = unknown ]
  [ -z "$(value DB_HOST)" ]
  expect PERMDIR /var/lib/xwiki/data
}

@test "layout: an embedded database has a type and no host" {
  use_fixture tomcat10-pgsql
  cat >"$XINIT_ROOT/etc/xwiki/hibernate.cfg.xml" <<'XML'
<session-factory>
  <property name="hibernate.connection.url">jdbc:hsqldb:file:/var/lib/xwiki/data/database/xwiki_db;shutdown=true</property>
</session-factory>
XML
  layout
  [ "$status" -eq 0 ]
  expect DB_TYPE hsqldb
  [ -z "$(value DB_HOST)" ]
}

@test "layout: PROFILE can be forced, and an unknown profile is refused" {
  use_fixture tomcat10-pgsql
  layout -o PROFILE=debian-tomcat
  [ "$status" -eq 0 ]
  expect PROFILE debian-tomcat config
  expect UNIT tomcat10.service
  layout -o PROFILE=websphere
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"PROFILE=websphere is not one of"* ]]
}

@test "layout: a package that is removed but not purged is not an installation" {
  use_fixture tomcat10-pgsql
  sed -i 's/\tii $/\trc /' "$XINIT_ROOT/cmd/dpkg-query.txt"
  layout
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"no XWiki installation was detected"* ]]
}

@test "layout: an instance's file is used with -i" {
  use_fixture tomcat10-pgsql
  echo 'BASE_URL=http://localhost:8080/wiki1' >"$XINIT_CONF_DIR/instances/wiki1.conf"
  echo 'BASE_URL=http://localhost:8080/wiki2' >"$XINIT_CONF_DIR/instances/wiki2.conf"
  layout -i wiki2
  [ "$status" -eq 0 ]
  [ "$(json "d['instance']")" = wiki2 ]
  expect BASE_URL http://localhost:8080/wiki2 config
}

@test "layout: the text format has one line per key" {
  use_fixture tomcat10-pgsql
  run "$XINIT" layout
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 14 ]
  run "$XINIT" layout --format yaml
  [ "$status" -eq 64 ]
}

@test "json: strings are escaped" {
  # shellcheck source=../../lib/xinit/core.sh
  source "$XINIT_REPO/lib/xinit/core.sh"
  # shellcheck source=../../lib/xinit/config.sh
  source "$XINIT_REPO/lib/xinit/config.sh"
  # shellcheck source=../../lib/xinit/layout.sh
  source "$XINIT_REPO/lib/xinit/layout.sh"
  local text
  for text in 'plain' 'quote " and \ backslash' $'line\nbreak\ttab\rcr' $'bell\a escape\e' \
    'a & b <c>' 'é ü 日本' ''; do
    run xinit_json_string "$text"
    [ "$(json d)" = "$text" ] || { echo "wrong: $output"; false; }
  done
}
