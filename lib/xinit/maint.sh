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
# `xinit maint`: the maintenance mode of one instance. Sourced, never executed.
#
# During a maintenance, `xinit watch` records the failures but does not act on them. A maintenance
# always has an end, so that a forgotten one stops by itself.

# How long a maintenance lasts, when `xinit maint on` is not given --for.
xinit_config_define MAINT_DURATION 2h

# The maintenance as stored: UNTIL and SINCE (seconds since the epoch), BY and REASON.
declare -gA XINIT_MAINTENANCE=()

# xinit_maint_file: print the path of the file that holds the maintenance.
xinit_maint_file() { printf '%s/maintenance\n' "$(xinit_state_dir)"; }

# xinit_maint_load: read the stored maintenance into XINIT_MAINTENANCE. Returns 1 when there is
# none, 2 when what is stored cannot be read or understood.
xinit_maint_load() {
  local rc=0
  xinit_state_read "$(xinit_maint_file)" XINIT_MAINTENANCE || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  [[ "${XINIT_MAINTENANCE[UNTIL]-}" =~ ^[0-9]{1,12}$ ]] || return 2
  [[ "${XINIT_MAINTENANCE[SINCE]-}" =~ ^[0-9]{1,12}$ ]] || return 2
  XINIT_MAINTENANCE[UNTIL]="$((10#${XINIT_MAINTENANCE[UNTIL]}))"
  XINIT_MAINTENANCE[SINCE]="$((10#${XINIT_MAINTENANCE[SINCE]}))"
}

# xinit_maint_active: the loaded maintenance has not ended.
xinit_maint_active() {
  [ -n "${XINIT_MAINTENANCE[UNTIL]-}" ] && [ "${XINIT_MAINTENANCE[UNTIL]}" -gt "$(xinit_now)" ]
}

# _xinit_maint_print <format>: print the loaded maintenance.
_xinit_maint_print() {
  local format="$1" until left
  if ! xinit_maint_active; then
    case "$format" in
      json)
        printf '{"instance":%s,"maintenance":false,"until":null,"remaining_seconds":null,' \
          "$(xinit_json_string "$XINIT_INSTANCE")"
        printf '"since":null,"by":null,"reason":null}\n'
        ;;
      *) printf 'maintenance: off\n' ;;
    esac
    return 0
  fi
  until="${XINIT_MAINTENANCE[UNTIL]}"
  left=$((until - $(xinit_now)))
  case "$format" in
    json)
      printf '{"instance":%s,"maintenance":true,"until":%s,"remaining_seconds":%s,' \
        "$(xinit_json_string "$XINIT_INSTANCE")" "$until" "$left"
      printf '"since":%s,"by":%s,"reason":%s}\n' "${XINIT_MAINTENANCE[SINCE]}" \
        "$(xinit_json_string "${XINIT_MAINTENANCE[BY]-}")" \
        "$(xinit_json_string "${XINIT_MAINTENANCE[REASON]-}")"
      ;;
    *)
      printf 'maintenance: on until %(%Y-%m-%d %H:%M:%S %Z)T (%s left), set by %s' "$until" \
        "$(xinit_duration_text "$left")" "${XINIT_MAINTENANCE[BY]:-unknown}"
      [ -z "${XINIT_MAINTENANCE[REASON]-}" ] || printf ': %s' "${XINIT_MAINTENANCE[REASON]}"
      printf '\n'
      ;;
  esac
}

# xinit_cmd_maint on [--for DURATION] [--reason TEXT] | off | status, each with
# [--format text|json]: the `xinit maint` command.
xinit_cmd_maint() {
  local action="" format=text duration="" reason="" seconds now file rc
  local usage="usage: xinit maint on [--for DURATION] [--reason TEXT] | off | status"
  while [ $# -gt 0 ]; do
    case "$1" in
      --for | --reason | --format)
        [ $# -ge 2 ] || xinit_die "maint: $1 needs a value" "$XINIT_EXIT_USAGE"
        case "$1" in
          --for) duration="$2" ;;
          --reason) reason="$2" ;;
          --format) format="$2" ;;
        esac
        shift 2
        ;;
      --for=*) duration="${1#--for=}" && shift ;;
      --reason=*) reason="${1#--reason=}" && shift ;;
      --format=*) format="${1#--format=}" && shift ;;
      -*) xinit_die "maint: unknown option $1" "$XINIT_EXIT_USAGE" ;;
      *)
        [ -z "$action" ] || xinit_die "maint: unexpected argument $1 ($usage)" "$XINIT_EXIT_USAGE"
        action="$1"
        shift
        ;;
    esac
  done
  case "$format" in
    text | json) ;;
    *) xinit_die "maint: unknown format $format (text, json)" "$XINIT_EXIT_USAGE" ;;
  esac
  case "$action" in
    on | off | status) ;;
    *) xinit_die "$usage" "$XINIT_EXIT_USAGE" ;;
  esac
  if [ "$action" != on ] && [ -n "$duration$reason" ]; then
    xinit_die "maint: --for and --reason go with 'on' ($usage)" "$XINIT_EXIT_USAGE"
  fi
  file="$(xinit_maint_file)"

  case "$action" in
    on)
      if [ -n "$duration" ]; then
        seconds="$(xinit_duration_seconds "$duration")" && [ "$seconds" -gt 0 ] ||
          xinit_die "maint: --for $duration is not a duration (30m, 2h, 1d...)" "$XINIT_EXIT_USAGE"
      else
        seconds="$(xinit_duration_seconds "${XINIT_CFG[MAINT_DURATION]-}")" &&
          [ "$seconds" -gt 0 ] ||
          xinit_die "MAINT_DURATION is not a duration: ${XINIT_CFG[MAINT_DURATION]-}"
      fi
      xinit_state_become_owner
      now="$(xinit_now)"
      xinit_state_write "$file" "UNTIL=$((now + seconds))" "SINCE=$now" \
        "BY=$(xinit_state_text "$(xinit_invoker)" 64)" \
        "REASON=$(xinit_state_text "$reason" 200)" ||
        xinit_die "cannot write $file: run this as root, or as the user who owns ${file%/*}"
      xinit_maint_load || xinit_die "cannot read back $file"
      xinit_log_journal "maintenance on for $(xinit_duration_text "$seconds")," \
        "by ${XINIT_MAINTENANCE[BY]}${XINIT_MAINTENANCE[REASON]:+: ${XINIT_MAINTENANCE[REASON]}}"
      ;;
    off)
      xinit_state_become_owner
      if [ -e "$file" ]; then
        rm -f -- "$file" 2>/dev/null && [ ! -e "$file" ] ||
          xinit_die "cannot remove $file: run this as root, or as the user who owns ${file%/*}"
        xinit_log_journal "maintenance off, by $(xinit_state_text "$(xinit_invoker)" 64)"
      fi
      XINIT_MAINTENANCE=()
      ;;
    status)
      rc=0
      xinit_maint_load || rc=$?
      [ "$rc" -ne 2 ] ||
        xinit_die "cannot read $file, or it does not hold a maintenance: try as root"
      ;;
  esac
  _xinit_maint_print "$format"
}
