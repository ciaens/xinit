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
# Notifications: telling people what xinit did. Sourced, never executed.
#
# For now a notification is a line in the system log. Mail and webhooks come with the reports.

# xinit_notify <event> <message>: send a notification. The events: restart, flapping.
xinit_notify() {
  xinit_log_journal "notification ($1): $2"
}

# xinit_cmd_notify crash: the `xinit notify` command, which the unit of XWiki starts when it stops
# for another reason than being asked to.
xinit_cmd_notify() {
  local event="${1:-}" unit line detail="" source
  [ $# -eq 1 ] && [ "$event" = crash ] || xinit_die "usage: xinit notify crash" "$XINIT_EXIT_USAGE"
  xinit_layout_resolve || true
  unit="${XINIT_LAYOUT[UNIT]-}"
  source="${XINIT_LAYOUT[LOG_SOURCE]-}"
  [ -n "$unit" ] || xinit_die "notify: no XWiki installation is known for the instance $XINIT_INSTANCE"
  # What systemd said about it.
  if [[ "$source" == journal:* ]] && _xinit_journal -u "${source#journal:}" --since "-120s"; then
    while IFS= read -r line; do
      case "$line" in
        *"Main process exited"* | *"Failed with result"*) detail="${line#*: }" ;;
      esac
    done < <(printf '%s\n' "$XINIT_JOURNAL_OUTPUT")
  fi
  xinit_notify crash "$unit stopped unexpectedly${detail:+: $detail}"
}
