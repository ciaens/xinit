#!/usr/bin/env bats
# Notifications: the line in the system log and the mail. Scenarios S-NOTIFY-* of docs/TESTING.md,
# on fakes: curl is given each mail, and keeps it.

load helpers

setup() {
  use_fixture tomcat10-pgsql
  use_state
  DUMPS="$FIXTURES/journal/thread-dumps-unit.txt"
  STATE_DIR="$XINIT_STATE_DIR/default"
  TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  # The name of the host, which bash keeps when it is given one.
  export TMPDIR FAKE_JOURNAL_UNIT="$DUMPS" HOSTNAME=wiki1.example.org
}

# watch_at <seconds after $NOW> [xinit watch arguments...]: one run at that time, in JSON.
watch_at() {
  local offset="$1"
  shift
  XINIT_TEST_NOW=$((NOW + offset)) run --separate-stderr "$XINIT" watch --format json "$@"
}

# notified: the event this run notified and what became of its mail, or nothing.
notified() { json "d['watch']['notification'] and d['watch']['notification']['event'] + ' ' + d['watch']['notification']['mail']"; }

# w <field>: a field of the "watch" member of the output.
w() { json "d['watch']['$1']"; }

# fields <event>: how many entries of the system log have this event.
fields() { calls logger | grep -cx "XINIT_EVENT=$1" || true; }

# failing: from now on, XWiki does not answer.
failing() { export FAKE_CURL_EXIT=28 FAKE_CURL_ERROR="Operation timed out"; }
healed() { unset FAKE_CURL_EXIT FAKE_CURL_ERROR; }

# no_name: from now on, the host name of the URL of XWiki does not resolve.
no_name() { export FAKE_CURL_EXIT=6 FAKE_CURL_ERROR="Could not resolve host: localhost"; }

@test "S-NOTIFY-01 notify: a restart is mailed once it is done, with the report" {
  failing
  conf <<<"RESTART_AFTER=1
MAIL=admin@example.org, ops@example.org"
  watch_at 0
  [ "$status" -eq 0 ]
  [ "$(w action)" = restart ]
  [ "$(w restart_ok)" = True ]
  [ "$(notified)" = "restart sent" ]
  [ "$(mails)" = 1 ]
  # Nothing but fixed options on the command line of curl: the rest is read from its input.
  [ "$(calls curl | grep -- '--config')" = "-q -sS --max-time 30 --config -" ]
  [ "$(mail_options 1)" = "url = \"smtp://localhost:25/wiki1.example.org\"
mail-from = \"xinit@wiki1.example.org\"
mail-rcpt = \"admin@example.org\"
mail-rcpt = \"ops@example.org\"
upload-file = \"$(sed -n 's/^upload-file = "\(.*\)"$/\1/p' "$FAKEBIN/mail-1.config")\"" ]
  [ "$(cat "$FAKEBIN/mail-1.mode")" = 600 ]
  [ "$(mail_header 1 Subject)" = "[xinit] default on wiki1.example.org: XWiki restarted (http)" ]
  [ "$(mail_header 1 From)" = "xinit <xinit@wiki1.example.org>" ]
  [ "$(mail 1 | sed -n '/^To:/,/^Subject:/p')" = "To: admin@example.org,
 ops@example.org
Subject: [xinit] default on wiki1.example.org: XWiki restarted (http)" ]
  [ "$(mail_header 1 Date)" = "Fri, 15 Jan 2027 08:00:00 +0000" ]
  [ "$(mail_header 1 Auto-Submitted)" = "auto-generated" ]
  # Every line ends with CR LF, and none is longer than a mail server takes.
  [ "$(grep -vc $'\r$' "$FAKEBIN/mail-1.eml")" = 0 ]
  [ "$(awk '{ if (length($0) > max) max = length($0) } END { print (max <= 901) }' "$FAKEBIN/mail-1.eml")" = 1 ]
  # What happened, how the restart went, and what the report says.
  mail 1 | grep -qx "http (timeout) failed in 1 runs in a row: restarting tomcat10.service"
  mail 1 | grep -qx "The restart was done."
  mail 1 | grep -qx "Instance: default"
  mail 1 | grep -qx "Report: $STATE_DIR/reports/report-20270115T080000Z.tar.gz (attached)"
  mail 1 | grep -q "^Thread dumps: 3 "
  # The attachment is the report.
  mail_attachment 1 "$BATS_TEST_TMPDIR/attached.tar.gz"
  cmp "$BATS_TEST_TMPDIR/attached.tar.gz" "$STATE_DIR/reports/report-20270115T080000Z.tar.gz"
  mail 1 | grep -qx 'Content-Disposition: attachment; filename="xinit-report-default-20270115T080000Z.tar.gz"'
  # The entry of the system log can be found by its fields.
  [ "$(fields restart)" = 1 ]
  calls logger | grep -qx "XINIT_INSTANCE=default"
  calls logger | grep -qx "XINIT_CHECK=http"
  calls logger | grep -qx "XINIT_STATUS=crit"
  calls logger | grep -qx "SYSLOG_IDENTIFIER=xinit"
  calls logger | grep -q "^MESSAGE=instance default: notification (restart): http (timeout) failed"
  # Nothing is left behind.
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "S-NOTIFY-01 notify: a restart that fails is mailed as such" {
  failing
  export FAKE_RESTART_ERROR="Access denied"
  conf <<<"RESTART_AFTER=1
MAIL=admin@example.org"
  watch_at 0
  [ "$status" -eq 3 ]
  [ "$(w restart_ok)" = False ]
  [ "$(notified)" = "restart sent" ]
  [ "$(mail_header 1 Subject)" = "[xinit] default on wiki1.example.org: the restart of XWiki failed (http)" ]
  mail 1 | grep -qx "The restart failed: systemctl failed with status 1: Access denied"
}

@test "S-NOTIFY-01 notify: without MAIL, a notification is a line in the system log" {
  failing
  conf <<<"RESTART_AFTER=1"
  watch_at 0
  [ "$(w action)" = restart ]
  [ "$(notified)" = "restart off" ]
  [ "$(mails)" = 0 ]
  [ "$(fields restart)" = 1 ]
  [ ! -e "$STATE_DIR/notify" ]
}

@test "S-NOTIFY-02 notify: the subject starts with [OOM] when the oom check found one" {
  export FAKE_JOURNAL_UNIT="$FIXTURES/journal/heap-oom-unit.txt"
  conf <<<"RESTART_AFTER=1
MAIL=admin@example.org"
  watch_at 0
  [ "$(w action)" = restart ]
  [ "$(w failed_checks)" = "['oom']" ]
  [ "$(mail_header 1 Subject)" = "[xinit] [OOM] default on wiki1.example.org: XWiki restarted (oom)" ]
}

@test "S-NOTIFY-04 notify: the same notification is not mailed again within NOTIFY_REPEAT" {
  failing
  conf <<<"RESTART_AFTER=1
COOLDOWN=20min
MAX_RESTARTS=10
MAIL=admin@example.org"
  watch_at 0
  [ "$(notified)" = "restart sent" ]
  [ "$(stat -c %a "$STATE_DIR/notify")" = 600 ]
  watch_at 1200
  [ "$(w action)" = restart ]
  [ "$(notified)" = "restart held" ]
  watch_at 2400
  [ "$(notified)" = "restart held" ]
  [ "$(mails)" = 1 ]
  # An hour after the mail, the next one leaves, and says what was held back.
  watch_at 3600
  [ "$(notified)" = "restart sent" ]
  [ "$(mails)" = 2 ]
  mail 2 | grep -qx "Not mailed since 2027-01-15 08:00:00 UTC: 2 notifications like this one."
  run ! grep -q "Not mailed since" "$FAKEBIN/mail-1.eml"
  # The system log has them all.
  [ "$(fields restart)" = 4 ]
}

@test "S-NOTIFY-04 notify: with NOTIFY_REPEAT=0 each one is mailed" {
  failing
  conf <<<"RESTART_AFTER=1
COOLDOWN=20min
NOTIFY_REPEAT=0
MAIL=admin@example.org"
  watch_at 0
  watch_at 1200
  [ "$(notified)" = "restart sent" ]
  [ "$(mails)" = 2 ]
}

@test "S-NOTIFY-04 notify: another event is mailed within NOTIFY_REPEAT" {
  failing
  conf <<<"RESTART_AFTER=1
COOLDOWN=0
MAX_RESTARTS=1
MAIL=admin@example.org"
  watch_at 0
  [ "$(notified)" = "restart sent" ]
  watch_at 60
  [ "$(w reason)" = flapping ]
  [ "$(notified)" = "flapping sent" ]
  [ "$(mail_header 2 Subject)" = "[xinit] default on wiki1.example.org: XWiki still fails after restarts (http)" ]
  # It comes with a report too.
  mail 2 | grep -q "^Report: .*report-20270115T080100Z.tar.gz (attached)$"
  watch_at 120
  [ -z "$(notified)" ]
  [ "$(mails)" = 2 ]
}

@test "S-NOTIFY-05 notify: a mail that cannot be sent does not stop the restart, and is tried again" {
  failing
  export FAKE_SMTP_EXIT=7 FAKE_SMTP_ERROR="Failed to connect to localhost port 25"
  conf <<<"RESTART_AFTER=1
COOLDOWN=20min
MAIL=admin@example.org"
  watch_at 0
  [ "$status" -eq 0 ]
  [ "$(w restart_ok)" = True ]
  [ "$(notified)" = "restart failed" ]
  [[ "$(calls logger)" == *"instance default: mail not sent: curl failed with status 7: Failed to connect to localhost port 25"* ]]
  [ -z "$(ls -A "$TMPDIR")" ]
  # Not counted as mailed: the next one is not held back.
  unset FAKE_SMTP_EXIT
  watch_at 1200
  [ "$(notified)" = "restart sent" ]
}

@test "S-NOTIFY-06 notify: a maintenance that lasts is reminded, after MAINT_REMINDER_AFTER" {
  conf <<<"MAIL=admin@example.org"
  run "$XINIT" maint on --for 4h --reason "upgrade to 18.9"
  [ "$status" -eq 0 ]
  watch_at 0
  [ -z "$(notified)" ]
  # Not in its first two hours, the default length of a maintenance.
  watch_at 3600
  [ -z "$(notified)" ]
  watch_at 7140
  [ -z "$(notified)" ]
  watch_at 7200
  [ "$status" -eq 0 ]
  [ "$(notified)" = "maintenance sent" ]
  [ "$(mail_header 1 Subject)" = "[xinit] default on wiki1.example.org: still in maintenance" ]
  mail 1 | grep -qx "In maintenance for 2h, set by root (upgrade to 18.9): xinit does not restart XWiki. It ends in 2h, or with 'xinit maint off'."
  [ "$(mail_header 1 Content-Type)" = "text/plain; charset=UTF-8" ]
  # Then every MAINT_REMINDER.
  watch_at 7260
  [ -z "$(notified)" ]
  watch_at 10740
  [ -z "$(notified)" ]
  watch_at 10800
  [ "$(notified)" = "maintenance sent" ]
  [ "$(mails)" = 2 ]
  [ "$(fields maintenance)" = 2 ]
  # Not after its end.
  watch_at 14400
  [ -z "$(notified)" ]
}

@test "S-NOTIFY-06 notify: the first reminder waits for MAINT_REMINDER_AFTER, the next ones for MAINT_REMINDER" {
  conf <<<"MAINT_REMINDER_AFTER=30min
MAINT_REMINDER=10min"
  run "$XINIT" maint on --for 1d
  watch_at 1740
  [ -z "$(notified)" ]
  watch_at 1800
  [ "$(notified)" = "maintenance off" ]
  watch_at 2340
  [ -z "$(notified)" ]
  watch_at 2400
  [ "$(notified)" = "maintenance off" ]
  [ "$(fields maintenance)" = 2 ]
  # A new maintenance starts again from nothing.
  XINIT_TEST_NOW=$((NOW + 2460)) run "$XINIT" maint on --for 1d
  watch_at 2520
  [ -z "$(notified)" ]
}

@test "S-NOTIFY-06 notify: MAINT_REMINDER=0 reminds of nothing, and a mail that fails is not sent each minute" {
  conf <<<"MAINT_REMINDER=0
MAIL=admin@example.org"
  run "$XINIT" maint on --for 1d
  watch_at 7200
  [ -z "$(notified)" ]
  conf <<<"MAIL=admin@example.org"
  export FAKE_SMTP_EXIT=7
  watch_at 7260
  [ "$status" -eq 0 ]
  [ "$(notified)" = "maintenance failed" ]
  watch_at 7320
  [ -z "$(notified)" ]
  [ "$(mails)" = 1 ]
}

@test "S-NOTIFY-07 notify: checks that cannot tell any more are notified once, without a restart" {
  no_name
  conf <<<"MAIL=admin@example.org"
  watch_at 0
  [ "$(w reason)" = unknown ]
  [ -z "$(notified)" ]
  watch_at 60
  [ -z "$(notified)" ]
  watch_at 120
  [ "$status" -eq 0 ]
  [ "$(w action)" = none ]
  [ "$(w reason)" = cannot-check ]
  [ "$(notified)" = "cannot-check sent" ]
  [ "$(mail_header 1 Subject)" = "[xinit] default on wiki1.example.org: cannot check XWiki (http)" ]
  mail 1 | grep -qx "http (dns) could not tell in 3 runs in a row: XWiki is not watched, and nothing is done"
  # What the resolver of the host says is in the mail, and in the report.
  mail 1 | grep -qx "Name resolution:"
  mail 1 | grep -qxF '$ getent ahosts localhost'
  tar -tzf "$(w report)" | grep -q "/dns.txt$"
  calls logger | grep -qx "XINIT_STATUS=unknown"
  # Once: not at each run that follows.
  watch_at 180
  [ "$(w reason)" = cannot-check ]
  [ -z "$(notified)" ]
  [ "$(mails)" = 1 ]
  [ "$(calls systemctl | grep -c '^restart ' || true)" = 0 ]
  # Again after XWiki was seen healthy, when the last mail is old enough.
  healed
  watch_at 240
  [ "$(w reason)" = healthy ]
  no_name
  watch_at 7200
  watch_at 7260
  watch_at 7320
  [ "$(notified)" = "cannot-check sent" ]
}

@test "S-NOTIFY-07 notify: during a maintenance, checks that cannot tell are not notified" {
  no_name
  conf <<<"RESTART_AFTER=1
MAINT_REMINDER=0"
  run "$XINIT" maint on --for 10min
  watch_at 0
  [ "$(w reason)" = cannot-check ]
  [ -z "$(notified)" ]
  watch_at 600
  [ "$(notified)" = "cannot-check off" ]
}

@test "S-NOTIFY-08 report: --send mails the report to MAIL, each time" {
  conf <<<"MAIL=admin@example.org"
  run --separate-stderr "$XINIT" report --send --format json
  [ "$status" -eq 0 ]
  [ "$(json 'd["mail"]')" = sent ]
  [ "$(mail_header 1 Subject)" = "[xinit] default on wiki1.example.org: report" ]
  mail 1 | grep -qx "Report asked by root."
  mail_attachment 1 "$BATS_TEST_TMPDIR/attached.tar.gz"
  cmp "$BATS_TEST_TMPDIR/attached.tar.gz" "$(json 'd["report"]')"
  [ "$(fields report)" = 1 ]
  # Someone asks: it is not held back.
  run --separate-stderr "$XINIT" report --send --format json
  [ "$(json 'd["mail"]')" = sent ]
  [ "$(mails)" = 2 ]
  [ -z "$(ls -A "$TMPDIR")" ]
  # Without --send, nothing is mailed.
  run --separate-stderr "$XINIT" report --format json
  [ -z "$(json 'd["mail"]')" ]
  [ "$(mails)" = 2 ]
}

@test "S-NOTIFY-08 report: --send needs MAIL, which -o can give for one run" {
  run --separate-stderr "$XINIT" report --send
  [ "$status" -eq 3 ]
  # shellcheck disable=SC2154  # $stderr is set by bats' run
  [[ "$stderr" == *"--send needs MAIL"* ]]
  [ -z "$(calls kill)" ]
  run --separate-stderr "$XINIT" -o MAIL=someone@example.org report --send --format json
  [ "$status" -eq 0 ]
  [ "$(mail_options 1 | grep mail-rcpt)" = 'mail-rcpt = "someone@example.org"' ]
}

@test "S-NOTIFY-08 report: a report that cannot be mailed is still stored, and the exit code is 3" {
  export FAKE_SMTP_EXIT=67 FAKE_SMTP_ERROR="Login denied"
  conf <<<"MAIL=admin@example.org"
  run --separate-stderr "$XINIT" report --send --format json
  [ "$status" -eq 3 ]
  [ "$(json 'd["mail"]')" = failed ]
  [ -f "$(json 'd["report"]')" ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "S-NOTIFY-08 report: root mails what it built, when the state belongs to another user" {
  mkdir -p "$XINIT_STATE_DIR"
  export FAKE_STATE_OWNER=990:985
  fake setsid '[ "$1" = --wait ] && shift; exec "$@"'
  fake setpriv "cat >'$FAKEBIN/stored.tar.gz'; echo /somewhere/report-1.tar.gz"
  conf <<<"MAIL=admin@example.org"
  run --separate-stderr "$XINIT" report --send --format json
  [ "$status" -eq 0 ]
  [ "$(json 'd["mail"]')" = sent ]
  mail_attachment 1 "$BATS_TEST_TMPDIR/attached.tar.gz"
  cmp "$BATS_TEST_TMPDIR/attached.tar.gz" "$FAKEBIN/stored.tar.gz"
  # Root wrote nothing in the directory of that user.
  [ -z "$(ls -A "$XINIT_STATE_DIR")" ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "S-NOTIFY-08 notify: a report over MAIL_ATTACH_MAX is not attached, and the mail says so" {
  conf <<<"MAIL=admin@example.org
MAIL_ATTACH_MAX=0"
  run --separate-stderr "$XINIT" report --send --format json
  [ "$status" -eq 0 ]
  [ "$(mail_header 1 Content-Type)" = "text/plain; charset=UTF-8" ]
  mail 1 | grep -q "^Report: .*report-20270115T080000Z.tar.gz (not attached: [0-9]* kB is more than MAIL_ATTACH_MAX)$"
  run ! grep -q "Content-Disposition" "$FAKEBIN/mail-1.eml"
}

@test "S-NOTIFY-09 notify: a crash is mailed, with [OOM] when the kernel killed XWiki for memory" {
  conf <<<"MAIL=admin@example.org"
  printf '%s\n' "tomcat10.service: A process of this unit has been killed by the OOM killer." \
    "tomcat10.service: Failed with result 'oom-kill'." >"$BATS_TEST_TMPDIR/journal"
  FAKE_JOURNAL_UNIT="$BATS_TEST_TMPDIR/journal" run "$XINIT" notify crash
  [ "$status" -eq 0 ]
  [ "$(mail_header 1 Subject)" = "[xinit] [OOM] default on wiki1.example.org: XWiki crashed" ]
  mail 1 | grep -qx "tomcat10.service stopped unexpectedly: Failed with result 'oom-kill'."
  [ "$(fields crash)" = 1 ]
  # A crash loop does not fill a mailbox.
  FAKE_JOURNAL_UNIT="$BATS_TEST_TMPDIR/journal" run "$XINIT" notify crash
  [ "$status" -eq 0 ]
  [ "$(mails)" = 1 ]
  [ "$(fields crash)" = 2 ]
  # Another crash is not the kernel's doing.
  printf '%s\n' "tomcat10.service: Failed with result 'signal'." >"$BATS_TEST_TMPDIR/journal"
  FAKE_JOURNAL_UNIT="$BATS_TEST_TMPDIR/journal" XINIT_TEST_NOW=$((NOW + 3600)) run "$XINIT" notify crash
  [ "$(mail_header 2 Subject)" = "[xinit] default on wiki1.example.org: XWiki crashed" ]
}

@test "S-NOTIFY-09 notify: a crash that cannot be mailed exits 3, with its line in the system log" {
  conf <<<"MAIL=admin@example.org"
  FAKE_SMTP_EXIT=7 run "$XINIT" notify crash
  [ "$status" -eq 3 ]
  [ "$(fields crash)" = 1 ]
}

@test "notify: root remembers nothing in a state that belongs to another user" {
  mkdir -p "$XINIT_STATE_DIR"
  export FAKE_STATE_OWNER=990:985
  conf <<<"MAIL=admin@example.org"
  run "$XINIT" notify crash
  [ "$status" -eq 0 ]
  run "$XINIT" notify crash
  [ "$(mails)" = 2 ]
  [ -z "$(ls -A "$XINIT_STATE_DIR")" ]
}

@test "notify: with a credentials file curl logs in, and only over TLS" {
  failing
  mkdir -p "$XINIT_CONF_DIR/credentials"
  echo "machine mail.example.org login xinit password Sm7pSecret99" >"$XINIT_CONF_DIR/credentials/smtp.netrc"
  conf <<<"RESTART_AFTER=1
COOLDOWN=0
MAX_RESTARTS=10
NOTIFY_REPEAT=0
MAIL=admin@example.org
MAIL_SMTP_URL=smtp://mail.example.org:587"
  watch_at 0
  [ "$(notified)" = "restart sent" ]
  mail_options 1 | grep -qxF 'url = "smtp://mail.example.org:587/wiki1.example.org"'
  mail_options 1 | grep -qxF "netrc-file = \"$XINIT_CONF_DIR/credentials/smtp.netrc\""
  mail_options 1 | grep -qx "ssl-reqd"
  # The password stays in its file.
  run ! grep -rq "Sm7pSecret99" "$FAKEBIN" "$XINIT_STATE_DIR"
  # MAIL_SMTP_TLS=no: the administrator takes it on.
  XINIT_MAIL_SMTP_TLS=no watch_at 60
  mail_options 2 | grep -q "^netrc-file = "
  run ! grep -qx "ssl-reqd" "$FAKEBIN/mail-2.config"
  # MAIL_SMTP_TLS=yes: also without a login.
  rm "$XINIT_CONF_DIR/credentials/smtp.netrc"
  watch_at 120
  run ! grep -q "netrc-file\|ssl-reqd" "$FAKEBIN/mail-3.config"
  XINIT_MAIL_SMTP_TLS=yes watch_at 180
  mail_options 4 | grep -qx "ssl-reqd"
  # A file named in the configuration.
  echo "machine mail.example.org login xinit password Sm7pSecret99" >"$BATS_TEST_TMPDIR/my netrc"
  XINIT_MAIL_SMTP_NETRC="$BATS_TEST_TMPDIR/my netrc" XINIT_MAIL_SMTP_URL=smtps://mail.example.org watch_at 240
  mail_options 5 | grep -qxF 'url = "smtps://mail.example.org/wiki1.example.org"'
  mail_options 5 | grep -qxF "netrc-file = \"$BATS_TEST_TMPDIR/my netrc\""
}

@test "notify: a wrong value of the configuration stops watch before it does anything" {
  local bad
  failing
  for bad in "MAIL=admin@example.org;id" "MAIL=*" "MAIL=<admin@example.org>" 'MAIL=a"b@example.org' \
    "MAIL_SMTP_URL=http://localhost" "MAIL_SMTP_URL=smtp://user:secret@localhost" \
    "MAIL_SMTP_URL=smtp://localhost/x y" "MAIL_FROM=xinit" "MAIL_SMTP_TLS=maybe" \
    "MAIL_ATTACH_MAX=5M" "MAIL_SMTP_NETRC=$BATS_TEST_TMPDIR/missing" "MAIL_SMTP_NETRC=relative" \
    "NOTIFY_REPEAT=often"; do
    conf <<<"RESTART_AFTER=1
MAIL=admin@example.org
$bad"
    watch_at 0
    [ "$status" -eq 3 ] || { echo "accepted: $bad"; false; }
    [ -z "$output" ]
  done
  [ "$(mails)" = 0 ]
  [ -z "$(calls systemctl | grep '^restart ' || true)" ]
  [ ! -e "$STATE_DIR/state" ]
  # Without MAIL, what only a mail needs is not looked at.
  conf <<<"MAIL_FROM=xinit"
  watch_at 0
  [ "$status" -eq 0 ]
  conf <<<"MAINT_REMINDER=sometimes"
  watch_at 0
  [ "$status" -eq 3 ]
}

@test "notify: what is not plain text reaches neither a header nor a long line" {
  local lib long
  for lib in core config parse result layout check state maint act checks/oom notify; do
    # shellcheck disable=SC1090  # the libraries, as bin/xinit sources them
    source "$XINIT_REPO/lib/xinit/$lib.sh"
  done
  # shellcheck disable=SC2034  # read by the libraries
  XINIT_INSTANCE=default
  # shellcheck disable=SC2034  # read by the libraries
  XINIT_CFG[MAIL]="admin@example.org" XINIT_CFG[STATE_DIR]="$XINIT_STATE_DIR"
  xinit_notify_config
  long="$(printf 'x%.0s' {1..3000})"
  xinit_notify_reset
  XINIT_NOTIFY[TITLE]=$'a title\r\nBcc: thief@example.org'
  XINIT_NOTIFY[CHECKS]=$'http\r\nBcc:' XINIT_NOTIFY[BODY]="$long"$'\n.\nsecond \033[31m line\r'
  xinit_notify_mail restart $'a message\r\nBcc: thief@example.org'
  [ "${XINIT_NOTIFY[MAIL]}" = sent ]
  # One Subject line, and no header a remote user could have added.
  [ "$(mail 1 | sed -n '1,/^$/p' | grep -c '^Bcc')" = 0 ]
  [ "$(mail_header 1 Subject)" = "[xinit] default on wiki1.example.org: a title??Bcc: thief@example.org (http??Bcc:)" ]
  [ "$(LC_ALL=C grep -c $'[\001-\010\013\014\016-\037]' "$FAKEBIN/mail-1.eml")" = 0 ]
  [ "$(awk '{ if (length($0) > max) max = length($0) } END { print max }' "$FAKEBIN/mail-1.eml")" = 901 ]
  # A line that is a dot alone would end the mail: it is sent as a line of the text, with its CR LF.
  [ "$(grep -c $'^\\.\r$' "$FAKEBIN/mail-1.eml")" = 1 ]
}
