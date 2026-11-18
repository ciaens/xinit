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
# Check results and their output formats. Sourced, never executed.
#
# A result has:
#   - the name of the check;
#   - a status;
#   - a reason: a short word that says why, for programs (refused, timeout, slow...);
#   - a message, for people;
#   - metrics: name=number pairs, where the name ends with its unit (time_seconds, free_percent,
#     free_bytes).
#
# Statuses, and the exit code each one gives (the Nagios plugin convention):
#   ok 0       the check passed
#   warn 1     needs attention, but XWiki is serving, or is about to
#   crit 2     XWiki is not serving
#   unknown 3  the check could not tell

declare -ga XINIT_RESULT_CHECK=() XINIT_RESULT_STATUS=() XINIT_RESULT_REASON=()
declare -ga XINIT_RESULT_MESSAGE=() XINIT_RESULT_METRICS=()

# xinit_result <check> <status> <reason> <message> [metric=number...]: record one result.
xinit_result() {
  local check="$1" status="$2" reason="$3" message="$4"
  shift 4
  case "$status" in
    ok | warn | crit | unknown) ;;
    *) xinit_die "internal error: check $check returned the status '$status'" ;;
  esac
  XINIT_RESULT_CHECK+=("$check")
  XINIT_RESULT_STATUS+=("$status")
  XINIT_RESULT_REASON+=("$reason")
  XINIT_RESULT_MESSAGE+=("$message")
  XINIT_RESULT_METRICS+=("$*")
}

# _xinit_status_rank <status>: print how bad it is. A problem that is known outranks a check that
# could not tell, so that one unknown never hides a crit.
_xinit_status_rank() {
  case "$1" in
    ok) echo 0 ;;
    unknown) echo 1 ;;
    warn) echo 2 ;;
    crit) echo 3 ;;
  esac
}

# xinit_results_status: print the overall status, which is the worst one. With no result: unknown.
xinit_results_status() {
  local status worst="" rank worst_rank=-1
  for status in "${XINIT_RESULT_STATUS[@]}"; do
    rank="$(_xinit_status_rank "$status")"
    if [ "$rank" -gt "$worst_rank" ]; then
      worst="$status"
      worst_rank="$rank"
    fi
  done
  echo "${worst:-unknown}"
}

# xinit_status_exit_code <status>: print its exit code.
xinit_status_exit_code() {
  case "$1" in
    ok) echo "$XINIT_EXIT_OK" ;;
    warn) echo "$XINIT_EXIT_WARN" ;;
    crit) echo "$XINIT_EXIT_CRIT" ;;
    *) echo "$XINIT_EXIT_UNKNOWN" ;;
  esac
}

# xinit_json_string <text>: print it as a JSON string, quotes included.
xinit_json_string() {
  local text="$1" out="" char i code
  # Quoted replacements: bash 5.2 otherwise reads & in a replacement as "the matched text".
  local bs='\\' dq='\"'
  text="${text//\\/"$bs"}"
  text="${text//\"/"$dq"}"
  text="${text//$'\n'/\\n}"
  text="${text//$'\r'/\\r}"
  text="${text//$'\t'/\\t}"
  if [[ "$text" == *[[:cntrl:]]* ]]; then
    for ((i = 0; i < ${#text}; i++)); do
      char="${text:i:1}"
      if [[ "$char" == [[:cntrl:]] ]]; then
        printf -v code '%d' "'$char"
        printf -v char '\\u%04x' "$code"
      fi
      out+="$char"
    done
    text="$out"
  fi
  printf '"%s"' "$text"
}

# _xinit_results_json [member]: {"instance":…,"status":…,"results":[{"check":…,"status":…,"reason":…,
# "message":…,"metrics":{…}}]}
_xinit_results_json() {
  local i metric sep="" msep
  # JSON numbers have no leading zero.
  local re_number='^-?(0|[1-9][0-9]*)(\.[0-9]+)?$'
  printf '{"instance":%s,"status":"%s","results":[' \
    "$(xinit_json_string "$XINIT_INSTANCE")" "$(xinit_results_status)"
  for i in "${!XINIT_RESULT_CHECK[@]}"; do
    printf '%s{"check":"%s","status":"%s","reason":"%s","message":%s,"metrics":{' "$sep" \
      "${XINIT_RESULT_CHECK[$i]}" "${XINIT_RESULT_STATUS[$i]}" "${XINIT_RESULT_REASON[$i]}" \
      "$(xinit_json_string "${XINIT_RESULT_MESSAGE[$i]}")"
    msep=""
    for metric in ${XINIT_RESULT_METRICS[$i]}; do
      if [[ "${metric#*=}" =~ $re_number ]]; then
        printf '%s"%s":%s' "$msep" "${metric%%=*}" "${metric#*=}"
      else
        printf '%s"%s":%s' "$msep" "${metric%%=*}" "$(xinit_json_string "${metric#*=}")"
      fi
      msep=","
    done
    printf '}}'
    sep=","
  done
  printf ']%s}\n' "${1:+,$1}"
}

# _xinit_results_text: one line per result, then the overall status.
_xinit_results_text() {
  local i
  for i in "${!XINIT_RESULT_CHECK[@]}"; do
    printf '%-8s %-8s %s\n' "${XINIT_RESULT_STATUS[$i]}" "${XINIT_RESULT_CHECK[$i]}" \
      "${XINIT_RESULT_MESSAGE[$i]}"
  done
  printf 'overall: %s\n' "$(xinit_results_status)"
}

# _xinit_nagios_word <status>: print the word Nagios uses for it.
_xinit_nagios_word() {
  case "$1" in
    ok) echo OK ;;
    warn) echo WARNING ;;
    crit) echo CRITICAL ;;
    *) echo UNKNOWN ;;
  esac
}

# _xinit_results_nagios: the Nagios plugin output.
#   XINIT <STATUS> - <what is wrong, or how many checks passed> | <performance data>
#   [<STATUS>] <check>: <message>          (one line per result, as the long output)
_xinit_results_nagios() {
  local i metric name value unit status summary="" perfdata="" wanted count="${#XINIT_RESULT_CHECK[@]}"
  # What is wrong, the worst first.
  for wanted in crit warn unknown; do
    for i in "${!XINIT_RESULT_CHECK[@]}"; do
      [ "${XINIT_RESULT_STATUS[$i]}" = "$wanted" ] || continue
      summary+="${summary:+; }${XINIT_RESULT_CHECK[$i]}: ${XINIT_RESULT_MESSAGE[$i]}"
    done
  done
  [ -n "$summary" ] || summary="$count checks passed"
  for i in "${!XINIT_RESULT_CHECK[@]}"; do
    for metric in ${XINIT_RESULT_METRICS[$i]}; do
      name="${metric%%=*}"
      value="${metric#*=}"
      unit=""
      case "$name" in
        *_seconds) unit=s ;;
        *_percent) unit=% ;;
        *_bytes) unit=B ;;
      esac
      perfdata+="${perfdata:+ }${XINIT_RESULT_CHECK[$i]}_$name=$value$unit"
    done
  done
  status="$(xinit_results_status)"
  # | separates the text from the performance data: it cannot appear in the text.
  printf 'XINIT %s - %s%s\n' "$(_xinit_nagios_word "$status")" "${summary//|/ }" \
    "${perfdata:+ | $perfdata}"
  for i in "${!XINIT_RESULT_CHECK[@]}"; do
    printf '[%s] %s: %s\n' "$(_xinit_nagios_word "${XINIT_RESULT_STATUS[$i]}")" \
      "${XINIT_RESULT_CHECK[$i]}" "${XINIT_RESULT_MESSAGE[$i]//|/ }"
  done
}

# xinit_results_print <text|json|nagios> [one more JSON member, as "name":value]
xinit_results_print() {
  case "$1" in
    text) _xinit_results_text ;;
    json) _xinit_results_json "${2:-}" ;;
    nagios) _xinit_results_nagios ;;
  esac
}
