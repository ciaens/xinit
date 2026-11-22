# shellcheck shell=bash
# ---------------------------------------------------------------------------
# See the NOTICE file distributed with this work for additional
# information regarding copyright ownership.
#
# This is free software; you can redistribute it and/or modify it
# under the terms of the GNU Lesser General Public License as
# published by the Free Software Foundation; either version 2.1 of
# the License, or (at your option) any later version.
#
# This software is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this software; if not, write to the Free
# Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA
# 02110-1301 USA, or see the FSF site: http://www.fsf.org.
# ---------------------------------------------------------------------------
# Notifications: what xinit tells the administrator. Sourced, never executed.
#
# A notification is always a line in the system log, with fields to search it by
# (`journalctl XINIT_EVENT=restart`). With MAIL set, it is also a mail, which curl sends to
# MAIL_SMTP_URL: the periodic job may gain no privilege, and the sendmail of a mail server needs
# one. The events: restart, flapping, cannot-check, crash, maintenance, report.

# Who gets the mails: addresses separated by spaces or commas. Empty: no mail.
xinit_config_define MAIL ""
# The sender. Default: xinit@<host name>.
xinit_config_define MAIL_FROM ""
# The mail server: smtp://host[:port], or smtps://host[:port] for TLS from the first byte.
xinit_config_define MAIL_SMTP_URL smtp://localhost:25
# STARTTLS on an smtp:// server. yes: required. no: never. auto: required when xinit logs in, so
# that the password is not sent in clear.
xinit_config_define MAIL_SMTP_TLS auto
# A netrc file with the login and password of the mail server. By default,
# $XINIT_CONF_DIR/credentials/smtp.netrc when it exists.
xinit_config_define MAIL_SMTP_NETRC
# A report larger than this, in kilobytes, is not attached. 0: never attach.
xinit_config_define MAIL_ATTACH_MAX 5000
# The same notification is not mailed again within this time.
xinit_config_define NOTIFY_REPEAT 1h

# Seconds after which a mail that is not sent is given up.
XINIT_NOTIFY_TIMEOUT=30

# The configuration, once xinit_notify_config has read it: HOST, FROM, URL, TLS (true, false),
# NETRC, ATTACH_MAX, REPEAT (seconds), ERROR.
# What a caller sets for one notification, after xinit_notify_reset:
#   TITLE      what the subject says happened (default: the event)
#   CHECKS     the checks it is about, separated by spaces
#   STATUS     the status of the checks of this run
#   OOM        true: the subject starts with [OOM]
#   BODY       the text after the message: the summary of a report
#   ATTACH     an archive to attach, and ATTACH_NAME, its name in the mail
#   REPORT     where the report is stored
#   SIGNATURE  what makes two notifications of an event the same (default: CHECKS)
#   UNLIMITED  true: mailed whatever was mailed before
# What a notification sets: MAIL (off, sent, held, failed), and ERROR when it failed.
declare -gA XINIT_NOTIFY=()
# The addresses the mails go to.
XINIT_NOTIFY_RCPT=()
# What was notified, as stored: SENT_<EVENT>="<time> <mails held back since> <signature>".
declare -gA XINIT_NOTIFY_STATE=()

# xinit_notify_config: read the configuration of the notifications. Returns 1 when a value is
# wrong, with the reason in XINIT_NOTIFY[ERROR].
xinit_notify_config() {
  local address list=() host="${HOSTNAME:-}" netrc
  local re_address='^[A-Za-z0-9][A-Za-z0-9._%+-]*@[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'
  local re_url='^smtps?://(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?)(:[0-9]{1,5})?/?$'
  XINIT_NOTIFY=([ERROR]="" [MAIL]=off)
  XINIT_NOTIFY_RCPT=()
  if ! XINIT_NOTIFY[REPEAT]="$(xinit_duration_seconds "${XINIT_CFG[NOTIFY_REPEAT]-}")"; then
    XINIT_NOTIFY[ERROR]="NOTIFY_REPEAT is not a duration: ${XINIT_CFG[NOTIFY_REPEAT]-}"
    return 1
  fi
  # The name goes in a mail and after the URL of the mail server.
  host="${host//[^A-Za-z0-9.-]/}"
  host="${host#"${host%%[A-Za-z0-9]*}"}"
  XINIT_NOTIFY[HOST]="${host:-localhost}"
  # No pathname expansion: read splits, the shell does not.
  read -r -a list < <(printf '%s\n' "${XINIT_CFG[MAIL]//,/ }") || true
  [ "${#list[@]}" -gt 0 ] || return 0
  for address in "${list[@]}"; do
    if [[ ! "$address" =~ $re_address ]] || [ "${#address}" -gt 254 ]; then
      XINIT_NOTIFY[ERROR]="MAIL: $(xinit_state_text "$address" 80) is not a mail address"
      return 1
    fi
    [[ " ${XINIT_NOTIFY_RCPT[*]} " == *" $address "* ]] || XINIT_NOTIFY_RCPT+=("$address")
  done
  XINIT_NOTIFY[FROM]="${XINIT_CFG[MAIL_FROM]:-xinit@${XINIT_NOTIFY[HOST]}}"
  if [[ ! "${XINIT_NOTIFY[FROM]}" =~ $re_address ]] || [ "${#XINIT_NOTIFY[FROM]}" -gt 254 ]; then
    XINIT_NOTIFY[ERROR]="MAIL_FROM is not a mail address: $(xinit_state_text "${XINIT_NOTIFY[FROM]}" 80)"
    return 1
  fi
  XINIT_NOTIFY[URL]="${XINIT_CFG[MAIL_SMTP_URL]-}"
  if [[ ! "${XINIT_NOTIFY[URL]}" =~ $re_url ]]; then
    XINIT_NOTIFY[ERROR]="MAIL_SMTP_URL has to be smtp://host[:port] or smtps://host[:port]: $(xinit_state_text "${XINIT_NOTIFY[URL]}" 80)"
    return 1
  fi
  XINIT_NOTIFY[URL]="${XINIT_NOTIFY[URL]%/}"
  if ! XINIT_NOTIFY[ATTACH_MAX]="$(xinit_config_number MAIL_ATTACH_MAX)"; then
    XINIT_NOTIFY[ERROR]="MAIL_ATTACH_MAX has to be a number of kilobytes: ${XINIT_CFG[MAIL_ATTACH_MAX]-}"
    return 1
  fi
  netrc="${XINIT_CFG[MAIL_SMTP_NETRC]-}"
  if [ -n "$netrc" ]; then
    # curl reads the path between double quotes.
    if [[ "$netrc" != /* || "$netrc" == *[\"\\[:cntrl:]]* ]] || [ ! -f "$netrc" ] || [ ! -r "$netrc" ]; then
      XINIT_NOTIFY[ERROR]="MAIL_SMTP_NETRC has to be a file this user can read: $(xinit_state_text "$netrc" 200)"
      return 1
    fi
  else
    netrc="${XINIT_CONF_DIR:-/etc/xinit}/credentials/smtp.netrc"
    if [[ "$netrc" == *[\"\\[:cntrl:]]* ]] || [ ! -f "$netrc" ] || [ ! -r "$netrc" ]; then
      netrc=""
    fi
  fi
  XINIT_NOTIFY[NETRC]="$netrc"
  case "${XINIT_CFG[MAIL_SMTP_TLS]-}" in
    yes) XINIT_NOTIFY[TLS]=true ;;
    no) XINIT_NOTIFY[TLS]=false ;;
    auto)
      XINIT_NOTIFY[TLS]=false
      [ -z "$netrc" ] || XINIT_NOTIFY[TLS]=true
      ;;
    *)
      XINIT_NOTIFY[ERROR]="MAIL_SMTP_TLS has to be auto, yes or no: ${XINIT_CFG[MAIL_SMTP_TLS]-}"
      return 1
      ;;
  esac
}

# xinit_notify_reset: forget what was set for the last notification.
xinit_notify_reset() {
  local key
  for key in TITLE CHECKS STATUS OOM BODY ATTACH ATTACH_NAME REPORT SIGNATURE UNLIMITED; do
    unset "XINIT_NOTIFY[$key]"
  done
  XINIT_NOTIFY[MAIL]=off
  XINIT_NOTIFY[ERROR]=""
}

# xinit_notify_oom: the oom check of this run found an out-of-memory error.
xinit_notify_oom() {
  local i
  for i in "${!XINIT_RESULT_CHECK[@]}"; do
    [ "${XINIT_RESULT_CHECK[$i]}" = oom ] || continue
    case "${XINIT_RESULT_STATUS[$i]}" in warn | crit) return 0 ;; esac
  done
  return 1
}

# xinit_notify_journal <event> <message>: the line in the system log, with its fields. Best
# effort, as xinit_log_journal.
xinit_notify_journal() {
  local event="$1" text priority=5 fields=()
  command -v logger >/dev/null || return 0
  text="$(xinit_state_text "instance $XINIT_INSTANCE: notification ($event): $2" 2000)"
  case "$event" in maintenance | report) ;; *) priority=4 ;; esac
  fields=("MESSAGE=$text" "SYSLOG_IDENTIFIER=xinit" "PRIORITY=$priority"
    "XINIT_INSTANCE=$XINIT_INSTANCE" "XINIT_EVENT=$event")
  [ -z "${XINIT_NOTIFY[CHECKS]-}" ] ||
    fields+=("XINIT_CHECK=$(xinit_state_text "${XINIT_NOTIFY[CHECKS]}" 200)")
  [ -z "${XINIT_NOTIFY[STATUS]-}" ] ||
    fields+=("XINIT_STATUS=$(xinit_state_text "${XINIT_NOTIFY[STATUS]}" 20)")
  if ! printf '%s\n' "${fields[@]}" | logger --journald 2>/dev/null; then
    # A logger that knows no fields.
    logger -t xinit -- "$text" 2>/dev/null || true
  fi
}

# xinit_notify_state_file: print the path of the file that holds what was notified.
xinit_notify_state_file() { printf '%s/notify\n' "$(xinit_state_dir)"; }

# _xinit_notify_key <event>: print the key of an event in the state.
_xinit_notify_key() {
  local key="${1^^}"
  printf 'SENT_%s\n' "${key//-/_}"
}

# xinit_notify_recent <event> <signature> <seconds> <now>: this event was notified, with this
# signature, less than the seconds ago. Sets XINIT_NOTIFY[LAST_TIME] and [LAST_HELD], which are
# 0 when it never was. Root reads no state that belongs to another user: it remembers nothing.
xinit_notify_recent() {
  local key value time held signature
  local re='^([0-9]{1,12}) ([0-9]{1,9}) ?(.*)$'
  XINIT_NOTIFY[LAST_TIME]=0
  XINIT_NOTIFY[LAST_HELD]=0
  xinit_state_is_mine || return 1
  xinit_state_read "$(xinit_notify_state_file)" XINIT_NOTIFY_STATE || return 1
  key="$(_xinit_notify_key "$1")"
  value="${XINIT_NOTIFY_STATE[$key]-}"
  [[ "$value" =~ $re ]] || return 1
  time="$((10#${BASH_REMATCH[1]}))" held="$((10#${BASH_REMATCH[2]}))" signature="${BASH_REMATCH[3]}"
  [ "$signature" = "$(xinit_state_text "$2" 200)" ] || return 1
  XINIT_NOTIFY[LAST_TIME]="$time"
  XINIT_NOTIFY[LAST_HELD]="$held"
  [ "$(($4 - time))" -lt "$3" ] && [ "$4" -ge "$time" ]
}

# xinit_notify_remember <event> <signature> <time> <mails held back>: store that this event was
# notified. Returns 1 when that fails: the next one is then notified again.
xinit_notify_remember() {
  local key lines=() name
  xinit_state_is_mine || return 1
  key="$(_xinit_notify_key "$1")"
  xinit_state_read "$(xinit_notify_state_file)" XINIT_NOTIFY_STATE || true
  XINIT_NOTIFY_STATE[$key]="$3 $4 $(xinit_state_text "$2" 200)"
  for name in "${!XINIT_NOTIFY_STATE[@]}"; do
    [[ "$name" == SENT_* ]] && lines+=("$name=${XINIT_NOTIFY_STATE[$name]}")
  done
  xinit_state_write "$(xinit_notify_state_file)" "${lines[@]}"
}

# _xinit_notify_cleanup: remove the temporary directory of a mail, if there is one.
_xinit_notify_cleanup() {
  local work="${XINIT_NOTIFY[WORK]-}"
  XINIT_NOTIFY[WORK]=""
  case "$work" in
    */xinit-mail.*) [ ! -d "$work" ] || rm -rf -- "$work" ;;
  esac
  return 0
}

# _xinit_notify_ascii <text> <max length>: print it as a mail header can hold it.
_xinit_notify_ascii() {
  local LC_ALL=C text="$1"
  text="${text//[^[:print:]]/?}"
  printf '%s\n' "${text:0:$2}"
}

# _xinit_notify_body <event> <message> <note about the report>: print the text of a mail.
_xinit_notify_body() {
  local message="$2" note="$3" now held="${XINIT_NOTIFY[LAST_HELD]:-0}"
  now="$(xinit_now)"
  printf '%s\n\n' "$message"
  printf 'Instance: %s\nHost: %s\n' "$XINIT_INSTANCE" "${XINIT_NOTIFY[HOST]}"
  TZ=UTC printf 'Time: %(%Y-%m-%d %H:%M:%S)T UTC\n' "$now"
  if [ "$held" -gt 0 ]; then
    TZ=UTC printf 'Not mailed since %(%Y-%m-%d %H:%M:%S)T UTC: %s notifications like this one.\n' \
      "${XINIT_NOTIFY[LAST_TIME]}" "$held"
  fi
  [ -z "$note" ] || printf '%s\n' "$note"
  [ -z "${XINIT_NOTIFY[BODY]-}" ] || printf '\n%s\n' "${XINIT_NOTIFY[BODY]}"
}

# _xinit_notify_message <event> <message>: print a whole mail, headers first. An attachment
# goes after the text, in base64.
_xinit_notify_message() {
  local event="$1" message="$2" now subject title="${XINIT_NOTIFY[TITLE]:-$1}" address sep=""
  local attach="${XINIT_NOTIFY[ATTACH]-}" name size note="" boundary=""
  now="$(xinit_now)"
  subject="[xinit] "
  [ "${XINIT_NOTIFY[OOM]-}" != true ] || subject+="[OOM] "
  subject+="$XINIT_INSTANCE on ${XINIT_NOTIFY[HOST]}: $title"
  [ -z "${XINIT_NOTIFY[CHECKS]-}" ] || subject+=" (${XINIT_NOTIFY[CHECKS]// /, })"
  if [ -n "${XINIT_NOTIFY[REPORT]-}" ]; then
    note="Report: ${XINIT_NOTIFY[REPORT]}"
  fi
  if [ -n "$attach" ]; then
    size="$(wc -c <"$attach" 2>/dev/null)" || size=""
    if [[ ! "$size" =~ ^[0-9]+$ ]]; then
      note+="${note:+ }(not attached: it cannot be read)"
      attach=""
    elif [ "$size" -gt "$((XINIT_NOTIFY[ATTACH_MAX] * 1024))" ]; then
      note+="${note:+ }(not attached: $((size / 1024)) kB is more than MAIL_ATTACH_MAX)"
      attach=""
    else
      note+="${note:+ }(attached)"
    fi
  fi
  printf 'From: xinit <%s>\n' "${XINIT_NOTIFY[FROM]}"
  printf 'To:'
  for address in "${XINIT_NOTIFY_RCPT[@]}"; do
    printf '%s %s' "$sep" "$address"
    sep=$',\n'
  done
  printf '\nSubject: %s\n' "$(_xinit_notify_ascii "$subject" 200)"
  LC_ALL=C printf 'Date: %(%a, %d %b %Y %H:%M:%S %z)T\n' "$now"
  printf 'Message-ID: <%s.%s.%s@%s>\n' "$now" "$$" "$RANDOM$RANDOM" "${XINIT_NOTIFY[HOST]}"
  printf 'MIME-Version: 1.0\nAuto-Submitted: auto-generated\n'
  printf 'X-Xinit-Instance: %s\nX-Xinit-Event: %s\n' "$XINIT_INSTANCE" "$(_xinit_notify_ascii "$event" 40)"
  if [ -n "$attach" ]; then
    boundary="xinit-$now-$$-$RANDOM$RANDOM$RANDOM"
    printf 'Content-Type: multipart/mixed; boundary="%s"\n\n--%s\n' "$boundary" "$boundary"
  fi
  printf 'Content-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: 8bit\n\n'
  # A line of a mail holds 998 characters at most, and what a remote user can have written in
  # the log reaches no mail reader as a control character.
  _xinit_notify_body "$event" "$message" "$note" |
    LC_ALL=C tr '\000-\011\013-\037\177' '[ *]' | LC_ALL=C cut -c 1-900
  [ -n "$attach" ] || return 0
  name="$(_xinit_notify_ascii "${XINIT_NOTIFY[ATTACH_NAME]:-report.tar.gz}" 100)"
  name="${name//[^A-Za-z0-9._-]/_}"
  printf '\n--%s\nContent-Type: application/gzip; name="%s"\n' "$boundary" "$name"
  printf 'Content-Transfer-Encoding: base64\nContent-Disposition: attachment; filename="%s"\n\n' "$name"
  base64 <"$attach" || return 1
  printf '%s\n' "--$boundary--"
}

# _xinit_notify_send <event> <message>: send the mail. Returns 1 when that fails, with the
# reason in XINIT_NOTIFY[ERROR].
_xinit_notify_send() {
  local work file address error rc=0 old_umask
  if ! command -v curl >/dev/null 2>&1; then
    XINIT_NOTIFY[ERROR]="curl is not installed"
    return 1
  fi
  old_umask="$(umask)"
  umask 077
  if ! work="$(mktemp -d -- "${TMPDIR:-/tmp}/xinit-mail.XXXXXX" 2>/dev/null)"; then
    umask "$old_umask"
    XINIT_NOTIFY[ERROR]="cannot create a temporary directory in ${TMPDIR:-/tmp}"
    return 1
  fi
  XINIT_NOTIFY[WORK]="$work"
  xinit_on_exit _xinit_notify_cleanup
  file="$work/message"
  # curl reads the path between double quotes. A mail has lines that end with CR LF: curl sends
  # them as they are.
  if [[ "$file" == *[\"\\[:cntrl:]]* ]] ||
    ! _xinit_notify_message "$1" "$2" | sed 's/$/\r/' >"$file"; then
    umask "$old_umask"
    _xinit_notify_cleanup
    XINIT_NOTIFY[ERROR]="cannot write the mail in $(xinit_state_text "$work" 200)"
    return 1
  fi
  umask "$old_umask"
  # Nothing goes on the command line: curl reads its options from its standard input. -q comes
  # first: the ~/.curlrc of the user must not change the request. The name after the URL is the
  # one curl gives the server: without it, that would be the name of the file.
  error="$({
    printf 'url = "%s/%s"\n' "${XINIT_NOTIFY[URL]}" "${XINIT_NOTIFY[HOST]}"
    printf 'mail-from = "%s"\n' "${XINIT_NOTIFY[FROM]}"
    for address in "${XINIT_NOTIFY_RCPT[@]}"; do
      printf 'mail-rcpt = "%s"\n' "$address"
    done
    printf 'upload-file = "%s"\n' "$file"
    [ -z "${XINIT_NOTIFY[NETRC]}" ] || printf 'netrc-file = "%s"\n' "${XINIT_NOTIFY[NETRC]}"
    [ "${XINIT_NOTIFY[TLS]}" != true ] || printf 'ssl-reqd\n'
  } | curl -q -sS --max-time "$XINIT_NOTIFY_TIMEOUT" --config - 2>&1 >/dev/null)" || rc=$?
  _xinit_notify_cleanup
  [ "$rc" -ne 0 ] || return 0
  error="${error%%$'\n'*}"
  XINIT_NOTIFY[ERROR]="$(xinit_state_text "curl failed with status $rc${error:+: ${error#curl: (*) }}" 300)"
  return 1
}

# xinit_notify_mail <event> <message>: mail a notification, unless the same was mailed less than
# NOTIFY_REPEAT ago. Sets XINIT_NOTIFY[MAIL]. Returns 1 when the mail could not be sent, with
# the reason in XINIT_NOTIFY[ERROR]: it never ends xinit.
xinit_notify_mail() {
  local event="$1" message="$2" now signature limited=true
  XINIT_NOTIFY[MAIL]=off
  XINIT_NOTIFY[ERROR]=""
  XINIT_NOTIFY[LAST_TIME]=0
  XINIT_NOTIFY[LAST_HELD]=0
  [ "${#XINIT_NOTIFY_RCPT[@]}" -gt 0 ] || return 0
  now="$(xinit_now)" || return 1
  signature="${XINIT_NOTIFY[SIGNATURE]-${XINIT_NOTIFY[CHECKS]-}}"
  [ "${XINIT_NOTIFY[UNLIMITED]-}" != true ] || limited=false
  if [ "$limited" = true ] && xinit_notify_recent "$event" "$signature" "${XINIT_NOTIFY[REPEAT]}" "$now"; then
    xinit_notify_remember "$event" "$signature" "${XINIT_NOTIFY[LAST_TIME]}" \
      "$((XINIT_NOTIFY[LAST_HELD] + 1))" || true
    XINIT_NOTIFY[MAIL]=held
    return 0
  fi
  if ! _xinit_notify_send "$event" "$message"; then
    XINIT_NOTIFY[MAIL]=failed
    xinit_log_journal "mail not sent: ${XINIT_NOTIFY[ERROR]}"
    return 1
  fi
  XINIT_NOTIFY[MAIL]=sent
  [ "$limited" = false ] || xinit_notify_remember "$event" "$signature" "$now" 0 || true
  return 0
}

# xinit_notify <event> <message>: notify, in the system log and by mail. Returns 1 when the
# mail could not be sent, with the reason in XINIT_NOTIFY[ERROR].
xinit_notify() {
  xinit_notify_journal "$1" "$2"
  xinit_notify_mail "$1" "$2"
}

# xinit_cmd_notify crash: the `xinit notify` command, which the unit of XWiki starts when it stops
# for another reason than being asked to.
xinit_cmd_notify() {
  local event="${1:-}" unit line detail="" source
  [ $# -eq 1 ] && [ "$event" = crash ] || xinit_die "usage: xinit notify crash" "$XINIT_EXIT_USAGE"
  xinit_notify_config || xinit_die "${XINIT_NOTIFY[ERROR]}"
  xinit_layout_resolve || true
  unit="${XINIT_LAYOUT[UNIT]-}"
  source="${XINIT_LAYOUT[LOG_SOURCE]-}"
  [ -n "$unit" ] || xinit_die "notify: no XWiki installation is known for the instance $XINIT_INSTANCE"
  # What systemd said about it.
  if [[ "$source" == journal:* ]] && _xinit_journal -u "${source#journal:}" --since "-120s"; then
    while IFS= read -r line; do
      case "$line" in
        *"Main process exited"* | *"Failed with result"*) detail="${line#*: }" ;;
      esac
    done < <(printf '%s\n' "$XINIT_JOURNAL_OUTPUT")
  fi
  xinit_notify_reset
  XINIT_NOTIFY[TITLE]="XWiki crashed"
  XINIT_NOTIFY[STATUS]=crit
  # The kernel killed it for memory: systemd names that result.
  [[ "$detail" != *oom-kill* ]] || XINIT_NOTIFY[OOM]=true
  xinit_notify crash "$unit stopped unexpectedly${detail:+: $detail}" || return "$XINIT_EXIT_UNKNOWN"
}
