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
# Core helpers shared by every xinit command. Sourced, never executed.

XINIT_VERSION="2.0.0-SNAPSHOT"

# Exit codes follow the Nagios plugin convention for check results, so that `xinit check` can be
# used as a plugin as is; usage errors use 64 (EX_USAGE) to stay distinct from results.
XINIT_EXIT_OK=0
XINIT_EXIT_WARN=1
XINIT_EXIT_CRIT=2
XINIT_EXIT_UNKNOWN=3
XINIT_EXIT_USAGE=64

# xinit_log <level> <message...>: to stderr, so that stdout stays the command's result.
xinit_log() {
  local level="$1"
  shift
  printf 'xinit: %s: %s\n' "$level" "$*" >&2
}

# xinit_die <message> [exit code, default 3 (unknown)]
xinit_die() {
  xinit_log error "$1"
  exit "${2:-$XINIT_EXIT_UNKNOWN}"
}
