#!/usr/bin/env bash
# Runs INSIDE a test container (systemd as PID 1), as root. Installs one XWiki Debian package and
# provisions the wiki so that no human has to go through the Distribution Wizard:
#   - the main wiki flavor is installed through the REST install job,
#   - XWiki.Admin (password "admin") has admin + programming rights and is in XWikiAdminGroup,
#   - XWiki.standard (password "standard") is a plain user,
#   - superadmin is disabled again at the end.
#
# Usage: provision.sh <package>     e.g. provision.sh xwiki-tomcat10-pgsql
#
# Non-obvious facts this relies on:
# - The xwiki-*-{pgsql,mysql,mariadb} packages create the database from their maintainer scripts
#   (dbconfig-common), so the database server must be running while the package is configured.
# - On a fresh wiki every request, REST included, is redirected to the Distribution Wizard unless
#   distribution.automaticStartOnMainWiki=false.
# - The flavor's pages name XWiki.Admin as their author: without that user their scripts do not
#   render ("the execution of the [velocity] script macro is not allowed").
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[provision] $*"; }

PACKAGE="${1:-}"
[[ "$PACKAGE" =~ ^xwiki-(tomcat[0-9]+|xjetty)-(pgsql|mysql|mariadb)$ ]] \
  || die "expected a package like xwiki-tomcat10-pgsql or xwiki-xjetty-mariadb, got '$PACKAGE'"
CONTAINER="${BASH_REMATCH[1]}"

case "$CONTAINER" in
  xjetty) SERVICE=xwiki.service ;;
  *)      SERVICE="$CONTAINER.service" ;;
esac
BASE_URL="http://localhost:8080/xwiki"
REST="$BASE_URL/rest/wikis/xwiki"
SU=(-u superadmin:system)

code() { curl -s -o /dev/null -w '%{http_code}' "$@" || true; }
# wait_for <expected codes> <tries, 3s apart> <curl args...>
wait_for() {
  local expected="$1" tries="$2" c i
  shift 2
  for ((i = 1; i <= tries; i++)); do
    c="$(code --max-time 30 "$@")"
    [[ " $expected " == *" $c "* ]] && return 0
    sleep 3
  done
  echo "last HTTP code: $c" >&2
  return 1
}

log "installing $PACKAGE"
curl -fsSL https://maven.xwiki.org/public.gpg -o /usr/share/keyrings/xwiki-keyring.gpg
chmod 644 /usr/share/keyrings/xwiki-keyring.gpg
apt-get update -q
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -q "$PACKAGE"
# Re-run the hooks now that Java is installed, so its trust store holds any extra local CA.
update-ca-certificates >/dev/null 2>&1 || true
VERSION="$(dpkg-query -W -f='${Version}' xwiki-common)"
VERSION="${VERSION%%-*}"
log "XWiki $VERSION installed, service $SERVICE"
systemctl enable "$SERVICE" >/dev/null 2>&1 || true

log "enabling superadmin and disabling the wizard's automatic start"
sed -i 's/^# *xwiki.superadminpassword=system/xwiki.superadminpassword=system/' /etc/xwiki/xwiki.cfg
grep -q '^xwiki.superadminpassword=system' /etc/xwiki/xwiki.cfg \
  || die "no '# xwiki.superadminpassword=system' line in /etc/xwiki/xwiki.cfg"
grep -q '^distribution.automaticStartOnMainWiki=false' /etc/xwiki/xwiki.properties \
  || echo 'distribution.automaticStartOnMainWiki=false' >> /etc/xwiki/xwiki.properties
systemctl restart "$SERVICE"

log "waiting for XWiki to answer as superadmin (up to 10min)"
wait_for 200 200 "${SU[@]}" "$REST" || die "XWiki did not answer $REST: journalctl -u $SERVICE"

REQUEST="$(mktemp)"
cat > "$REQUEST" <<EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<jobRequest xmlns="http://www.xwiki.org">
  <id><element>extension</element><element>provision</element><element>xinit-test-env</element></id>
  <interactive>false</interactive>
  <remote>false</remote>
  <verbose>true</verbose>
  <property>
    <key>extensions</key>
    <value>
      <list xmlns="" xmlns:ns2="http://www.xwiki.org">
        <org.xwiki.extension.ExtensionId>
          <id>org.xwiki.platform:xwiki-platform-distribution-flavor-mainwiki</id>
          <version class="org.xwiki.extension.version.internal.DefaultVersion" serialization="custom">
            <org.xwiki.extension.version.internal.DefaultVersion>
              <string>$VERSION</string>
            </org.xwiki.extension.version.internal.DefaultVersion>
          </version>
        </org.xwiki.extension.ExtensionId>
      </list>
    </value>
  </property>
  <property><key>interactive</key><value><boolean xmlns="">false</boolean></value></property>
  <property>
    <key>namespaces</key>
    <value><list xmlns=""><string>wiki:xwiki</string></list></value>
  </property>
</jobRequest>
EOF
log "installing the main wiki flavor $VERSION (several minutes)"
# Retried: extensions.xwiki.org / nexus.xwiki.org can time out; each attempt reuses the downloads.
for attempt in 1 2 3 4 5; do
  ANSWER="$(curl -s "${SU[@]}" -X PUT -H 'Content-Type: text/xml' --upload-file "$REQUEST" \
    "$BASE_URL/rest/jobs?jobType=install&async=false" || true)"
  grep -q '<state>FINISHED</state>' <<<"$ANSWER" && ! grep -q '<errorMessage>' <<<"$ANSWER" && break
  [ "$attempt" = 5 ] && die "the flavor install did not finish: $(head -c 500 <<<"${ANSWER:-no answer}")"
  log "flavor install attempt $attempt failed ($(head -c 200 <<<"${ANSWER:-no answer}")), retrying"
done
rm -f "$REQUEST"

P="$REST/spaces/XWiki/pages"
# rest <method> <url> <xml body>: fails unless XWiki answers 200/201/202.
rest() {
  local c
  c="$(code "${SU[@]}" -H 'Content-Type: application/xml' -X "$1" "$2" --data "$3")"
  [[ "$c" =~ ^20[012]$ ]] || die "$1 $2 answered $c"
}
# create_user <name> <password>
create_user() {
  rest PUT "$P/$1" "<page xmlns=\"http://www.xwiki.org\"><title>$1</title>
    <content>{{include reference=\"XWiki.XWikiUserSheet\"/}}</content></page>"
  rest POST "$P/$1/objects" "<object xmlns=\"http://www.xwiki.org\">
    <className>XWiki.XWikiUsers</className>
    <property name=\"first_name\"><value>$1</value></property>
    <property name=\"password\"><value>$2</value></property>
    <property name=\"active\"><value>1</value></property></object>"
  # What registration adds: the user may edit their own profile.
  rest POST "$P/$1/objects" "<object xmlns=\"http://www.xwiki.org\">
    <className>XWiki.XWikiRights</className>
    <property name=\"users\"><value>XWiki.$1</value></property>
    <property name=\"levels\"><value>edit</value></property>
    <property name=\"allow\"><value>1</value></property></object>"
}
# add_to_group <group page> <user>
add_to_group() {
  rest POST "$P/$1/objects" "<object xmlns=\"http://www.xwiki.org\">
    <className>XWiki.XWikiGroups</className>
    <property name=\"member\"><value>XWiki.$2</value></property></object>"
}

log "creating XWiki.Admin (admin) and XWiki.standard (standard)"
create_user Admin admin
create_user standard standard
add_to_group XWikiAllGroup Admin
add_to_group XWikiAllGroup standard
add_to_group XWikiAdminGroup Admin
rest POST "$P/XWikiPreferences/objects" '<object xmlns="http://www.xwiki.org">
  <className>XWiki.XWikiGlobalRights</className>
  <property name="users"><value>XWiki.Admin</value></property>
  <property name="levels"><value>admin,programming</value></property>
  <property name="allow"><value>1</value></property></object>'

log "disabling superadmin"
sed -i 's/^xwiki.superadminpassword=system/# xwiki.superadminpassword=system/' /etc/xwiki/xwiki.cfg
systemctl restart "$SERVICE"
# Guests can read most pages (REST included), so a 200 there proves nothing. The administration
# page tells the three cases apart: 200 for an admin, 403 for a logged-in user without admin
# rights, 302 to the login form for a guest (including wrong or disabled credentials).
ADMIN_PAGE="$BASE_URL/bin/admin/XWiki/XWikiPreferences"
wait_for 200 200 -u Admin:admin "$ADMIN_PAGE" || die "Admin:admin cannot open the administration"
[ "$(code -u standard:standard "$ADMIN_PAGE")" = 403 ] || die "standard:standard does not log in as a plain user"
[ "$(code -u superadmin:system "$ADMIN_PAGE")" = 302 ] || die "superadmin is still enabled"
if curl -s -u Admin:admin "$BASE_URL/bin/view/Main/WebHome" | grep -q "script macro is not allowed"; then
  die "Main.WebHome does not render its scripts: XWiki.Admin lacks programming rights"
fi
log "done: $PACKAGE $VERSION, $BASE_URL, Admin:admin and standard:standard"
