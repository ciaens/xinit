#!/usr/bin/env bats
# Notifications on a real installation, run by root, with a mail server in the container that
# keeps what it is given. Scenarios S-NOTIFY-* of docs/TESTING.md. The mails of the units that
# `xinit setup` installs are in 60-setup.bats.

load helpers

setup_file() {
  wait_healthy 300
  install_fault_page
  XT_START="$(date +%s)"
  export XT_START
}

setup() {
  xinit_conf
  in_env rm -rf /var/lib/xinit /run/xinit
  smtp_start
  HOST="$(host_name)"
}

teardown() {
  smtp_stop
  heal_all
  in_env rm -rf /var/lib/xinit /run/xinit /root/xinit-test-report /root/xinit-test-password
  wait_healthy 300
}

# The options that make the checks depend on XWiki alone (see 50-watch.bats), and send the mails
# to the server of the test.
options() {
  printf '%s\n' -o DISK_WARN=1 -o DISK_CRIT=0 -o STARTUP_GRACE=0 -o HTTP_TIMEOUT=5 \
    -o "OOM_WINDOW=$(($(date +%s) - XT_START + 1))" \
    -o "MAIL=admin@example.org, ops@example.org" -o "MAIL_SMTP_URL=$XT_MAIL_URL"
}

# watch [args...]: `xinit watch --format json`, with these options.
watch() {
  local args=()
  mapfile -t args < <(options)
  xinit watch --format json "${args[@]}" "$@"
}

# report [args...]: `xinit report --format json`, with these options.
report() {
  local args=()
  mapfile -t args < <(options)
  xinit report --format json "${args[@]}" "$@"
}

# w <field>: a field of the "watch" member of the output.
w() { json "d['watch']['$1']"; }

# notified: the event this run notified and what became of its mail, or nothing.
notified() { json "d['watch']['notification'] and d['watch']['notification']['event'] + ' ' + d['watch']['notification']['mail']"; }

@test "S-NOTIFY-01 a hung XWiki is restarted, and one mail tells it with the report and no secret" {
  local password start attached first
  password="$(db_password)"
  db_credentials
  start="$(date +%s)"
  # Requests that do not end: the JVM lives, and its thread dumps say what it does.
  in_env_sh "for i in \$(seq 30); do
      curl -s -o /dev/null --max-time 60 '$XT_BASE_URL$(fault_url "action=sleep&ms=30000&leak=$password")' &
    done; sleep 3" >/dev/null 2>&1
  watch -o RESTART_AFTER=1 -o "HTTP_PATH=$(fault_url 'action=sleep&ms=30000')"
  [ "$status" -eq 0 ]
  [ "$(w action)" = restart ]
  [ "$(w restart_ok)" = True ]
  [ "$(notified)" = "restart sent" ]
  [ "$(mails)" = 1 ]
  [ "$(mail_envelope 1)" = "from xinit@$HOST to admin@example.org to ops@example.org " ]
  # The subject has the instance, the host and the check.
  [ "$(mail_header 1 Subject)" = "[xinit] default on $HOST: XWiki restarted (http)" ]
  # Every line ends with CR LF, and none is longer than a mail server has to take.
  [ "$(in_env_sh "grep -vc \$'\\r\$' $XT_MAIL_DIR/mail-1.eml || true")" = 0 ]
  [ "$(in_env awk '{ if (length($0) > max) max = length($0) } END { print (max <= 999) }' "$XT_MAIL_DIR/mail-1.eml")" = 1 ]
  # What the admin needs first: how the restart went, the threads, the requests, the database.
  mail 1 | grep -qx "The restart was done."
  mail 1 | grep -q "^Thread dumps: 3 "
  first="$(mail 1 | grep -A 1 "^Requests being served, by URL" | tail -n 1)"
  [[ "$first" == *"/bin/view/XinitTest/Faults" ]]
  mail 1 | grep -q "^Database (.*): sessions: [1-9]"
  # The report is attached, as it is stored.
  attached="$(mail_attachment 1)"
  in_env cmp "$attached" "$(w report)"
  unpack "$attached"
  in_env grep -q "Full thread dump" "$R/threads/dump-3.txt"
  # The password of the database, which the requests brought in the thread dumps, is nowhere.
  if [ "${#password}" -ge 8 ]; then
    printf '%s\n' "$password" | in_env_sh "umask 077 && cat > /root/xinit-test-password"
    run in_env grep -qF -f /root/xinit-test-password "$XT_MAIL_DIR/mail-1.eml"
    [ "$status" -eq 1 ]
    run in_env grep -rqF -f /root/xinit-test-password "$R"
    [ "$status" -eq 1 ]
    in_env grep -q "leak=<redacted>" "$R/threads/dump-1.txt"
  fi
  # The entry of the system log is found by its fields.
  [ "$(journal_fields "$start" restart)" = "default http crit" ]
  # Nothing is left behind.
  [ -z "$(in_env_sh "ls -d /tmp/xinit-mail.* /tmp/xinit-report.* 2>/dev/null")" ]
  wait_healthy 300
}

@test "S-NOTIFY-02 after a heap OutOfMemoryError the subject says [OOM], and no longer once XWiki was restarted" {
  fault_small_heap 768m
  wait_healthy 300
  install_fault_page
  provoke_heap_oom
  watch -o RESTART_AFTER=1
  [ "$status" -eq 0 ]
  [ "$(w action)" = restart ]
  [[ " $(w failed_checks) " == *"'oom'"* ]]
  [ "$(notified)" = "restart sent" ]
  mail_header 1 Subject >&2
  [[ "$(mail_header 1 Subject)" == "[xinit] [OOM] default on $HOST: XWiki restarted ("*"oom"* ]]
  # The error is in the log of the JVM that was stopped: the new one has none.
  wait_healthy 300
  report --send
  [ "$status" -eq 0 ]
  [ "$(json 'd["oom"]')" = False ]
  [ "$(mail_header 2 Subject)" = "[xinit] default on $HOST: report" ]
}

@test "S-NOTIFY-04 the same notification is mailed once within NOTIFY_REPEAT" {
  local args=() start
  mapfile -t args < <(options)
  start="$(date +%s)"
  xinit notify crash "${args[@]}"
  [ "$status" -eq 0 ]
  xinit notify crash "${args[@]}"
  [ "$status" -eq 0 ]
  [ "$(mails)" = 1 ]
  [ "$(mail_header 1 Subject)" = "[xinit] default on $HOST: XWiki crashed" ]
  # The system log has both.
  [ "$(journal_fields "$start" crash | wc -l)" = 2 ]
  [ "$(in_env stat -c '%U %a' /var/lib/xinit/default/notify)" = "root 600" ]
  xinit notify crash "${args[@]}" -o NOTIFY_REPEAT=0
  [ "$(mails)" = 2 ]
}

@test "S-NOTIFY-05 without a mail server, XWiki is restarted all the same" {
  local pid start
  pid="$(jvm_pid)"
  start="$(date +%s)"
  smtp_stop
  watch -o RESTART_AFTER=1 -o "HTTP_PATH=$(fault_url 'action=status&code=503')"
  [ "$status" -eq 0 ]
  [ "$(w action)" = restart ]
  [ "$(w restart_ok)" = True ]
  [ "$(notified)" = "restart failed" ]
  in_env test -s "$(w report)"
  in_env_sh "journalctl -t xinit --since @$start -o cat | grep -q 'mail not sent: curl failed with status 7'"
  [ "$(journal_fields "$start" restart | wc -l)" = 1 ]
  wait_healthy 300
  [ "$(jvm_pid)" != "$pid" ]
}

@test "S-NOTIFY-06 a maintenance that lasts is reminded once per MAINT_REMINDER" {
  xinit maint on --for 10m --reason "upgrade"
  [ "$status" -eq 0 ]
  # In its first hour, nothing.
  watch
  [ "$status" -eq 0 ]
  [ -z "$(notified)" ]
  watch -o MAINT_REMINDER_AFTER=0
  [ "$(notified)" = "maintenance sent" ]
  [ "$(mail_header 1 Subject)" = "[xinit] default on $HOST: still in maintenance" ]
  mail 1 | grep -q "^In maintenance for .*, set by root (upgrade): xinit does not restart XWiki."
  watch -o MAINT_REMINDER_AFTER=0
  [ -z "$(notified)" ]
  [ "$(mails)" = 1 ]
}

@test "S-NOTIFY-07 a host name that no longer resolves is notified once, and XWiki is not restarted" {
  local pid
  pid="$(jvm_pid)"
  watch -o RESTART_AFTER=2 -o BASE_URL=http://xinit-test.invalid:8080/xwiki
  [ "$status" -eq 0 ]
  [ "$(w reason)" = unknown ]
  [ -z "$(notified)" ]
  watch -o RESTART_AFTER=2 -o BASE_URL=http://xinit-test.invalid:8080/xwiki
  [ "$(w action)" = none ]
  [ "$(w reason)" = cannot-check ]
  [ "$(notified)" = "cannot-check sent" ]
  [[ "$(mail_header 1 Subject)" == "[xinit] default on $HOST: cannot check XWiki (http"* ]]
  # What the resolver of the host says.
  mail 1 | grep -qx "Name resolution:"
  mail 1 | grep -qxF '$ getent ahosts xinit-test.invalid'
  mail 1 | grep -q "^Report: .* (attached)$"
  watch -o RESTART_AFTER=2 -o BASE_URL=http://xinit-test.invalid:8080/xwiki
  [ "$(w reason)" = cannot-check ]
  [ -z "$(notified)" ]
  [ "$(mails)" = 1 ]
  [ "$(jvm_pid)" = "$pid" ]
}

@test "S-NOTIFY-08 report --send logs in to the mail server, and never in clear unless told to" {
  smtp_start "xinit:Sm7pSecret99"
  printf 'machine 127.0.0.1 login xinit password Sm7pSecret99\n' |
    in_env_sh "mkdir -p $XT_XINIT_CONF_DIR/credentials && umask 077 &&
      cat > $XT_XINIT_CONF_DIR/credentials/smtp.netrc"
  # This server has no TLS: nothing is sent, and the report is kept.
  report --send
  [ "$status" -eq 3 ]
  [ "$(json 'd["mail"]')" = failed ]
  in_env test -s "$(json 'd["report"]')"
  [ "$(mails)" = 0 ]
  run in_env test -e "$XT_MAIL_DIR/logins"
  [ "$status" -ne 0 ]
  # The administrator can take it on.
  report --send -o MAIL_SMTP_TLS=no
  [ "$status" -eq 0 ]
  [ "$(json 'd["mail"]')" = sent ]
  [ "$(in_env cat "$XT_MAIL_DIR/logins")" = "accepted xinit" ]
  [ "$(mail_header 1 Subject)" = "[xinit] default on $HOST: report" ]
  in_env cmp "$(mail_attachment 1)" "$(json 'd["report"]')"
  # The name xinit gives the server is the one of the host, not one of a file.
  [ "$(in_env_sh "sort -u $XT_MAIL_DIR/hello")" = "EHLO $HOST" ]
  # A wrong password: no mail.
  printf 'machine 127.0.0.1 login xinit password wrong-one\n' |
    in_env_sh "umask 077 && cat > $XT_XINIT_CONF_DIR/credentials/smtp.netrc"
  report --send -o MAIL_SMTP_TLS=no
  [ "$status" -eq 3 ]
  [ "$(mails)" = 1 ]
}
