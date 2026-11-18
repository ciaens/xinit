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
# `xinit warmup`: the first requests to XWiki after its start. Sourced, never executed.
#
# The first request to a wiki is slow: XWiki initializes then. This command makes those requests,
# so that the first visitor does not wait. A systemd unit runs it after each start of XWiki.

# The URLs to request, separated by spaces: one per wiki of a farm. A path (/bin/view/Main/) is
# taken under BASE_URL. Empty: the page of the http check.
xinit_config_define WARMUP_URLS ""
# How long to keep trying, in all.
xinit_config_define WARMUP_TIMEOUT 10min

# xinit_cmd_warmup: the `xinit warmup` command. It exits 0 when every URL answered 200.
xinit_cmd_warmup() {
  local timeout base url urls=() start="$SECONDS" pending done_count=0 next=()
  local re_url='^https?://[^[:space:]]+$'
  [ $# -eq 0 ] || xinit_die "warmup: unexpected argument $1" "$XINIT_EXIT_USAGE"
  timeout="$(xinit_duration_seconds "${XINIT_CFG[WARMUP_TIMEOUT]-}")" ||
    xinit_die "WARMUP_TIMEOUT is not a duration: ${XINIT_CFG[WARMUP_TIMEOUT]-}"
  xinit_config_number HTTP_TIMEOUT decimal >/dev/null ||
    xinit_die "HTTP_TIMEOUT must be a number of seconds"
  xinit_layout_resolve || true
  base="${XINIT_LAYOUT[BASE_URL]-}"
  for url in ${XINIT_CFG[WARMUP_URLS]:-${XINIT_CFG[HTTP_PATH]-}}; do
    if [[ "$url" == /* ]]; then
      [ -n "$base" ] || xinit_die "warmup: BASE_URL is not known: see 'xinit layout'"
      url="$base$url"
    fi
    [[ "$url" =~ $re_url ]] || xinit_die "warmup: not a URL or a path: $url"
    urls+=("$url")
  done
  [ "${#urls[@]}" -gt 0 ] || return 0

  pending=("${urls[@]}")
  while :; do
    next=()
    for url in "${pending[@]}"; do
      xinit_http_get "$url" -o /dev/null || true
      if [ "$XINIT_HTTP_EXIT" -eq 0 ] && [ "$XINIT_HTTP_CODE" = 200 ]; then
        printf 'ok      %s (%ss)\n' "$url" "$XINIT_HTTP_TIME"
        done_count=$((done_count + 1))
      else
        next+=("$url")
      fi
    done
    [ "${#next[@]}" -gt 0 ] || break
    pending=("${next[@]}")
    [ "$((SECONDS - start))" -lt "$timeout" ] || break
    sleep 5
  done
  if [ "${#next[@]}" -gt 0 ]; then
    for url in "${next[@]}"; do
      printf 'failed  %s\n' "$url"
    done
    xinit_log_journal "warm-up: $done_count of ${#urls[@]} URLs answered in $(xinit_duration_text "$timeout"); not: ${next[*]}"
    return "$XINIT_EXIT_CRIT"
  fi
  xinit_log_journal "warm-up: ${#urls[@]} of ${#urls[@]} URLs answered, in $(xinit_duration_text "$((SECONDS - start))")"
  return 0
}
