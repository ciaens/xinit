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
# What xinit remembers and locks, for one instance. Sourced, never executed.
#
#   <STATE_DIR>/<instance>/   what has to survive a reboot: the maintenance, the failure counters;
#   <RUN_DIR>/<instance>/     what does not: the lock.
#
# A state file holds one KEY=value per line, the value running to the end of the line. It is
# parsed, never sourced. It is replaced in one rename, so a reader never sees half of it.

# Where the state of every instance is kept.
xinit_config_define STATE_DIR /var/lib/xinit
# Where the locks of every instance are kept.
xinit_config_define RUN_DIR /run/xinit

# The file descriptor of the lock, once xinit_lock_acquire has it.
XINIT_LOCK_FD=""

# xinit_now: print the time, in seconds since the epoch. XINIT_TEST_NOW replaces the clock, for
# the tests.
xinit_now() {
  local now="${XINIT_TEST_NOW:-$EPOCHSECONDS}"
  [[ "$now" =~ ^[0-9]{1,12}$ ]] || xinit_die "XINIT_TEST_NOW is not a time: $now"
  printf '%s\n' "$((10#$now))"
}

# xinit_duration_seconds <duration>: print a duration in seconds. A duration is a number of
# seconds (90), or numbers with a unit: s or sec, m or min, h, d (15min, 2h, 1h30m). Returns 1
# when it is not a duration.
xinit_duration_seconds() {
  local text="$1" total=0 n factor
  local re='^([0-9]{1,9})(sec|s|min|m|h|d)?(.*)$'
  [ -n "$text" ] || return 1
  while [ -n "$text" ]; do
    [[ "$text" =~ $re ]] || return 1
    n="${BASH_REMATCH[1]}"
    text="${BASH_REMATCH[3]}"
    case "${BASH_REMATCH[2]}" in
      m | min) factor=60 ;;
      h) factor=3600 ;;
      d) factor=86400 ;;
      s | sec) factor=1 ;;
      *)
        # A number without a unit is the last one: more digits after it are one long number.
        [ -z "$text" ] || return 1
        factor=1
        ;;
    esac
    total=$((total + 10#$n * factor))
  done
  printf '%s\n' "$total"
}

# xinit_duration_text <seconds>: print a duration for a reader, with its two largest units
# (1h59m, 2d3h, 45s).
xinit_duration_text() {
  local seconds="$1" out="" count=0 unit size
  for unit in d:86400 h:3600 m:60 s:1; do
    size="${unit#*:}"
    if [ "$seconds" -ge "$size" ] && [ "$count" -lt 2 ]; then
      out+="$((seconds / size))${unit%%:*}"
      seconds=$((seconds % size))
      count=$((count + 1))
    elif [ "$count" -gt 0 ]; then
      # Only two units that follow each other: 1d5s says less than 1d0h.
      break
    fi
  done
  printf '%s\n' "${out:-0s}"
}

# _xinit_instance_dir <KEY>: print the directory of this instance under STATE_DIR or RUN_DIR.
_xinit_instance_dir() {
  local top="${XINIT_CFG[$1]-}"
  [[ "$top" == /* ]] || xinit_die "$1 has to be an absolute path: $top"
  while [ "${#top}" -gt 1 ] && [ "${top%/}" != "$top" ]; do
    top="${top%/}"
  done
  printf '%s/%s\n' "${top%/}" "$XINIT_INSTANCE"
}

# xinit_state_dir: print the state directory of this instance.
xinit_state_dir() { _xinit_instance_dir STATE_DIR; }

# xinit_run_dir: print the runtime directory of this instance.
xinit_run_dir() { _xinit_instance_dir RUN_DIR; }

# xinit_dir_ensure <directory>: create it, for its owner only. Returns 1 when that fails.
xinit_dir_ensure() {
  [ -d "$1" ] && return 0
  (umask 077 && mkdir -p -- "$1") 2>/dev/null
}

# xinit_state_become_owner: root never writes in a directory that belongs to another user. When
# STATE_DIR does, as it does once the periodic job runs as its own user, run this xinit command
# again as that user. What it writes is then also readable by the periodic job.
xinit_state_become_owner() {
  local top="${XINIT_CFG[STATE_DIR]-}" owner uid gid
  [ "$(id -u)" = 0 ] || return 0
  [ -d "$top" ] || return 0
  owner="$(stat -c '%u:%g' -- "$top" 2>/dev/null)" || return 0
  uid="${owner%%:*}"
  gid="${owner#*:}"
  [[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] || return 0
  [ "$uid" != 0 ] || return 0
  command -v setpriv >/dev/null ||
    xinit_die "$top belongs to user $uid: setpriv (util-linux) is needed to write there as root"
  # Who asked, before it reads as the owner of the directory.
  XINIT_INVOKER="$(xinit_invoker)"
  export XINIT_INVOKER
  exec setpriv --reuid="$uid" --regid="$gid" --clear-groups -- "$XINIT_SELF" "${XINIT_ARGV[@]}"
}

# xinit_invoker: print the name of the user who runs this command, through sudo or not.
xinit_invoker() {
  local name="${XINIT_INVOKER:-${SUDO_USER:-}}"
  [ -n "$name" ] || name="$(id -un 2>/dev/null)" || name="unknown"
  printf '%s\n' "$name"
}

# xinit_state_write <file> <KEY=value>...: replace a state file. Returns 1 when that fails.
xinit_state_write() {
  local file="$1" tmp
  shift
  xinit_dir_ensure "${file%/*}" || return 1
  # mktemp creates the file for its owner only.
  tmp="$(mktemp -- "$file.XXXXXX" 2>/dev/null)" || return 1
  if printf '%s\n' "$@" >"$tmp" && mv -f -- "$tmp" "$file"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# xinit_state_read <file> <associative array name>: read a state file into the array. Returns 1
# when there is no such file, 2 when it cannot be read or when this user cannot tell.
xinit_state_read() {
  local file="$1" line dir
  local -n _state="$2"
  local re='^([A-Z][A-Z0-9_]*)=(.*)$'
  _state=()
  if [ ! -e "$file" ]; then
    # Missing, or out of sight: in a directory this user may not look into.
    dir="${file%/*}"
    while [ -n "$dir" ] && [ ! -e "$dir" ]; do
      dir="${dir%/*}"
    done
    [ -z "$dir" ] || [ -x "$dir" ] || return 2
    return 1
  fi
  [ -f "$file" ] && [ -r "$file" ] || return 2
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ $re ]] || continue
    _state[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
  done <"$file"
}

# xinit_state_text <text> <max length>: print a text as a state file can hold it: on one line,
# without control characters, and cut to the length.
xinit_state_text() {
  local text="${1//[[:cntrl:]]/ }"
  printf '%s\n' "${text:0:$2}"
}

# xinit_lock_acquire: take the lock of this instance, until this process ends. Returns 1 when
# another process holds it. Does not wait.
xinit_lock_acquire() {
  local dir
  dir="$(xinit_run_dir)"
  xinit_dir_ensure "$dir" || xinit_die "cannot create $dir"
  if ! { exec {XINIT_LOCK_FD}>>"$dir/lock"; } 2>/dev/null; then
    XINIT_LOCK_FD=""
    xinit_die "cannot open the lock $dir/lock"
  fi
  flock -n "$XINIT_LOCK_FD"
}
