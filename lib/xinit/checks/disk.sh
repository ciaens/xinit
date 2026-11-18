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
# Check disk: the file system of XWiki's permanent directory has room left. Sourced, never
# executed.

# Percentages of free space, and of free inodes, below which the check warns and is critical.
xinit_config_define DISK_WARN 10
xinit_config_define DISK_CRIT 5

# _xinit_df <df option> <path>: print "total available" from df's line for a path.
_xinit_df() {
  local _fs total _used available _rest
  { read -r _rest && read -r _fs total _used available _rest; } < <(df -P "$1" -- "$2" 2>/dev/null)
  [[ "$total" =~ ^[0-9]+$ && "$available" =~ ^[0-9]+$ ]] || return 1
  echo "$total $available"
}

xinit_check_disk() {
  local dir="${XINIT_LAYOUT[PERMDIR]-}" path total available free inodes_free="" status=ok reason=ok
  local warn="${XINIT_CFG[DISK_WARN]%\%}" crit="${XINIT_CFG[DISK_CRIT]%\%}" message metrics
  if [ -z "$dir" ]; then
    xinit_result disk unknown no-permdir "the permanent directory (PERMDIR) is not known"
    return 0
  fi
  if [[ ! "$warn" =~ ^[0-9]+$ || ! "$crit" =~ ^[0-9]+$ ]]; then
    xinit_result disk unknown bad-config "DISK_WARN and DISK_CRIT must be percentages"
    return 0
  fi
  path="${XINIT_ROOT:-}$dir"
  if [ ! -d "$path" ]; then
    xinit_result disk unknown no-dir "the permanent directory $dir does not exist, or cannot be reached"
    return 0
  fi
  if ! read -r total available < <(_xinit_df -k "$path") || [ "$total" -eq 0 ]; then
    xinit_result disk unknown df-failed "df cannot tell the free space of $dir"
    return 0
  fi
  free=$((available * 100 / total))
  metrics=("free_percent=$free" "free_bytes=$((available * 1024))")
  message="$free% free on the file system of $dir"
  # Some file systems have no fixed number of inodes: df then reports 0.
  if read -r total available < <(_xinit_df -i "$path") && [ "$total" -gt 0 ]; then
    inodes_free=$((available * 100 / total))
    metrics+=("inodes_free_percent=$inodes_free")
    message+=", $inodes_free% of its inodes free"
  fi
  if [ "$free" -lt "$crit" ] || { [ -n "$inodes_free" ] && [ "$inodes_free" -lt "$crit" ]; }; then
    status=crit reason=low
    message+=" (critical below $crit%)"
  elif [ "$free" -lt "$warn" ] || { [ -n "$inodes_free" ] && [ "$inodes_free" -lt "$warn" ]; }; then
    status=warn reason=low
    message+=" (warning below $warn%)"
  fi
  xinit_result disk "$status" "$reason" "$message" "${metrics[@]}"
}
