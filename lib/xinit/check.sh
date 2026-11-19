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
#
# A check is a function xinit_check_<name>, in checks/<name>.sh. It reads the layout and the
# configuration, changes nothing on the system, and records its findings with xinit_result.

# The checks, in the order they run. Not XINIT_CHECKS: that is the environment variable of CHECKS.
XINIT_CHECK_NAMES=(process http rest oom db disk)

# The checks to run, when none is named on the command line.
xinit_config_define CHECKS "${XINIT_CHECK_NAMES[*]}"
# How long after its start a JVM may still refuse or not answer requests without that being a
# failure, in seconds.
xinit_config_define STARTUP_GRACE 300

# xinit_jvm_age: print for how many seconds the JVM has been running. Returns 1 when that cannot
# be told.
xinit_jvm_age() {
  local pid="${XINIT_LAYOUT[JVM_PID]-}" age
  [ -n "$pid" ] || return 1
  age="$(ps -o etimes= -p "$pid" 2>/dev/null)" || return 1
  age="${age//[[:space:]]/}"
  [[ "$age" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$age"
}

# xinit_unit_age: print how many seconds ago the main process of the unit last started, running
# or not. Returns 1 when that cannot be told. systemd counts in microseconds since the boot.
xinit_unit_age() {
  local unit="${XINIT_LAYOUT[UNIT]-}" started uptime
  [ -n "$unit" ] || return 1
  started="$(xinit_systemctl_show "$unit" ExecMainStartTimestampMonotonic)" || return 1
  [[ "$started" =~ ^[0-9]{1,18}$ ]] && [ "$((10#$started))" -gt 0 ] || return 1
  [ -r "${XINIT_ROOT:-}/proc/uptime" ] || return 1
  read -r uptime _ <"${XINIT_ROOT:-}/proc/uptime" || return 1
  uptime="${uptime%%.*}"
  [[ "$uptime" =~ ^[0-9]{1,12}$ ]] || return 1
  [ "$((10#$uptime))" -ge "$((10#$started / 1000000))" ] || return 1
  printf '%s\n' "$((10#$uptime - 10#$started / 1000000))"
}

# xinit_jvm_starting: the JVM started less than STARTUP_GRACE seconds ago.
xinit_jvm_starting() {
  local age grace
  grace="$(xinit_config_number STARTUP_GRACE)" || return 1
  age="$(xinit_jvm_age)" || return 1
  [ "$age" -lt "$grace" ]
}

# xinit_seconds_to_ms <seconds, as 1.234567>: print it in milliseconds, as an integer.
xinit_seconds_to_ms() {
  local seconds="${1%%.*}" fraction=""
  [[ "$1" == *.* ]] && fraction="${1#*.}"
  fraction="${fraction}000"
  echo "$((10#${seconds:-0} * 1000 + 10#${fraction:0:3}))"
}

# xinit_checks_known <check...>: every name is a check. Else returns 1, with the first name that
# is not in XINIT_CHECK_UNKNOWN.
xinit_checks_known() {
  local name known found
  XINIT_CHECK_UNKNOWN=""
  for name in "$@"; do
    found=1
    for known in "${XINIT_CHECK_NAMES[@]}"; do
      [ "$name" = "$known" ] && found=0
    done
    if [ "$found" -ne 0 ]; then
      XINIT_CHECK_UNKNOWN="$name"
      return 1
    fi
  done
}

# xinit_checks_run <check...>: resolve the layout and run the checks, which record their results.
# Returns 1 when there is no installation to check, with that as the only result.
xinit_checks_run() {
  local name before
  if ! xinit_layout_resolve && [ -z "${XINIT_LAYOUT[PROFILE]+x}" ]; then
    # Nothing to check: say so as a result.
    xinit_result layout unknown no-installation \
      "no XWiki installation was detected: see 'xinit layout' for what to configure"
    return 1
  fi
  for name in "$@"; do
    before="${#XINIT_RESULT_CHECK[@]}"
    # A check that fails without a result is a bug: report it rather than hide it.
    if ! "xinit_check_$name" || [ "${#XINIT_RESULT_CHECK[@]}" -eq "$before" ]; then
      [ "${#XINIT_RESULT_CHECK[@]}" -gt "$before" ] ||
        xinit_result "$name" unknown no-result "the check ended without a result"
    fi
  done
}

# xinit_cmd_check [--format text|json|nagios] [check...]: the `xinit check` command.
xinit_cmd_check() {
  local format=text names=() name
  while [ $# -gt 0 ]; do
    case "$1" in
      --format)
        [ $# -ge 2 ] || xinit_die "--format needs a value" "$XINIT_EXIT_USAGE"
        format="$2"
        shift 2
        ;;
      --format=*)
        format="${1#--format=}"
        shift
        ;;
      -*) xinit_die "check: unknown option $1" "$XINIT_EXIT_USAGE" ;;
      *)
        names+=("$1")
        shift
        ;;
    esac
  done
  case "$format" in
    text | json | nagios) ;;
    *) xinit_die "check: unknown format $format (text, json, nagios)" "$XINIT_EXIT_USAGE" ;;
  esac
  if [ "${#names[@]}" -eq 0 ]; then
    # CHECKS is a list separated by spaces or commas.
    for name in ${XINIT_CFG[CHECKS]//,/ }; do
      names+=("$name")
    done
  fi
  xinit_checks_known "${names[@]}" ||
    xinit_die "unknown check: $XINIT_CHECK_UNKNOWN (the checks are: ${XINIT_CHECK_NAMES[*]})" \
      "$XINIT_EXIT_USAGE"
  xinit_checks_run "${names[@]}" || true
  xinit_results_print "$format"
  return "$(xinit_status_exit_code "$(xinit_results_status)")"
}
