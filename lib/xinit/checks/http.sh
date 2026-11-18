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
# Check http: XWiki answers a page request, in time. Also the HTTP client the rest check shares.
# Sourced, never executed.

# The page to request, after BASE_URL.
xinit_config_define HTTP_PATH /bin/view/Main/
# The HTTP status codes that mean XWiki works, separated by spaces or commas.
xinit_config_define HTTP_EXPECT 200
# Seconds after which an answer is slow (warn), and after which the request is given up (crit).
xinit_config_define HTTP_SLOW 10
xinit_config_define HTTP_TIMEOUT 30
# "yes" to accept any TLS certificate, for an https BASE_URL with a self-signed one.
xinit_config_define HTTP_INSECURE no
# A netrc file with the login and password to send. By default,
# $XINIT_CONF_DIR/credentials/<instance>.netrc when it exists.
xinit_config_define HTTP_NETRC

# xinit_http_get <url> [curl options...]: one GET request, redirects not followed. Sets:
#   XINIT_HTTP_EXIT      curl's exit code (127 without curl)
#   XINIT_HTTP_ERROR     curl's error message, when the exit code is not 0
#   XINIT_HTTP_CODE      the HTTP status code, 000 without an answer
#   XINIT_HTTP_TIME      the duration in seconds, as 1.234567
#   XINIT_HTTP_REDIRECT  where a 3xx answer redirects to
#   XINIT_HTTP_BODY      the body, when the options do not send it elsewhere
xinit_http_get() {
  local url="$1" output line netrc="${XINIT_CFG[HTTP_NETRC]-}"
  shift
  local args=(-sS --max-time "${XINIT_CFG[HTTP_TIMEOUT]}" -A "xinit/$XINIT_VERSION"
    -w '\nXINIT-HTTP\t%{http_code}\t%{time_total}\t%{redirect_url}\n')
  XINIT_HTTP_EXIT=0 XINIT_HTTP_ERROR="" XINIT_HTTP_CODE=000 XINIT_HTTP_TIME=0
  XINIT_HTTP_REDIRECT="" XINIT_HTTP_BODY=""
  if ! command -v curl >/dev/null 2>&1; then
    XINIT_HTTP_EXIT=127 XINIT_HTTP_ERROR="curl is not installed"
    return 0
  fi
  [ -n "$netrc" ] || netrc="${XINIT_CONF_DIR:-/etc/xinit}/credentials/$XINIT_INSTANCE.netrc"
  # The password stays in the file: on a command line, every local user could read it.
  [ -r "$netrc" ] && args+=(--netrc-file "$netrc")
  [ "${XINIT_CFG[HTTP_INSECURE]}" = yes ] && args+=(--insecure)
  output="$(curl "${args[@]}" "$@" -- "$url" 2>&1)" || XINIT_HTTP_EXIT=$?
  while IFS= read -r line; do
    case "$line" in
      XINIT-HTTP$'\t'*)
        IFS=$'\t' read -r _ XINIT_HTTP_CODE XINIT_HTTP_TIME XINIT_HTTP_REDIRECT <<<"$line"
        ;;
      "curl: ("*) XINIT_HTTP_ERROR="${line#curl: (*) }" ;;
      *) XINIT_HTTP_BODY+="$line"$'\n' ;;
    esac
  done <<<"$output"
  return 0
}

# xinit_http_failure <check> <url> [metric...]: record the result for a request that did not give
# an expected answer, from the XINIT_HTTP_* variables. Shared by the http and rest checks.
xinit_http_failure() {
  local check="$1" url="$2" starting=""
  shift 2
  xinit_jvm_starting && starting=" (the JVM started less than ${XINIT_CFG[STARTUP_GRACE]}s ago)"
  case "$XINIT_HTTP_EXIT" in
    0)
      if [ "$XINIT_HTTP_CODE" = 202 ]; then
        # What XWiki answers to every request until it has finished starting.
        xinit_result "$check" warn initializing "XWiki is initializing (HTTP 202 from $url)" "$@"
      elif [[ "$XINIT_HTTP_CODE" == 3* && "$XINIT_HTTP_REDIRECT" == */bin/distribution/* ]]; then
        xinit_result "$check" warn wizard \
          "Distribution Wizard pending: an administrator has to finish it at $url" "$@"
      elif [[ "$XINIT_HTTP_CODE" == 3* ]]; then
        xinit_result "$check" crit redirect \
          "HTTP $XINIT_HTTP_CODE from $url, a redirect to $XINIT_HTTP_REDIRECT" "$@"
      else
        xinit_result "$check" crit status "HTTP $XINIT_HTTP_CODE from $url" "$@"
      fi
      ;;
    6)
      # Not XWiki's fault, and a restart would not help.
      xinit_result "$check" unknown dns "the host name of $url does not resolve" "$@"
      ;;
    7)
      if [ -n "$starting" ]; then
        xinit_result "$check" warn starting "connection refused by $url$starting" "$@"
      else
        xinit_result "$check" crit refused "connection refused by $url" "$@"
      fi
      ;;
    28)
      if [ -n "$starting" ]; then
        xinit_result "$check" warn starting \
          "no answer from $url within ${XINIT_CFG[HTTP_TIMEOUT]}s$starting" "$@"
      else
        xinit_result "$check" crit timeout "no answer from $url within ${XINIT_CFG[HTTP_TIMEOUT]}s" "$@"
      fi
      ;;
    127) xinit_result "$check" unknown no-curl "$XINIT_HTTP_ERROR" ;;
    *)
      xinit_result "$check" crit error \
        "request to $url failed: ${XINIT_HTTP_ERROR:-curl exit code $XINIT_HTTP_EXIT}" "$@"
      ;;
  esac
}

xinit_check_http() {
  local base="${XINIT_LAYOUT[BASE_URL]-}" url code expected=1 time_ms slow_ms metrics
  if [ -z "$base" ]; then
    xinit_result http unknown no-url "BASE_URL is not known"
    return 0
  fi
  url="$base${XINIT_CFG[HTTP_PATH]}"
  xinit_http_get "$url" -o /dev/null
  metrics=("code=$((10#$XINIT_HTTP_CODE))" "time_seconds=$XINIT_HTTP_TIME")
  if [ "$XINIT_HTTP_EXIT" -eq 0 ]; then
    for code in ${XINIT_CFG[HTTP_EXPECT]//,/ }; do
      [ "$code" = "$XINIT_HTTP_CODE" ] && expected=0
    done
  fi
  if [ "$expected" -ne 0 ]; then
    xinit_http_failure http "$url" "${metrics[@]}"
    return 0
  fi
  time_ms="$(xinit_seconds_to_ms "$XINIT_HTTP_TIME")"
  slow_ms="$(xinit_seconds_to_ms "${XINIT_CFG[HTTP_SLOW]}")"
  if [ "$time_ms" -ge "$slow_ms" ]; then
    xinit_result http warn slow \
      "HTTP $XINIT_HTTP_CODE from $url in ${XINIT_HTTP_TIME}s, slower than ${XINIT_CFG[HTTP_SLOW]}s" \
      "${metrics[@]}"
  else
    xinit_result http ok ok "HTTP $XINIT_HTTP_CODE from $url in ${XINIT_HTTP_TIME}s" "${metrics[@]}"
  fi
}
