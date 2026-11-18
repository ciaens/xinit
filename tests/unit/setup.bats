#!/usr/bin/env bats
# `xinit setup`: the systemd units, the credentials file and the manifest. Scenarios S-SETUP-* of
# docs/TESTING.md, on fakes.

load helpers

setup() {
  use_fixture tomcat10-pgsql
  fake logger ''
  fake systemd-sysusers ''
  fake chown ''
  SYSTEMD="$XINIT_ROOT/etc/systemd/system"
  MANIFEST="$XINIT_CONF_DIR/setup/default.manifest"
  CREDENTIALS="$XINIT_CONF_DIR/credentials/default.pgpass"
  # A password of its own, with what a credentials file has to escape.
  sed -i 's/REDACTED/s3:cr\\et\&amp;pw/' "$XINIT_ROOT/etc/xwiki/hibernate.cfg.xml"
}

# set_up [args...]: `xinit setup --format json`.
set_up() { run --separate-stderr "$XINIT" setup --format json "$@"; }

# change_of <path under the root>: what setup did, or would do, to this file.
change_of() { json "[f['change'] for f in d['files'] if f['path'] == '$1'][0]"; }

@test "S-SETUP-01 setup: every file is written, listed in the manifest, and the units are enabled" {
  local file
  set_up
  [ "$status" -eq 0 ]
  [ "$(json 'd["action"]')" = setup ]
  [ "$(json 'd["dry_run"]')" = False ]
  [ "$(json 'len(d["files"])')" = 9 ]
  for file in /etc/sysusers.d/xinit.conf /etc/systemd/system/tomcat10.service.d/50-xinit.conf \
    /etc/systemd/system/xinit-watch@default.service /etc/systemd/system/xinit-watch@default.timer \
    /etc/systemd/system/xinit-act@default.path /etc/systemd/system/xinit-act@default.service \
    /etc/systemd/system/xinit-notify@default.service /etc/systemd/system/xinit-warmup@default.service; do
    [ "$(change_of "$file")" = create ] || { echo "$file: $(change_of "$file")"; false; }
    [ -f "$XINIT_ROOT$file" ]
    [ "$(stat -c %a "$XINIT_ROOT$file")" = 644 ]
    grep -qxF "file $XINIT_ROOT$file" "$MANIFEST"
  done
  grep -qxF "unit xinit-watch@default.timer" "$MANIFEST"
  grep -qxF "unit xinit-act@default.path" "$MANIFEST"
  [ "$(stat -c %a "$MANIFEST")" = 644 ]
  [ "$(calls systemd-sysusers)" = "$XINIT_ROOT/etc/sysusers.d/xinit.conf" ]
  [[ "$(calls systemctl)" == *"daemon-reload"*"enable --now xinit-act@default.path xinit-watch@default.timer"* ]]
}

@test "setup: the drop-in restarts a crashed XWiki, notifies the crash and starts the warm-up" {
  set_up
  file="$SYSTEMD/tomcat10.service.d/50-xinit.conf"
  grep -qxF "[Service]" "$file"
  grep -qxF "Restart=on-failure" "$file"
  grep -qxF "RestartSec=10" "$file"
  # Not for a stop that succeeded, nor for one the job asked root for.
  grep -qxF 'ExecStopPost=-+/bin/sh -c '"'"'[ "$$SERVICE_RESULT" = success ] || [ "$$(systemctl show -p ActiveState --value xinit-act@default.service)" = activating ] || systemctl start --no-block xinit-notify@default.service'"'" "$file"
  grep -qxF "ExecStartPost=-+systemctl start --no-block xinit-warmup@default.service" "$file"
  run ! grep -q JDK_JAVA_OPTIONS "$file"
}

@test "S-SETUP-03 setup: the periodic job runs as its own user, confined, every minute" {
  set_up
  file="$SYSTEMD/xinit-watch@default.service"
  grep -qxF "User=xinit" "$file"
  grep -qxF "Group=xinit" "$file"
  grep -qxF "SupplementaryGroups=systemd-journal" "$file"
  grep -qxF "ExecStart=$XINIT -i default watch" "$file"
  grep -qxF "StateDirectory=xinit xinit/default" "$file"
  grep -qxF "StateDirectoryMode=0700" "$file"
  grep -qxF "RuntimeDirectory=xinit/default" "$file"
  grep -qxF "RuntimeDirectoryPreserve=yes" "$file"
  grep -qxF "ProtectSystem=strict" "$file"
  grep -qxF "NoNewPrivileges=yes" "$file"
  # Longer than the longest wait of a run: the thread dump, then a restart of ten minutes.
  grep -qxF "TimeoutStartSec=15min" "$file"
  grep -qxF "OnUnitActiveSec=1min" "$SYSTEMD/xinit-watch@default.timer"
  grep -qxF "WantedBy=timers.target" "$SYSTEMD/xinit-watch@default.timer"
}

@test "S-SETUP-03 setup: root acts for the job through a path unit, on two requests only" {
  set_up
  file="$SYSTEMD/xinit-act@default.path"
  [ "$(grep -c '^PathExists=' "$file")" = 2 ]
  grep -qxF "PathExists=/run/xinit/default/request-thread-dump" "$file"
  grep -qxF "PathExists=/run/xinit/default/request-restart" "$file"
  file="$SYSTEMD/xinit-act@default.service"
  grep -qxF "ExecStart=$XINIT -i default act" "$file"
  run ! grep -q "^User=" "$file"
  # The other units are not root.
  grep -qxF "User=xinit" "$SYSTEMD/xinit-notify@default.service"
  grep -qxF "ExecStart=$XINIT -i default notify crash" "$SYSTEMD/xinit-notify@default.service"
  grep -qxF "User=xinit" "$SYSTEMD/xinit-warmup@default.service"
  grep -qxF "PartOf=tomcat10.service" "$SYSTEMD/xinit-warmup@default.service"
  grep -qxF "After=tomcat10.service" "$SYSTEMD/xinit-warmup@default.service"
}

@test "setup: the credentials of the db check come from XWiki's configuration, for the job only" {
  set_up
  [ "$status" -eq 0 ]
  [ "$(change_of "$CREDENTIALS")" = create ]
  # In a .pgpass, a colon and a backslash are escaped. The XML entity is decoded.
  [ "$(cat "$CREDENTIALS")" = '*:*:*:*:s3\:cr\\et&pw' ]
  [ "$(stat -c %a "$CREDENTIALS")" = 600 ]
  [[ "$(calls chown)" == *"xinit:xinit -- $CREDENTIALS."* ]]
  [[ "$(calls chown)" == *"root:xinit -- $XINIT_CONF_DIR/credentials"* ]]
  [ "$(stat -c %a "$XINIT_CONF_DIR/credentials")" = 750 ]
  # The password is in that file only.
  # shellcheck disable=SC2154  # $stderr is set by bats' run
  [[ "$output$stderr" != *s3*cr* ]]
  run ! grep -rq 's3.*cr' "$SYSTEMD" "$MANIFEST" "$FAKEBIN"
  run "$XINIT" setup --dry-run
  [[ "$output" != *s3*cr* ]]
}

@test "setup: for MariaDB the credentials are a client option file" {
  use_other_fixture tomcat11-mariadb
  fake systemd-sysusers ''
  fake chown ''
  sed -i 's/REDACTED/pa"ss\\word/' "$XINIT_ROOT/etc/xwiki/hibernate.cfg.xml"
  set_up
  [ "$status" -eq 0 ]
  [ "$(cat "$XINIT_CONF_DIR/credentials/default.my.cnf")" = '[client]
password="pa\"ss\\word"' ]
}

@test "setup: a credentials file the administrator wrote is left alone" {
  mkdir -p "$XINIT_CONF_DIR/credentials"
  echo "mine" >"$CREDENTIALS"
  set_up
  [ "$status" -eq 0 ]
  [ "$(json 'len(d["files"])')" = 8 ]
  [ "$(cat "$CREDENTIALS")" = mine ]
  run ! grep -q "$CREDENTIALS" "$MANIFEST"
}

@test "setup: without a password to read, the db check is left to test the port" {
  sed -i '/connection.password/d' "$XINIT_ROOT/etc/xwiki/hibernate.cfg.xml"
  set_up
  [ "$status" -eq 0 ]
  [ ! -e "$CREDENTIALS" ]
  [[ "$(json 'd["warnings"]')" == *"no database password could be read"* ]]
}

@test "setup: run again, nothing changes; a file that differs is updated" {
  set_up
  set_up
  [ "$status" -eq 0 ]
  [ "$(json 'sorted(set(f["change"] for f in d["files"]))')" = "['unchanged']" ]
  echo "# edited" >>"$SYSTEMD/xinit-watch@default.timer"
  set_up --dry-run
  [ "$(change_of /etc/systemd/system/xinit-watch@default.timer)" = update ]
  [ "$(change_of /etc/systemd/system/xinit-act@default.path)" = unchanged ]
  grep -q "# edited" "$SYSTEMD/xinit-watch@default.timer"
  set_up
  run ! grep -q "# edited" "$SYSTEMD/xinit-watch@default.timer"
}

@test "setup: --dry-run writes and runs nothing, and needs no root" {
  export FAKE_UID=1000
  set_up --dry-run
  [ "$status" -eq 0 ]
  [ "$(json 'd["dry_run"]')" = True ]
  [ "$(json 'len(d["files"])')" = 9 ]
  [ "$(json 'len(d["commands"])')" = 3 ]
  [ ! -e "$SYSTEMD" ]
  [ ! -e "$XINIT_CONF_DIR/setup" ]
  [ ! -e "$XINIT_CONF_DIR/credentials" ]
  [ -z "$(calls systemd-sysusers)" ]
  run ! grep -q "enable\|daemon-reload" "$FAKEBIN/systemctl.calls"
  # In text, each file comes with what changes in it.
  run "$XINIT" setup --dry-run
  [[ "$output" == *"create: /etc/systemd/system/xinit-watch@default.timer"* ]]
  [[ "$output" == *"+OnUnitActiveSec=1min"* ]]
  [[ "$output" == *"dry run: nothing was written or run"* ]]
}

@test "setup: only root can install" {
  FAKE_UID=1000 set_up
  [ "$status" -eq 3 ]
  [ ! -e "$SYSTEMD" ]
  FAKE_UID=1000 set_up --undo
  [ "$status" -eq 3 ]
}

@test "setup: a file of the installation that only a group reads gives that group to the job" {
  chmod 640 "$XINIT_ROOT/etc/tomcat10/server.xml"
  FAKE_GROUP=tomcat set_up
  grep -qxF "SupplementaryGroups=systemd-journal tomcat" "$SYSTEMD/xinit-watch@default.service"
  grep -qxF "SupplementaryGroups=systemd-journal tomcat" "$SYSTEMD/xinit-warmup@default.service"
  [[ "$(json 'd["warnings"]')" != *"cannot read"* ]]
}

@test "setup: so does a directory that only a group enters" {
  chmod 750 "$XINIT_ROOT/etc/tomcat10"
  FAKE_GROUP=tomcat set_up
  grep -qxF "SupplementaryGroups=systemd-journal tomcat" "$SYSTEMD/xinit-watch@default.service"
}

@test "setup: a group that would give the job much more than that file is not given" {
  chmod 640 "$XINIT_ROOT/etc/tomcat10/server.xml"
  FAKE_GROUP=root set_up
  [ "$status" -eq 0 ]
  grep -qxF "SupplementaryGroups=systemd-journal" "$SYSTEMD/xinit-watch@default.service"
  [[ "$(json 'd["warnings"]')" == *"cannot read /etc/tomcat10/server.xml"* ]]
}

@test "setup: a file of the installation that no group reads is a warning" {
  # Root reads it all the same; as another user, the layout would already be incomplete.
  [ "$(command id -u)" -eq 0 ] || skip "needs root to read a file without permissions"
  chmod 600 "$XINIT_ROOT/etc/tomcat10/server.xml"
  FAKE_GROUP=tomcat set_up
  [ "$status" -eq 0 ]
  [[ "$(json 'd["warnings"]')" == *"cannot read /etc/tomcat10/server.xml"* ]]
}

@test "setup: an xinit that another user than root can change is a warning" {
  local copy="$BATS_TEST_TMPDIR/opt/xinit"
  mkdir -p "$copy"
  cp -r "$XINIT_REPO/bin" "$XINIT_REPO/lib" "$copy/"
  chmod 777 "$copy/lib"
  run --separate-stderr "$copy/bin/xinit" setup --format json --dry-run
  [ "$status" -eq 0 ]
  [[ "$(json 'd["warnings"]')" == *"where another user than root can change it ($copy/lib)"* ]]
}

@test "setup: a credentials file named by DB_CREDENTIALS is the administrator's to write" {
  conf <<<"DB_CREDENTIALS=$BATS_TEST_TMPDIR/elsewhere/db.pgpass"
  set_up
  [ "$status" -eq 0 ]
  [ "$(json 'len(d["files"])')" = 8 ]
  [ ! -e "$BATS_TEST_TMPDIR/elsewhere" ]
  [ ! -e "$XINIT_CONF_DIR/credentials" ]
  [ -z "$(calls chown)" ]
}

@test "S-SETUP-02 setup: JVM_OPTS_APPEND goes to the JVM through JDK_JAVA_OPTIONS" {
  conf <<<"JVM_OPTS_APPEND=-Xmx3g -Dfile.encoding=UTF-8 -XX:OnOutOfMemoryError=kill -9 %p"
  set_up
  [ "$status" -eq 0 ]
  # A % is doubled: alone, systemd would read it as a specifier.
  grep -qxF 'Environment="JDK_JAVA_OPTIONS=-Xmx3g -Dfile.encoding=UTF-8 -XX:OnOutOfMemoryError=kill -9 %%p"' \
    "$SYSTEMD/tomcat10.service.d/50-xinit.conf"
  [[ "$(json 'd["warnings"]')" == *"applies at the next start"* ]]
  [[ "$(json 'd["warnings"]')" != *"already on the command line"* ]]
}

@test "S-SETUP-02 setup: an -Xmx that is already on the command line of the JVM is reported" {
  printf 'java\0-Xms1g\0-Xmx2g\0org.apache.catalina.startup.Bootstrap\0' >"$XINIT_ROOT/proc/98/cmdline"
  conf <<<"JVM_OPTS_APPEND=-Xmx3g"
  set_up
  [ "$status" -eq 0 ]
  [[ "$(json 'd["warnings"]')" == *"-Xmx is already on the command line"* ]]
}

@test "setup: JVM options that would break out of the unit file are refused" {
  conf <<<'JVM_OPTS_APPEND=-Dx="y"'
  set_up
  [ "$status" -eq 3 ]
  conf <<<'JVM_OPTS_APPEND=-Dx=y\'
  set_up
  [ "$status" -eq 3 ]
  [ ! -e "$SYSTEMD" ]
}

@test "setup: each instance has its own units, requests and manifest" {
  touch "$XINIT_CONF_DIR/instances/wiki1.conf" "$XINIT_CONF_DIR/instances/wiki2.conf"
  set_up -i wiki2
  [ "$status" -eq 0 ]
  grep -qxF "ExecStart=$XINIT -i wiki2 watch" "$SYSTEMD/xinit-watch@wiki2.service"
  grep -qxF "StateDirectory=xinit xinit/wiki2" "$SYSTEMD/xinit-watch@wiki2.service"
  grep -qxF "PathExists=/run/xinit/wiki2/request-restart" "$SYSTEMD/xinit-act@wiki2.path"
  grep -q "xinit-notify@wiki2.service" "$SYSTEMD/tomcat10.service.d/50-xinit.conf"
  [ -f "$XINIT_CONF_DIR/setup/wiki2.manifest" ]
  [ -f "$XINIT_CONF_DIR/credentials/wiki2.pgpass" ]
  [ ! -e "$SYSTEMD/xinit-watch@default.service" ]
}

@test "setup: an installation that is not known well enough is not set up" {
  use_other_fixture war-tomcat10-pgsql
  set_up
  [ "$status" -eq 3 ]
  [ ! -e "$XINIT_ROOT/etc/systemd/system" ]
}

@test "setup: STATE_DIR and RUN_DIR have to be where systemd creates directories" {
  XINIT_STATE_DIR=/srv/xinit set_up
  [ "$status" -eq 3 ]
  XINIT_RUN_DIR=/tmp/xinit set_up
  [ "$status" -eq 3 ]
  XINIT_STATE_DIR=/var/lib/monitoring set_up
  [ "$status" -eq 0 ]
  grep -qxF "StateDirectory=monitoring monitoring/default" "$SYSTEMD/xinit-watch@default.service"
}

@test "S-SETUP-01 setup: --undo removes what setup wrote, and nothing else" {
  set_up
  mkdir -p "$SYSTEMD/other.service.d"
  echo keep >"$SYSTEMD/other.service.d/override.conf"
  rm -f "$FAKEBIN/systemctl.calls"
  set_up --undo
  [ "$status" -eq 0 ]
  [ "$(json 'd["action"]')" = undo ]
  [ "$(json 'sorted(set(f["change"] for f in d["files"]))')" = "['remove']" ]
  [ "$(json 'len(d["files"])')" = 9 ]
  [ "$(find "$XINIT_ROOT/etc/systemd/system" "$XINIT_ROOT/etc/sysusers.d" -type f)" = "$SYSTEMD/other.service.d/override.conf" ]
  [ ! -e "$SYSTEMD/tomcat10.service.d" ]
  [ ! -e "$CREDENTIALS" ]
  [ ! -e "$MANIFEST" ]
  [[ "$(calls systemctl)" == *"disable --now xinit-act@default.path"*"daemon-reload"* ]]
  # Again: nothing is left to undo.
  set_up --undo
  [ "$status" -eq 0 ]
  [ "$(json 'len(d["files"])')" = 0 ]
  [[ "$(json 'd["warnings"]')" == *"nothing to undo"* ]]
}

@test "setup: --undo keeps a drop-in directory that holds another file" {
  set_up
  echo mine >"$SYSTEMD/tomcat10.service.d/60-mine.conf"
  set_up --undo
  [ ! -e "$SYSTEMD/tomcat10.service.d/50-xinit.conf" ]
  [ -e "$SYSTEMD/tomcat10.service.d/60-mine.conf" ]
}

@test "setup: --undo --dry-run removes nothing" {
  set_up
  set_up --undo --dry-run
  [ "$status" -eq 0 ]
  [ "$(json 'd["dry_run"]')" = True ]
  [ "$(json 'len(d["files"])')" = 9 ]
  [ -e "$SYSTEMD/xinit-watch@default.service" ]
  [ -e "$MANIFEST" ]
}

@test "setup: --undo never removes a file outside of where setup writes" {
  set_up
  echo precious >"$BATS_TEST_TMPDIR/precious"
  printf '%s\n' "file $BATS_TEST_TMPDIR/precious" "file $SYSTEMD/../../../../precious" \
    "unit sshd.service" >>"$MANIFEST"
  rm -f "$FAKEBIN/systemctl.calls"
  set_up --undo
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/precious")" = precious ]
  run ! grep -q sshd "$FAKEBIN/systemctl.calls"
}

@test "setup: --undo does not trust a manifest that others than root can write" {
  set_up
  chmod 666 "$MANIFEST"
  set_up --undo
  [ "$status" -eq 3 ]
  [ -e "$SYSTEMD/xinit-watch@default.service" ]
  chmod 644 "$MANIFEST"
  FAKE_FILE_OWNER=1000 set_up --undo
  [ "$status" -eq 3 ]
  [ -e "$SYSTEMD/xinit-watch@default.service" ]
}

@test "setup: --undo of one instance keeps what another instance still uses" {
  touch "$XINIT_CONF_DIR/instances/wiki1.conf" "$XINIT_CONF_DIR/instances/wiki2.conf"
  set_up -i wiki1
  set_up -i wiki2
  set_up -i wiki1 --undo
  [ "$status" -eq 0 ]
  [ ! -e "$SYSTEMD/xinit-watch@wiki1.service" ]
  [ -e "$SYSTEMD/xinit-watch@wiki2.service" ]
  [ -e "$XINIT_ROOT/etc/sysusers.d/xinit.conf" ]
  set_up -i wiki2 --undo
  [ ! -e "$XINIT_ROOT/etc/sysusers.d/xinit.conf" ]
}

@test "setup: run again, it removes what it wrote before and no longer writes" {
  set_up
  [ -e "$CREDENTIALS" ]
  # The unit changes, and the password can no longer be read.
  sed -i '/connection.password/d' "$XINIT_ROOT/etc/xwiki/hibernate.cfg.xml"
  cp "$XINIT_ROOT/cmd/systemctl-show-tomcat10.txt" "$XINIT_ROOT/cmd/systemctl-show-tomcat11.txt"
  conf <<<"UNIT=tomcat11.service"
  set_up --dry-run
  [ "$(change_of /etc/systemd/system/tomcat10.service.d/50-xinit.conf)" = remove ]
  [ "$(change_of /etc/systemd/system/tomcat11.service.d/50-xinit.conf)" = create ]
  [ "$(change_of "$CREDENTIALS")" = remove ]
  [ -e "$SYSTEMD/tomcat10.service.d/50-xinit.conf" ]
  set_up
  [ "$status" -eq 0 ]
  [ ! -e "$SYSTEMD/tomcat10.service.d" ]
  [ -e "$SYSTEMD/tomcat11.service.d/50-xinit.conf" ]
  [ ! -e "$CREDENTIALS" ]
  run ! grep -q "tomcat10.service.d\|$CREDENTIALS" "$MANIFEST"
  # A line added to the manifest does not get another file removed.
  echo precious >"$BATS_TEST_TMPDIR/precious"
  echo "file $BATS_TEST_TMPDIR/precious" >>"$MANIFEST"
  set_up
  [ "$(cat "$BATS_TEST_TMPDIR/precious")" = precious ]
}

@test "setup: a command that fails stops it, with what the command said" {
  fake systemd-sysusers 'echo "no such thing" >&2; exit 1'
  set_up
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"systemd-sysusers"*"failed: no such thing"* ]]
  # What was written is known, and can be undone.
  [ -e "$MANIFEST" ]
}

@test "setup: usage errors exit 64" {
  run "$XINIT" setup --format xml
  [ "$status" -eq 64 ]
  run "$XINIT" setup now
  [ "$status" -eq 64 ]
}
