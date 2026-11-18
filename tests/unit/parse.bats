#!/usr/bin/env bats
# The readers for XML configuration, Java properties and JDBC URLs, on the real files of the test
# images (tests/fixtures/) and on hand-written edge cases.

load helpers

setup() {
  # shellcheck source=../../lib/xinit/core.sh
  source "$XINIT_REPO/lib/xinit/core.sh"
  # shellcheck source=../../lib/xinit/parse.sh
  source "$XINIT_REPO/lib/xinit/parse.sh"
  T="$BATS_TEST_TMPDIR"
}

# hibernate_of <variant>: the hibernate.cfg.xml of a fixture, wherever its profile puts it.
hibernate_of() { find "$FIXTURES/$1" -name hibernate.cfg.xml; }
properties_of() { find "$FIXTURES/$1" -name xwiki.properties; }
xed_of() { find "$FIXTURES/$1" -name extension.xed; }

# jdbc <url>: print "type|host|port|name".
jdbc() {
  local -A db
  xinit_jdbc_parse "$1" db || return 1
  echo "${db[type]}|${db[host]}|${db[port]}|${db[name]}"
}

# ---- XML comments

@test "xml: comments are removed, on one line or across lines, and lines are kept" {
  cat >"$T/a.xml" <<'XML'
<a><!-- one --><b/><!-- two --></a>
<!-- start
<hidden/>
end --><c/>
<d/>
XML
  run xinit_xml_strip_comments "$T/a.xml"
  [ "$status" -eq 0 ]
  [ "$(xinit_xml_strip_comments "$T/a.xml" | wc -l)" -eq 5 ]
  [ "$(xinit_xml_strip_comments "$T/a.xml" | sed -n 1p)" = "<a><b/></a>" ]
  [ "$(xinit_xml_strip_comments "$T/a.xml" | sed -n 4p)" = "<c/>" ]
  [[ "$output" != *hidden* ]]
}

@test "xml: a comment ends at the first -->, as XML says" {
  printf '<!-- a <!-- b --><shown/> -->\n<!----><also/>\n' >"$T/a.xml"
  run xinit_xml_strip_comments "$T/a.xml"
  [ "${lines[0]}" = "<shown/> -->" ]
  [ "${lines[1]}" = "<also/>" ]
}

@test "xml: a missing file is an error, not an empty result" {
  run xinit_xml_strip_comments "$T/nope.xml"
  [ "$status" -eq 1 ]
  run xinit_xml_property "$T/nope.xml" a
  [ "$status" -eq 1 ]
}

# ---- hibernate.cfg.xml

@test "hibernate: the active database of each fixture is found, not the commented examples" {
  local variant url user driver
  while read -r variant url user driver; do
    run xinit_hibernate_get "$(hibernate_of "$variant")" connection.url
    [ "$status" -eq 0 ] && [ "$output" = "$url" ] || { echo "$variant url: $output"; false; }
    run xinit_hibernate_get "$(hibernate_of "$variant")" connection.username
    [ "$output" = "$user" ] || { echo "$variant user: $output"; false; }
    run xinit_hibernate_get "$(hibernate_of "$variant")" connection.driver_class
    [ "$output" = "$driver" ] || { echo "$variant driver: $output"; false; }
  done <<'TABLE'
tomcat10-pgsql                 jdbc:postgresql:xwiki                         xwiki org.postgresql.Driver
tomcat11-mariadb               jdbc:mariadb://localhost/xwiki?useSSL=false   xwiki org.mariadb.jdbc.Driver
xjetty-pgsql                   jdbc:postgresql:xwiki                         xwiki org.postgresql.Driver
war-tomcat10-pgsql             jdbc:postgresql://localhost:5432/xwiki        xwiki org.postgresql.Driver
tomcat10-mariadb-lts-debian12  jdbc:mariadb://localhost/xwiki?useSSL=false   xwiki org.mariadb.jdbc.Driver
TABLE
}

@test "hibernate: a property in a comment, on several lines, is ignored" {
  cat >"$T/h.xml" <<'XML'
<hibernate-configuration><session-factory>
    <!-- MySQL example
    <property name="hibernate.connection.url">jdbc:mysql://commented/xwiki</property>
    -->
    <property name="hibernate.connection.url">jdbc:postgresql://real:5433/wiki</property>
    <!-- <property name="hibernate.connection.url">jdbc:h2:after</property> -->
</session-factory></hibernate-configuration>
XML
  run xinit_hibernate_get "$T/h.xml" connection.url
  [ "$output" = "jdbc:postgresql://real:5433/wiki" ]
}

@test "hibernate: no prefix, a value on its own line, entities and single quotes are read" {
  cat >"$T/h.xml" <<'XML'
<session-factory>
    <property name="connection.url">
        jdbc:mysql://db/xwiki?useSSL=false&amp;characterEncoding=UTF-8
    </property>
    <property name='connection.username'>wiki&lt;1&gt;</property>
</session-factory>
XML
  run xinit_hibernate_get "$T/h.xml" connection.url
  [ "$output" = "jdbc:mysql://db/xwiki?useSSL=false&characterEncoding=UTF-8" ]
  run xinit_hibernate_get "$T/h.xml" connection.username
  [ "$output" = "wiki<1>" ]
}

@test "hibernate: a property that is absent, or only in a comment, is not found" {
  printf '<a><!-- <property name="hibernate.connection.url">x</property> --></a>\n' >"$T/h.xml"
  run xinit_hibernate_get "$T/h.xml" connection.url
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "hibernate: a name is matched whole, with its dots literal" {
  cat >"$T/h.xml" <<'XML'
<property name="hibernate.connection.urlX">wrong</property>
<property name="hibernateXconnection.url">wrong</property>
<property name="hibernate.connection.url">right</property>
XML
  run xinit_hibernate_get "$T/h.xml" connection.url
  [ "$output" = "right" ]
}

# ---- elements and attributes: Tomcat's server.xml and context file

@test "xml: each Tomcat fixture has one active HTTP connector, on port 8080" {
  local f tag
  for f in "$FIXTURES"/*/etc/tomcat*/server.xml; do
    run xinit_xml_elements "$f" Connector
    [ "${#lines[@]}" -eq 1 ] || { echo "$f: ${#lines[@]} connectors"; false; }
    tag="${lines[0]}"
    # "port", not "redirectPort".
    run xinit_xml_attr "$tag" port
    [ "$output" = 8080 ]
    run xinit_xml_attr "$tag" redirectPort
    [ "$output" = 8443 ]
    run xinit_xml_attr "$tag" SSLEnabled
    [ "$status" -eq 1 ]
  done
}

@test "xml: the package's Tomcat context file gives the webapp directory" {
  local f n=0
  for f in "$FIXTURES"/*/etc/tomcat*/Catalina/localhost/xwiki.xml; do
    n=$((n + 1))
    run xinit_xml_elements "$f" Context
    [ "${#lines[@]}" -eq 1 ]
    run xinit_xml_attr "${lines[0]}" docBase
    [ "$output" = /usr/lib/xwiki ]
  done
  [ "$n" -eq 3 ]
}

@test "xml: an element name is matched whole; attributes may use single quotes and entities" {
  printf "<Connectors/><Connector\n   port = '80'\n   note=\"a &amp; b\" /><Connector/>\n" >"$T/s.xml"
  run xinit_xml_elements "$T/s.xml" Connector
  [ "${#lines[@]}" -eq 2 ]
  local tag="${lines[0]}"
  run xinit_xml_attr "$tag" port
  [ "$output" = 80 ]
  run xinit_xml_attr "$tag" note
  [ "$output" = "a & b" ]
  run xinit_xml_elements "$T/s.xml" Nothing
  [ "$status" -eq 0 ] && [ -z "$output" ]
}

# ---- xwiki.properties

@test "properties: the permanent directory of each fixture is found" {
  local variant dir
  while read -r variant dir; do
    run xinit_properties_get "$(properties_of "$variant")" environment.permanentDirectory
    [ "$status" -eq 0 ] && [ "$output" = "$dir" ] || { echo "$variant: $output"; false; }
  done <<'TABLE'
tomcat10-pgsql                 /var/lib/xwiki/data
tomcat11-mariadb               /var/lib/xwiki/data
xjetty-pgsql                   /var/lib/xwiki/data
war-tomcat10-pgsql             /var/lib/xwiki-war/data
tomcat10-mariadb-lts-debian12  /var/lib/xwiki/data
TABLE
}

@test "properties: a key that only appears in comments is not found" {
  # The stock file documents this key in comments only.
  run xinit_properties_get "$(properties_of tomcat10-pgsql)" extension.localRepository
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "properties: separators, comments, the last definition and whole-key matching" {
  cat >"$T/p.properties" <<'PROPS'
# a.b = commented
! a.b = commented too
a.b.c = longer key
a.bc = other key
a.b = first
  a.b:second with spaces  
colon:1
space 2
empty =
PROPS
  run xinit_properties_get "$T/p.properties" a.b
  [ "$output" = "second with spaces" ]
  run xinit_properties_get "$T/p.properties" colon
  [ "$output" = 1 ]
  run xinit_properties_get "$T/p.properties" space
  [ "$output" = 2 ]
  run xinit_properties_get "$T/p.properties" empty
  [ "$status" -eq 0 ] && [ -z "$output" ]
  run xinit_properties_get "$T/p.properties" a
  [ "$status" -eq 1 ]
  run xinit_properties_get "$T/nope.properties" a
  [ "$status" -eq 1 ]
}

# ---- extension.xed

@test "version: the XWiki version of each fixture is read from extension.xed" {
  local variant version
  while read -r variant version; do
    run xinit_extension_version "$(xed_of "$variant")"
    [ "$output" = "$version" ] || { echo "$variant: $output"; false; }
  done <<'TABLE'
tomcat10-pgsql                 18.9.0
tomcat11-mariadb               18.9.0
xjetty-pgsql                   18.9.0
war-tomcat10-pgsql             18.9.0
tomcat10-mariadb-lts-debian12  17.10.14
TABLE
}

@test "version: the extension's own version is taken, not a dependency's" {
  cat >"$T/extension.xed" <<'XML'
<extension>
    <id>org.xwiki.platform:xwiki-platform-distribution-war</id>
    <version>18.9.0</version>
    <dependencies><dependency><id>x</id><version>1.2.3</version></dependency></dependencies>
</extension>
XML
  run xinit_extension_version "$T/extension.xed"
  [ "$output" = 18.9.0 ]
  run xinit_extension_version "$T/nope.xed"
  [ "$status" -eq 1 ]
}

# ---- JDBC URLs

@test "jdbc: URLs are split into type, host, port and database name" {
  local url expected
  while read -r url expected; do
    run jdbc "$url"
    [ "$status" -eq 0 ] && [ "$output" = "$expected" ] || { echo "$url: $output"; false; }
  done <<'TABLE'
jdbc:postgresql:xwiki                                   postgresql|localhost|5432|xwiki
jdbc:postgresql://localhost:5432/xwiki                  postgresql|localhost|5432|xwiki
jdbc:postgresql://db.example.org/wiki?ssl=true          postgresql|db.example.org|5432|wiki
jdbc:postgresql://db1:5433,db2:5434/wiki                postgresql|db1|5433|wiki
jdbc:postgresql://[::1]:5433/wiki                       postgresql|[::1]|5433|wiki
jdbc:postgresql:///wiki                                 postgresql|localhost|5432|wiki
jdbc:mariadb://localhost/xwiki?useSSL=false             mariadb|localhost|3306|xwiki
jdbc:mysql://10.0.0.5:3307/xwiki?useSSL=false&a=b       mysql|10.0.0.5|3307|xwiki
jdbc:MySQL://localhost/xwiki                            mysql|localhost|3306|xwiki
jdbc:oracle:thin:@localhost:1521:XE                     oracle|localhost|1521|XE
jdbc:oracle:thin:@//ora.example.org:1522/service        oracle|ora.example.org|1522|service
jdbc:hsqldb:file:/var/lib/xwiki/data/database/xwiki_db;shutdown=true   hsqldb|||
jdbc:h2:/var/lib/xwiki/data/database/xwiki              h2|||
TABLE
}

@test "jdbc: text that is not a JDBC URL is refused" {
  run jdbc "postgresql://localhost/xwiki"
  [ "$status" -eq 1 ]
  run jdbc ""
  [ "$status" -eq 1 ]
}

@test "jdbc: the URL of every fixture's hibernate.cfg.xml is understood" {
  local variant expected url
  while read -r variant expected; do
    url="$(xinit_hibernate_get "$(hibernate_of "$variant")" connection.url)"
    run jdbc "$url"
    [ "$output" = "$expected" ] || { echo "$variant: $output"; false; }
  done <<'TABLE'
tomcat10-pgsql                 postgresql|localhost|5432|xwiki
tomcat11-mariadb               mariadb|localhost|3306|xwiki
xjetty-pgsql                   postgresql|localhost|5432|xwiki
war-tomcat10-pgsql             postgresql|localhost|5432|xwiki
tomcat10-mariadb-lts-debian12  mariadb|localhost|3306|xwiki
TABLE
}
