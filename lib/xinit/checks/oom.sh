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
# Check oom: the JVM ran out of memory, or the kernel killed it for that. Sourced, never executed.
#
#   - heap: java.lang.OutOfMemoryError in the unit's log since the JVM started. A JVM that threw
#     it is unreliable until it is restarted: crit.
#   - kernel: the kernel's OOM killer killed a process of the unit: a warn. The memory settings
#     need attention, which a restart does not give. On cgroup v1 systemd only sees a process
#     killed by a signal, and has usually restarted XWiki by then. On cgroup v2 it knows of the
#     kill, ends the unit with the result oom-kill, and starts it again only when Restart= is
#     on-failure or always: the process check then says that the unit has failed.

# How far back to look, in seconds.
xinit_config_define OOM_WINDOW 3600

# _xinit_journal <journalctl arguments...>: put the messages, one per line, in
# XINIT_JOURNAL_OUTPUT. Returns 1 when the journal cannot be read, with the reason in
# XINIT_JOURNAL_ERROR.
_xinit_journal() {
  local notice
  XINIT_JOURNAL_ERROR=""
  XINIT_JOURNAL_OUTPUT=""
  # journalctl exits 0 for a user who may not read the system journal, and only says so. Ask for
  # no message at all, so that what it prints is its own words, not something XWiki logged.
  notice="$(journalctl --no-pager -o cat -n 0 "$@" 2>&1)" || true
  case "$notice" in
    *"insufficient permissions"* | *"not seeing messages from other users"*)
      XINIT_JOURNAL_ERROR="this user may not read it (add the user to the systemd-journal group)"
      return 1
      ;;
  esac
  if ! XINIT_JOURNAL_OUTPUT="$(journalctl --no-pager -o cat "$@" 2>/dev/null)"; then
    XINIT_JOURNAL_ERROR="journalctl failed${notice:+: ${notice%%$'\n'*}}"
    return 1
  fi
  return 0
}

xinit_check_oom() {
  local source="${XINIT_LAYOUT[LOG_SOURCE]-}" window unit
  local age heap_window log heap=0 kind="" kernel=0 by_systemd=0 cgroup pattern minutes metrics
  local down=""
  local re_heap='^((Exception in thread "[^"]*" )+|Caused by: )?java\.lang\.OutOfMemoryError(:|$)'
  if [[ "$source" != journal:* ]]; then
    xinit_result oom unknown no-journal \
      "only the systemd journal can be searched, and LOG_SOURCE is '${source:-not known}'"
    return 0
  fi
  if ! command -v journalctl >/dev/null 2>&1; then
    xinit_result oom unknown no-journal "journalctl is not installed"
    return 0
  fi
  if ! window="$(xinit_config_number OOM_WINDOW)"; then
    xinit_result oom unknown bad-config "OOM_WINDOW must be a number of seconds"
    return 0
  fi
  unit="${source#journal:}"
  minutes=$(((window + 59) / 60))

  # An OutOfMemoryError from before the JVM started belongs to a previous JVM. Without a JVM,
  # the last one counts: since the unit last started its main process.
  heap_window="$window"
  if { age="$(xinit_jvm_age)" || age="$(xinit_unit_age)"; } && [ "$age" -lt "$window" ]; then
    heap_window="$age"
  fi
  if ! _xinit_journal -u "$unit" --since "-${heap_window}s"; then
    xinit_result oom unknown no-access "the journal cannot be read: $XINIT_JOURNAL_ERROR"
    return 0
  fi
  log="$XINIT_JOURNAL_OUTPUT"
  # Pipes, not here-strings: bash may write those to a temporary file, and xinit writes nowhere.
  # Only the lines the JVM writes itself, or the cause in a stack trace: at the start of a line.
  # A message XWiki logs starts with its date, whatever text a request put in it.
  heap="$(printf '%s\n' "$log" | grep -cE "$re_heap")" || heap=0
  if [ "$heap" -gt 0 ]; then
    # What ran out: "Java heap space", "Metaspace", "unable to create native thread"...
    kind="$(printf '%s\n' "$log" | grep -E "$re_heap" |
      grep -o 'java\.lang\.OutOfMemoryError: [A-Za-z ]*' | head -n 1)" || kind=""
    kind="${kind#java.lang.OutOfMemoryError: }"
  fi

  # The kernel's message names the control group of the process it killed: exactly the unit's,
  # so that a unit of the same name in a container on this host is not taken for this one.
  cgroup="$(xinit_systemctl_show "$unit" ControlGroup)" || cgroup=""
  [ -n "$cgroup" ] || cgroup="/system.slice/$unit"
  pattern="task_memcg=$(_xinit_regex_quote "$cgroup")(,|\$)"
  if ! _xinit_journal --since "-${window}s" _TRANSPORT=kernel + _PID=1; then
    xinit_result oom unknown no-access "the journal cannot be read: $XINIT_JOURNAL_ERROR"
    return 0
  fi
  log="$XINIT_JOURNAL_OUTPUT"
  kernel="$(printf '%s\n' "$log" | grep -cE "$pattern")" || kernel=0
  # systemd says it too, where it can tell (cgroup v2), in words that changed with systemd 259.
  # One kill gives both messages: count it once.
  pattern="^$(_xinit_regex_quote "$unit"): (A process of this unit has been killed by the OOM killer|The kernel OOM killer killed some processes in this unit)"
  by_systemd="$(printf '%s\n' "$log" | grep -cE "$pattern")" || by_systemd=0
  [ "$by_systemd" -gt "$kernel" ] && kernel="$by_systemd"
  # And it keeps it as the result of a unit that it did not start again: whatever the words,
  # and whatever control group the unit had.
  if [ "$(xinit_systemctl_show "$unit" Result)" = oom-kill ]; then
    down=" The unit is still down: systemd does not start it again unless its Restart= says so."
    [ "$kernel" -gt 0 ] || kernel=1
  fi

  metrics=("heap_errors=$heap" "kernel_kills=$kernel")
  if [ "$heap" -gt 0 ] && [ -z "${XINIT_LAYOUT[JVM_PID]-}" ]; then
    xinit_result oom crit heap \
      "the last JVM of $unit logged $heap java.lang.OutOfMemoryError${kind:+ ($kind)} and is no longer running" \
      "${metrics[@]}"
  elif [ "$heap" -gt 0 ]; then
    xinit_result oom crit heap \
      "the JVM logged $heap java.lang.OutOfMemoryError${kind:+ ($kind)} since it started: restart it" \
      "${metrics[@]}"
  elif [ "$kernel" -gt 0 ]; then
    xinit_result oom warn kernel \
      "the kernel killed a process of $unit for lack of memory in the last $minutes min.$down" \
      "${metrics[@]}"
  else
    xinit_result oom ok ok "no out-of-memory error in the last $minutes min" "${metrics[@]}"
  fi
}
