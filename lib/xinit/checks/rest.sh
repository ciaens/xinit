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
# Check rest: XWiki's REST API answers, and tells the running version. Sourced, never executed.

xinit_check_rest() {
  local base="${XINIT_LAYOUT[BASE_URL]-}" url version installed="${XINIT_LAYOUT[VERSION]-}" metrics
  local re_version='"version"[[:space:]]*:[[:space:]]*"([^"]+)"'
  if [ -z "$base" ]; then
    xinit_result rest unknown no-url "BASE_URL is not known: see 'xinit layout'"
    return 0
  fi
  url="$base/rest/"
  xinit_http_get "$url" -H 'Accept: application/json'
  metrics=("code=$((10#$XINIT_HTTP_CODE))" "time_seconds=$XINIT_HTTP_TIME")
  if [ "$XINIT_HTTP_EXIT" -ne 0 ] || [ "$XINIT_HTTP_CODE" != 200 ]; then
    xinit_http_failure rest "$url" "${metrics[@]}"
    return 0
  fi
  if [[ ! "$XINIT_HTTP_BODY" =~ $re_version ]]; then
    xinit_result rest crit not-rest "$url answers, but not as XWiki's REST API" "${metrics[@]}"
    return 0
  fi
  version="${BASH_REMATCH[1]}"
  if [ -n "$installed" ] && [ "$installed" != "$version" ]; then
    xinit_result rest warn restart-pending \
      "XWiki $version is running, but $installed is installed: a restart is pending" \
      "${metrics[@]}"
  else
    xinit_result rest ok ok "the REST API answers, XWiki $version" "${metrics[@]}"
  fi
}
