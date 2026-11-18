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
# `xinit check`: run the read-only checks on one instance. Sourced, never executed.
# `xinit watch`: run the checks, and restart XWiki when it has failed for long enough. Sourced,
# never executed.
#
# One run, every minute:
#   1. takes the lock of the instance, or ends when another run holds it;
#   2. runs the checks;
#   3. counts the consecutive runs in which a check of ACT_ON was crit;
#   4. restarts XWiki after RESTART_AFTER such runs, unless a maintenance is on, a restart was
#      done less than COOLDOWN ago, or MAX_RESTARTS were done in MAX_RESTARTS_WINDOW.
# A warn or an unknown never causes a restart.

# The checks whose crit counts as a failure. None: xinit only records.
xinit_config_define ACT_ON "process http oom"
# How many consecutive failed runs before a restart.
xinit_config_define RESTART_AFTER 3
# How long after a restart the next one has to wait.
xinit_config_define COOLDOWN 15min
# How many restarts at most in MAX_RESTARTS_WINDOW. Then xinit stops restarting, and says so
# once, until a run finds XWiki healthy.
xinit_config_define MAX_RESTARTS 3
xinit_config_define MAX_RESTARTS_WINDOW 1h

# The state of the instance, as stored: FAILURES, FAILED, LAST_RUN, LAST_RESTART, RESTARTS (the
# times of the restarts in the window), ESCALATED.
declare -gA XINIT_WATCH_STATE=()
# This run: ACTION (none, restart), REASON, FAILED (the failed checks, with their reasons),
# FAILED_CHECKS (their names), COOLDOWN_LEFT, RESTART_OK, THREAD_DUMP.
declare -gA XINIT_WATCH=()

# xinit_watch_state_file: print the path of the state file.
xinit_watch_state_file() { printf '%s/state\n' "$(xinit_state_dir)"; }

# _xinit_watch_state_load: read the state. What is missing or makes no sense starts again from
# nothing. Returns 1 when the state exists and cannot be read.
_xinit_watch_state_load() {
  local rc=0 key time times=""
  xinit_state_read "$(xinit_watch_state_file)" XINIT_WATCH_STATE || rc=$?
  [ "$rc" -ne 2 ] || return 1
  for key in FAILURES LAST_RUN LAST_RESTART ESCALATED; do
    if [[ "${XINIT_WATCH_STATE[$key]-}" =~ ^[0-9]{1,12}$ ]]; then
      XINIT_WATCH_STATE[$key]="$((10#${XINIT_WATCH_STATE[$key]}))"
    else
      XINIT_WATCH_STATE[$key]=0
    fi
  done
  for time in ${XINIT_WATCH_STATE[RESTARTS]-}; do
    [[ "$time" =~ ^[0-9]{1,12}$ ]] && times+="${times:+ }$((10#$time))"
  done
  XINIT_WATCH_STATE[RESTARTS]="$times"
  return 0
}

# _xinit_watch_state_save: store the state. Returns 1 when that fails.
_xinit_watch_state_save() {
  xinit_state_write "$(xinit_watch_state_file)" \
    "FAILURES=${XINIT_WATCH_STATE[FAILURES]}" \
    "FAILED=$(xinit_state_text "${XINIT_WATCH[FAILED]-}" 200)" \
    "LAST_RUN=${XINIT_WATCH_STATE[LAST_RUN]}" \
    "LAST_RESTART=${XINIT_WATCH_STATE[LAST_RESTART]}" \
    "RESTARTS=${XINIT_WATCH_STATE[RESTARTS]}" \
    "ESCALATED=${XINIT_WATCH_STATE[ESCALATED]}"
}

# _xinit_watch_classify <check...>: look at the results of the checks that count. Sets
# XINIT_WATCH[FAILED] and [FAILED_CHECKS], and prints failed, unknown or healthy.
_xinit_watch_classify() {
  local name i failed="" names="" unknown=0
  for name in "$@"; do
    for i in "${!XINIT_RESULT_CHECK[@]}"; do
      [ "${XINIT_RESULT_CHECK[$i]}" = "$name" ] || continue
      case "${XINIT_RESULT_STATUS[$i]}" in
        crit)
          failed+="${failed:+, }$name (${XINIT_RESULT_REASON[$i]})"
          names+="${names:+ }$name"
          ;;
        unknown) unknown=1 ;;
      esac
    done
  done
  XINIT_WATCH[FAILED]="$failed"
  XINIT_WATCH[FAILED_CHECKS]="$names"
  if [ -n "$failed" ]; then
    XINIT_WATCH[HEALTH]=failed
  elif [ "$unknown" -eq 1 ]; then
    XINIT_WATCH[HEALTH]=unknown
  else
    XINIT_WATCH[HEALTH]=healthy
  fi
}

# _xinit_watch_json: print the "watch" member of the JSON output.
_xinit_watch_json() {
  local name sep="" dump=null ok=null
  [ -z "${XINIT_WATCH[THREAD_DUMP]-}" ] || dump="$(xinit_json_string "${XINIT_WATCH[THREAD_DUMP]}")"
  [ -z "${XINIT_WATCH[RESTART_OK]-}" ] || ok="${XINIT_WATCH[RESTART_OK]}"
  printf '"watch":{"action":"%s","reason":"%s","dry_run":%s,"failures":%s,"restart_after":%s,' \
    "${XINIT_WATCH[ACTION]}" "${XINIT_WATCH[REASON]}" "${XINIT_WATCH[DRY_RUN]}" \
    "${XINIT_WATCH_STATE[FAILURES]:-0}" "${XINIT_WATCH[RESTART_AFTER]:-0}"
  printf '"failed_checks":['
  for name in ${XINIT_WATCH[FAILED_CHECKS]-}; do
    printf '%s"%s"' "$sep" "$name"
    sep=","
  done
  printf '],"restarts":%s,"max_restarts":%s,"cooldown_remaining_seconds":%s,' \
    "${XINIT_WATCH[RESTARTS]:-0}" "${XINIT_WATCH[MAX_RESTARTS]:-0}" "${XINIT_WATCH[COOLDOWN_LEFT]:-0}"
  printf '"restart_ok":%s,"thread_dump":%s}' "$ok" "$dump"
}

# _xinit_watch_print <format>: print the results of the checks, and what this run did.
_xinit_watch_print() {
  local would=""
  if [ "$1" = json ]; then
    xinit_results_print json "$(_xinit_watch_json)"
    return 0
  fi
  [ "${#XINIT_RESULT_CHECK[@]}" -eq 0 ] || xinit_results_print text
  [ "${XINIT_WATCH[DRY_RUN]}" = true ] && would=" (dry run: nothing was done)"
  printf 'watch: %s, %s%s\n' "${XINIT_WATCH[ACTION]}" "${XINIT_WATCH[MESSAGE]}" "$would"
}

# _xinit_watch_decide <now>: from the state and the health of this run, set XINIT_WATCH[ACTION],
# [REASON] and [MESSAGE], and update the state. Nothing is done yet.
_xinit_watch_decide() {
  local now="$1" after="${XINIT_WATCH[RESTART_AFTER]}" cooldown="${XINIT_WATCH[COOLDOWN]}"
  local max="${XINIT_WATCH[MAX_RESTARTS]}" window="${XINIT_WATCH[WINDOW]}"
  local time kept="" count=0 failures since rc
  XINIT_WATCH[ACTION]=none
  XINIT_WATCH[WAS_FAILING]="${XINIT_WATCH_STATE[FAILURES]}"
  XINIT_WATCH_STATE[LAST_RUN]="$now"
  # The restarts that still count.
  for time in ${XINIT_WATCH_STATE[RESTARTS]}; do
    if [ "$((now - time))" -lt "$window" ]; then
      kept+="${kept:+ }$time"
      count=$((count + 1))
    fi
  done
  XINIT_WATCH_STATE[RESTARTS]="$kept"
  XINIT_WATCH[RESTARTS]="$count"

  case "${XINIT_WATCH[HEALTH]}" in
    healthy)
      XINIT_WATCH_STATE[FAILURES]=0
      XINIT_WATCH_STATE[ESCALATED]=0
      XINIT_WATCH[REASON]=healthy
      XINIT_WATCH[MESSAGE]="no check that counts has failed"
      return 0
      ;;
    unknown)
      # Not a failure, and not a proof of health: the count stays as it is.
      XINIT_WATCH[REASON]=unknown
      XINIT_WATCH[MESSAGE]="a check could not tell: not counted as a failure"
      return 0
      ;;
  esac
  failures=$((XINIT_WATCH_STATE[FAILURES] + 1))
  XINIT_WATCH_STATE[FAILURES]="$failures"

  rc=0
  xinit_maint_load || rc=$?
  if [ "$rc" -eq 2 ]; then
    XINIT_WATCH[REASON]=maintenance-unknown
    XINIT_WATCH[MESSAGE]="${XINIT_WATCH[FAILED]} failed, but the maintenance cannot be read: not acting"
  elif [ "$rc" -eq 0 ] && xinit_maint_active; then
    XINIT_WATCH[REASON]=maintenance
    XINIT_WATCH[MESSAGE]="${XINIT_WATCH[FAILED]} failed during a maintenance: not acting"
  elif [ "$failures" -lt "$after" ]; then
    XINIT_WATCH[REASON]=counting
    XINIT_WATCH[MESSAGE]="${XINIT_WATCH[FAILED]} failed: run $failures of $after before a restart"
  elif [ "${XINIT_WATCH_STATE[ESCALATED]}" -gt 0 ]; then
    XINIT_WATCH[REASON]=flapping
    XINIT_WATCH[MESSAGE]="${XINIT_WATCH[FAILED]} failed: restarts did not help, waiting for someone"
  elif [ "${XINIT_WATCH_STATE[LAST_RESTART]}" -gt 0 ] &&
    [ "$((now - XINIT_WATCH_STATE[LAST_RESTART]))" -lt "$cooldown" ]; then
    since=$((now - XINIT_WATCH_STATE[LAST_RESTART]))
    XINIT_WATCH[COOLDOWN_LEFT]=$((cooldown - since))
    XINIT_WATCH[REASON]=cooldown
    XINIT_WATCH[MESSAGE]="${XINIT_WATCH[FAILED]} failed: restarted $(xinit_duration_text "$since") ago, waiting $(xinit_duration_text "${XINIT_WATCH[COOLDOWN_LEFT]}") more"
  elif [ "$count" -ge "$max" ]; then
    XINIT_WATCH_STATE[ESCALATED]="$now"
    XINIT_WATCH[ESCALATE]=1
    XINIT_WATCH[REASON]=flapping
    XINIT_WATCH[MESSAGE]="${XINIT_WATCH[FAILED]} failed after $count restarts in $(xinit_duration_text "$window"): not restarting again"
  else
    XINIT_WATCH[ACTION]=restart
    XINIT_WATCH[REASON]=threshold
    XINIT_WATCH[MESSAGE]="${XINIT_WATCH[FAILED]} failed in $failures runs in a row: restarting ${XINIT_LAYOUT[UNIT]-XWiki}"
    XINIT_WATCH_STATE[LAST_RESTART]="$now"
    XINIT_WATCH_STATE[RESTARTS]="${kept:+$kept }$now"
    XINIT_WATCH[RESTARTS]=$((count + 1))
  fi
}

# xinit_cmd_watch [--dry-run] [--format text|json]: the `xinit watch` command. It exits 0 when it
# did its work, whatever the state of XWiki, and 3 when it could not.
xinit_cmd_watch() {
  local format=text dry=false name names=() acting=() now rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=true && shift ;;
      --format)
        [ $# -ge 2 ] || xinit_die "--format needs a value" "$XINIT_EXIT_USAGE"
        format="$2"
        shift 2
        ;;
      --format=*) format="${1#--format=}" && shift ;;
      *) xinit_die "watch: unexpected argument $1" "$XINIT_EXIT_USAGE" ;;
    esac
  done
  case "$format" in
    text | json) ;;
    *) xinit_die "watch: unknown format $format (text, json)" "$XINIT_EXIT_USAGE" ;;
  esac
  XINIT_WATCH=([ACTION]=none [REASON]="" [MESSAGE]="" [DRY_RUN]="$dry" [HEALTH]="")

  # The configuration, before anything is done.
  XINIT_WATCH[RESTART_AFTER]="$(xinit_config_number RESTART_AFTER)" &&
    [ "${XINIT_WATCH[RESTART_AFTER]}" -ge 1 ] ||
    xinit_die "RESTART_AFTER has to be a number, 1 or more: ${XINIT_CFG[RESTART_AFTER]-}"
  XINIT_WATCH[MAX_RESTARTS]="$(xinit_config_number MAX_RESTARTS)" &&
    [ "${XINIT_WATCH[MAX_RESTARTS]}" -ge 1 ] ||
    xinit_die "MAX_RESTARTS has to be a number, 1 or more: ${XINIT_CFG[MAX_RESTARTS]-}"
  XINIT_WATCH[COOLDOWN]="$(xinit_duration_seconds "${XINIT_CFG[COOLDOWN]-}")" ||
    xinit_die "COOLDOWN is not a duration: ${XINIT_CFG[COOLDOWN]-}"
  XINIT_WATCH[WINDOW]="$(xinit_duration_seconds "${XINIT_CFG[MAX_RESTARTS_WINDOW]-}")" ||
    xinit_die "MAX_RESTARTS_WINDOW is not a duration: ${XINIT_CFG[MAX_RESTARTS_WINDOW]-}"
  for name in ${XINIT_CFG[ACT_ON]//,/ }; do
    acting+=("$name")
  done
  xinit_checks_known "${acting[@]}" ||
    xinit_die "ACT_ON: unknown check $XINIT_CHECK_UNKNOWN (the checks are: ${XINIT_CHECK_NAMES[*]})"
  for name in ${XINIT_CFG[CHECKS]//,/ }; do
    names+=("$name")
  done
  xinit_checks_known "${names[@]}" ||
    xinit_die "CHECKS: unknown check $XINIT_CHECK_UNKNOWN (the checks are: ${XINIT_CHECK_NAMES[*]})"
  # A check that counts runs, also when CHECKS leaves it out.
  for name in "${acting[@]}"; do
    [[ " ${names[*]} " == *" $name "* ]] || names+=("$name")
  done

  # A dry run changes nothing: it takes no lock either.
  if [ "$dry" = false ] && ! xinit_lock_acquire; then
    XINIT_WATCH[REASON]=locked
    XINIT_WATCH[MESSAGE]="another xinit watch is running for this instance"
    _xinit_watch_print "$format"
    return 0
  fi
  _xinit_watch_state_load ||
    xinit_die "cannot read $(xinit_watch_state_file): run this as root, or as its owner"

  if ! xinit_checks_run "${names[@]}"; then
    XINIT_WATCH[REASON]=no-installation
    XINIT_WATCH[MESSAGE]="there is no XWiki installation to watch"
    _xinit_watch_print "$format"
    return "$XINIT_EXIT_UNKNOWN"
  fi
  _xinit_watch_classify "${acting[@]}"
  now="$(xinit_now)"
  _xinit_watch_decide "$now"

  if [ "$dry" = true ]; then
    _xinit_watch_print "$format"
    return 0
  fi
  # Remember first, act next: a restart that is not remembered would be done again and again.
  _xinit_watch_state_save ||
    xinit_die "cannot write $(xinit_watch_state_file): run this as root, or as its owner"

  if [ "${XINIT_WATCH[HEALTH]}" = failed ]; then
    xinit_log_journal "${XINIT_WATCH[MESSAGE]}"
  elif [ "${XINIT_WATCH[HEALTH]}" = healthy ] && [ "${XINIT_WATCH[WAS_FAILING]}" -gt 0 ]; then
    xinit_log_journal "healthy again, after ${XINIT_WATCH[WAS_FAILING]} failed runs"
  fi
  if [ -n "${XINIT_WATCH[ESCALATE]-}" ]; then
    xinit_notify flapping "${XINIT_WATCH[MESSAGE]}"
  fi
  if [ "${XINIT_WATCH[ACTION]}" = restart ]; then
    # The thread dump first: it shows what hangs, and is gone with the JVM.
    if xinit_thread_dump; then
      XINIT_WATCH[THREAD_DUMP]="$XINIT_THREAD_DUMP_FILE"
      xinit_log_journal "thread dump stored in $XINIT_THREAD_DUMP_FILE"
    else
      xinit_log_journal "no thread dump: $XINIT_ACT_ERROR"
    fi
    xinit_notify restart "${XINIT_WATCH[MESSAGE]}"
    if xinit_act_restart; then
      XINIT_WATCH[RESTART_OK]=true
    else
      XINIT_WATCH[RESTART_OK]=false
      xinit_log_journal "the restart failed: $XINIT_ACT_ERROR"
      xinit_log error "the restart failed: $XINIT_ACT_ERROR"
      rc="$XINIT_EXIT_UNKNOWN"
    fi
  fi
  _xinit_watch_print "$format"
  return "$rc"
}
