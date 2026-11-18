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

# The two things xinit does to XWiki need root. A periodic job that is not root asks for them:
# it creates a file named after the request in its runtime directory, which a systemd path unit
# watches. The unit starts `xinit act` as root, which does what the name of the file says, and
# reads nothing from it.
XINIT_ACT_REQUESTS=(thread-dump restart)

# _xinit_act_request <thread-dump|restart> <seconds to wait for the end>: ask root for it, and
# wait until it is done. Returns 1 when it is not, with the reason in XINIT_ACT_ERROR.
_xinit_act_request() {
  local request="$1" patience="$2" dir file unit state="" waited=0
  dir="$(xinit_run_dir)"
  file="$dir/request-$request"
  unit="xinit-act@$XINIT_INSTANCE.service"
  if ! xinit_dir_ensure "$dir" || ! : >"$file"; then
    XINIT_ACT_ERROR="cannot write $file"
    return 1
  fi
  # Taken: the file is gone.
  while [ -e "$file" ]; do
    if [ "$waited" -ge 15 ]; then
      rm -f -- "$file"
      XINIT_ACT_ERROR="nothing answered the request: only root can do this, through $unit, which 'xinit setup' installs"
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  # Done: the unit has ended.
  waited=0
  while [ "$waited" -lt "$patience" ]; do
    state="$(xinit_systemctl_show "$unit" ActiveState)" || state=""
    case "$state" in
      activating | active | deactivating | reloading) ;;
      failed)
        XINIT_ACT_ERROR="$unit failed: see 'journalctl -u $unit'"
        return 1
        ;;
      *) return 0 ;;
    esac
    sleep 1
    waited=$((waited + 1))
  done
  XINIT_ACT_ERROR="$unit did not end in $patience seconds"
  return 1
}

# _xinit_act_is_root: this process may restart a unit and signal its JVM itself.
_xinit_act_is_root() { [ "$(id -u)" = 0 ]; }

# xinit_act_thread_dump_signal: ask the JVM for a thread dump, which it writes to its output.
xinit_act_thread_dump_signal() {
  if _xinit_act_is_root; then
    xinit_signal QUIT "${XINIT_LAYOUT[JVM_PID]-}"
  else
    _xinit_act_request thread-dump 30
  fi
}

# xinit_act_restart: restart XWiki. A job that is not root asks root for it. Returns 1 when that
# fails, with the reason in XINIT_ACT_ERROR.
xinit_act_restart() {
  local cmd="${XINIT_CFG[RESTART_CMD]-}" unit="${XINIT_LAYOUT[UNIT]-}" argv=() rc=0
  XINIT_ACT_ERROR=""
  if ! _xinit_act_is_root; then
    # The watch unit waits 15 minutes in all: the thread dump and this have to fit.
    _xinit_act_request restart 540
    return $?
  fi
  if [ -n "$cmd" ]; then
    read -r -a argv < <(printf '%s\n' "$cmd")
    if [ "${#argv[@]}" -eq 0 ]; then
      XINIT_ACT_ERROR="RESTART_CMD is empty"
      return 1
    fi
    # Its output is not read, and it does not get the lock: a command that leaves a process
    # behind, as a start script does, would otherwise keep this run waiting, and the lock held.
    if [ -n "$XINIT_LOCK_FD" ]; then
      "${argv[@]}" </dev/null >/dev/null 2>&1 {XINIT_LOCK_FD}>&- || rc=$?
    else
      "${argv[@]}" </dev/null >/dev/null 2>&1 || rc=$?
    fi
    [ "$rc" -eq 0 ] && return 0
    XINIT_ACT_ERROR="RESTART_CMD (${argv[0]}) failed with status $rc"
    return 1
  fi
  if [ -z "$unit" ]; then
    XINIT_ACT_ERROR="neither UNIT nor RESTART_CMD is known: nothing to restart XWiki with"
    return 1
  fi
  XINIT_ACT_ERROR="$(systemctl restart -- "$unit" 2>&1 >/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  XINIT_ACT_ERROR="systemctl failed with status $rc${XINIT_ACT_ERROR:+: ${XINIT_ACT_ERROR%%$'\n'*}}"
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
    XINIT_ACT_ERROR="the JVM could not be sent a signal${XINIT_ACT_ERROR:+: $XINIT_ACT_ERROR}"
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

# xinit_cmd_act: the `xinit act` command, which the path unit starts as root. It does what the
# request files of the periodic job ask for, and nothing else: their content is never read.
xinit_cmd_act() {
  local dir request file rc=0 pid
  [ $# -eq 0 ] || xinit_die "act: unexpected argument $1" "$XINIT_EXIT_USAGE"
  [ "$(id -u)" = 0 ] || xinit_die "act: only root can do this"
  dir="$(xinit_run_dir)"
  if ! xinit_layout_resolve && [ -z "${XINIT_LAYOUT[UNIT]-}${XINIT_CFG[RESTART_CMD]-}" ]; then
    # Nothing can be done, and the requests must not start this again and again.
    for request in "${XINIT_ACT_REQUESTS[@]}"; do
      rm -f -- "$dir/request-$request"
    done
    xinit_die "act: no XWiki installation is known for the instance $XINIT_INSTANCE"
  fi
  for request in "${XINIT_ACT_REQUESTS[@]}"; do
    file="$dir/request-$request"
    # Also a link that leads nowhere: what counts is the name.
    [ -e "$file" ] || [ -L "$file" ] || continue
    rm -f -- "$file" || xinit_die "act: cannot remove $file"
    case "$request" in
      thread-dump)
        pid="${XINIT_LAYOUT[JVM_PID]-}"
        if [ -n "$pid" ] && xinit_signal QUIT "$pid"; then
          xinit_log_journal "asked the JVM $pid for a thread dump, on request"
        else
          xinit_log_journal "no thread dump: no JVM to ask"
        fi
        ;;
      restart)
        xinit_log_journal "restarting ${XINIT_LAYOUT[UNIT]:-XWiki}, on request"
        if ! xinit_act_restart; then
          xinit_log_journal "the restart failed: $XINIT_ACT_ERROR"
          xinit_log error "the restart failed: $XINIT_ACT_ERROR"
          rc="$XINIT_EXIT_UNKNOWN"
        fi
        ;;
    esac
  done
  return "$rc"
}
