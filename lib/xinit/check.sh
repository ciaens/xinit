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

# The checks, in the order they run.
XINIT_CHECKS=(process http rest oom db disk)

# The checks to run, when none is named on the command line.
xinit_config_define CHECKS "${XINIT_CHECKS[*]}"
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

# xinit_jvm_starting: the JVM started less than STARTUP_GRACE seconds ago.
xinit_jvm_starting() {
  local age grace="${XINIT_CFG[STARTUP_GRACE]}"
  [[ "$grace" =~ ^[0-9]+$ ]] || return 1
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

# xinit_cmd_check [--format text|json|nagios] [check...]: the `xinit check` command.
xinit_cmd_check() {
  local format=text names=() name known found before
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
  for name in "${names[@]}"; do
    found=1
    for known in "${XINIT_CHECKS[@]}"; do
      [ "$name" = "$known" ] && found=0
    done
    [ "$found" -eq 0 ] ||
      xinit_die "unknown check: $name (the checks are: ${XINIT_CHECKS[*]})" "$XINIT_EXIT_USAGE"
  done

  if ! xinit_layout_resolve && [ -z "${XINIT_LAYOUT[PROFILE]+x}" ]; then
    # Nothing to check: say so in the requested format.
    xinit_result layout unknown no-installation \
      "no XWiki installation was detected: see 'xinit layout' for what to configure"
  else
    for name in "${names[@]}"; do
      before="${#XINIT_RESULT_CHECK[@]}"
      # A check that fails without a result is a bug: report it rather than hide it.
      if ! "xinit_check_$name" || [ "${#XINIT_RESULT_CHECK[@]}" -eq "$before" ]; then
        [ "${#XINIT_RESULT_CHECK[@]}" -gt "$before" ] ||
          xinit_result "$name" unknown no-result "the check ended without a result"
      fi
    done
  fi
  xinit_results_print "$format"
  return "$(xinit_status_exit_code "$(xinit_results_status)")"
}
