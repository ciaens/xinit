# shellcheck shell=bash
# Variables defined here are used by the scripts that source this file.
# shellcheck disable=SC2034
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
# What xinit does to a running XWiki: a thread dump, and a restart. Sourced, never executed.

# Where the last thread dump was stored, by xinit_thread_dump.
XINIT_THREAD_DUMP_FILE=""
# What the restart command said when it failed, for xinit_act_restart.
XINIT_ACT_ERROR=""
# How many thread dumps are kept.
XINIT_THREAD_DUMPS_KEPT=5

# The command that restarts XWiki, when it is not `systemctl restart <UNIT>`. It is split on
# spaces and run as is, without a shell.
xinit_config_define RESTART_CMD ""

# xinit_signal <signal name> <pid>: send a signal, with the kill command when there is one.
xinit_signal() {
  local bin
  [[ "$2" =~ ^[0-9]+$ ]] || return 1
  bin="$(type -P kill)" || bin=""
  if [ -n "$bin" ]; then
    "$bin" -s "$1" "$2" 2>/dev/null
  else
    kill -s "$1" "$2" 2>/dev/null
  fi
}

# xinit_act_thread_dump_signal: ask the JVM for a thread dump, which it writes to its output.
xinit_act_thread_dump_signal() {
  xinit_signal QUIT "${XINIT_LAYOUT[JVM_PID]-}"
}

# xinit_act_restart: restart XWiki. Returns 1 when that fails, with the reason in XINIT_ACT_ERROR.
xinit_act_restart() {
  local cmd="${XINIT_CFG[RESTART_CMD]-}" argv=() rc=0
  XINIT_ACT_ERROR=""
  if [ -n "$cmd" ]; then
    read -r -a argv < <(printf '%s\n' "$cmd")
  else
    argv=(systemctl restart -- "${XINIT_LAYOUT[UNIT]}")
  fi
  XINIT_ACT_ERROR="$("${argv[@]}" 2>&1 >/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  XINIT_ACT_ERROR="${argv[0]} failed with status $rc${XINIT_ACT_ERROR:+: ${XINIT_ACT_ERROR%%$'\n'*}}"
  return 1
}

# xinit_thread_dump: store a thread dump of the JVM in the state directory, and set
# XINIT_THREAD_DUMP_FILE. The JVM of the packages has no jcmd: it is asked with a signal, and
# answers in the journal. Returns 1 when there is no dump, with the reason in XINIT_ACT_ERROR.
xinit_thread_dump() {
  local source="${XINIT_LAYOUT[LOG_SOURCE]-}" dir since try seen=0 tmp file old files=()
  XINIT_THREAD_DUMP_FILE=""
  XINIT_ACT_ERROR=""
  if [ -z "${XINIT_LAYOUT[JVM_PID]-}" ]; then
    XINIT_ACT_ERROR="no JVM is running"
    return 1
  fi
  if [[ "$source" != journal:* ]]; then
    XINIT_ACT_ERROR="the JVM's output is only read from the systemd journal"
    return 1
  fi
  # The real time, also in a test that sets the clock: the journal has no other.
  since="$EPOCHSECONDS"
  if ! xinit_act_thread_dump_signal; then
    XINIT_ACT_ERROR="the JVM could not be sent a signal"
    return 1
  fi
  # The dump takes a moment to be written: once it shows, leave it one more second to end.
  for try in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    if ! _xinit_journal -u "${source#journal:}" --since "@$since"; then
      XINIT_ACT_ERROR="the journal cannot be read: $XINIT_JOURNAL_ERROR"
      return 1
    fi
    [ "$seen" -eq 0 ] || break
    case "$XINIT_JOURNAL_OUTPUT" in *"Full thread dump"*) seen="$try" ;; esac
  done
  if [ "$seen" -eq 0 ]; then
    XINIT_ACT_ERROR="the JVM wrote no thread dump"
    return 1
  fi
  dir="$(xinit_state_dir)"
  file="$dir/threaddump-$(printf '%(%Y%m%dT%H%M%S)T' "$(xinit_now)").txt"
  if ! xinit_dir_ensure "$dir" || ! tmp="$(mktemp -- "$file.XXXXXX" 2>/dev/null)"; then
    XINIT_ACT_ERROR="cannot write in $dir"
    return 1
  fi
  if ! printf '%s\n' "$XINIT_JOURNAL_OUTPUT" >"$tmp" || ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    XINIT_ACT_ERROR="cannot write $file"
    return 1
  fi
  XINIT_THREAD_DUMP_FILE="$file"
  # Keep the last ones: their names sort by time.
  for old in "$dir"/threaddump-*.txt; do
    [ -f "$old" ] && files+=("$old")
  done
  while [ "${#files[@]}" -gt "$XINIT_THREAD_DUMPS_KEPT" ]; do
    rm -f -- "${files[0]}"
    files=("${files[@]:1}")
  done
  return 0
}
