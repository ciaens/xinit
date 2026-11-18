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
# Check process: the service is running, and its main process is a JVM. Sourced, never executed.

xinit_check_process() {
  local unit="${XINIT_LAYOUT[UNIT]-}" pid="${XINIT_LAYOUT[JVM_PID]-}"
  local load active result age restarts metrics=()
  if age="$(xinit_jvm_age)"; then
    metrics+=("uptime_seconds=$age")
  fi
  if [ -n "$unit" ] && load="$(xinit_systemctl_show "$unit" LoadState)" && [ -n "$load" ]; then
    if [ "$load" = not-found ]; then
      xinit_result process unknown no-unit "the unit $unit does not exist"
      return 0
    fi
    active="$(xinit_systemctl_show "$unit" ActiveState)" || active=""
    restarts="$(xinit_systemctl_show "$unit" NRestarts)" || restarts=""
    [[ "$restarts" =~ ^[0-9]+$ ]] && metrics+=("restarts=$restarts")
    case "$active" in
      active | reloading)
        if [ -n "$pid" ]; then
          xinit_result process ok running "$unit is running, JVM pid $pid" "${metrics[@]}"
        elif [ -n "${XINIT_CFG[PID_FILE]-}" ]; then
          xinit_result process crit stopped \
            "$unit is active, but no JVM is running with the PID in ${XINIT_CFG[PID_FILE]}" \
            "${metrics[@]}"
        else
          xinit_result process ok running \
            "$unit is running (its main process is not java: set PID_FILE to name the JVM)" \
            "${metrics[@]}"
        fi
        ;;
      activating) xinit_result process warn starting "$unit is starting" "${metrics[@]}" ;;
      deactivating) xinit_result process warn stopping "$unit is stopping" "${metrics[@]}" ;;
      failed)
        result="$(xinit_systemctl_show "$unit" Result)" || result=""
        xinit_result process crit failed "$unit has failed${result:+ ($result)}" "${metrics[@]}"
        ;;
      inactive) xinit_result process crit stopped "$unit is not running" "${metrics[@]}" ;;
      *) xinit_result process unknown state "$unit is in the state '$active'" "${metrics[@]}" ;;
    esac
    return 0
  fi
  # No systemd: only the PID file can tell.
  if [ -n "$pid" ]; then
    xinit_result process ok running "the JVM is running, pid $pid" "${metrics[@]}"
  elif [ -n "${XINIT_CFG[PID_FILE]-}" ]; then
    xinit_result process crit stopped "no JVM is running with the PID in ${XINIT_CFG[PID_FILE]}"
  else
    xinit_result process unknown no-unit "systemd does not answer, and PID_FILE is not set"
  fi
}
