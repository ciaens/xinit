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
# `xinit report`: what an admin needs to understand a failure, in one archive. Sourced, never
# executed.
#
# The archive holds the layout, the results of the checks, thread dumps of the JVM and what they
# say, the end of the log, the sockets, the activity of the database and the disks. It is written
# for its owner only: a thread dump or a log line may hold what a user typed.

# How many reports are kept in the state directory.
xinit_config_define REPORT_KEEP 10
# How many lines of the log go in a report.
xinit_config_define REPORT_JOURNAL_LINES 2000
# yes: the report holds the text of the queries the database is running. They may hold data of
# the wiki.
xinit_config_define REPORT_DB_QUERIES no
# How long to wait between two thread dumps.
xinit_config_define THREADDUMP_INTERVAL 5s

# How many thread dumps a report takes.
XINIT_REPORT_DUMPS=3
# A secret shorter than this is not searched for in a report: it would match too much.
XINIT_REPORT_SECRET_MIN=8

# The report being built or just built: FILE, DUMPS, OOM, DEADLOCK, ERROR, and while it is
# built WORK (the temporary directory), KEEP, LINES, INTERVAL, QUERIES.
# With HOLD=true, set before xinit_report_build, the temporary directory stays until
# xinit_report_release, and ARCHIVE is the archive in it, NAME its name without .tar.gz: what a
# mail attaches.
declare -gA XINIT_REPORT=()
# Its summary, a text.
XINIT_REPORT_SUMMARY=""
# Its sections, each "name<tab>ok" or "name<tab>skipped: why".
XINIT_REPORT_SECTIONS=()

# xinit_report_config: read the configuration of the reports. Returns 1 when a value is wrong,
# with the reason in XINIT_REPORT[ERROR].
xinit_report_config() {
  XINIT_REPORT[ERROR]=""
  if ! XINIT_REPORT[KEEP]="$(xinit_config_number REPORT_KEEP)" || [ "${XINIT_REPORT[KEEP]}" -lt 1 ]; then
    XINIT_REPORT[ERROR]="REPORT_KEEP has to be a number, 1 or more: ${XINIT_CFG[REPORT_KEEP]-}"
    return 1
  fi
  if ! XINIT_REPORT[LINES]="$(xinit_config_number REPORT_JOURNAL_LINES)"; then
    XINIT_REPORT[ERROR]="REPORT_JOURNAL_LINES has to be a number: ${XINIT_CFG[REPORT_JOURNAL_LINES]-}"
    return 1
  fi
  if ! XINIT_REPORT[INTERVAL]="$(xinit_duration_seconds "${XINIT_CFG[THREADDUMP_INTERVAL]-}")" ||
    [ "${XINIT_REPORT[INTERVAL]}" -gt 300 ]; then
    XINIT_REPORT[ERROR]="THREADDUMP_INTERVAL has to be a duration of 5 minutes at most: ${XINIT_CFG[THREADDUMP_INTERVAL]-}"
    return 1
  fi
  case "${XINIT_CFG[REPORT_DB_QUERIES]-}" in
    yes | no) XINIT_REPORT[QUERIES]="${XINIT_CFG[REPORT_DB_QUERIES]}" ;;
    *)
      XINIT_REPORT[ERROR]="REPORT_DB_QUERIES has to be yes or no: ${XINIT_CFG[REPORT_DB_QUERIES]-}"
      return 1
      ;;
  esac
}

# _xinit_report_section <name> <ok | skipped: why>: remember what became of a section.
_xinit_report_section() { XINIT_REPORT_SECTIONS+=("$1"$'\t'"$2"); }

# _xinit_report_cleanup: remove the temporary directory, if there is one.
_xinit_report_cleanup() {
  local work="${XINIT_REPORT[WORK]-}"
  XINIT_REPORT[WORK]=""
  case "$work" in
    */xinit-report.*) [ ! -d "$work" ] || rm -rf -- "$work" ;;
  esac
  return 0
}

# _xinit_report_time <seconds since the epoch> <strftime format>: print that time, in UTC.
_xinit_report_time() { TZ=UTC printf "%($2)T\n" "$1"; }

# _xinit_report_unescape <text>: print it with each backslash removed, and the character after
# it kept: how a password is written in .pgpass, and between quotes in .my.cnf.
_xinit_report_unescape() {
  local text="$1" out="" i char
  for ((i = 0; i < ${#text}; i++)); do
    char="${text:i:1}"
    if [ "$char" = "\\" ] && [ "$((i + 1))" -lt "${#text}" ]; then
      i=$((i + 1))
      char="${text:i:1}"
    fi
    out+="$char"
  done
  printf '%s\n' "$out"
}

# _xinit_report_secrets: print the secrets this user can read, one per line: the password of the
# database, and the one xinit logs in to XWiki with.
_xinit_report_secrets() {
  local file line word next=0 value
  local re_pgpass='^(([^:\\]|\\.)*:){4}(.*)$'
  local re_mycnf='^[[:space:]]*password[[:space:]]*=[[:space:]]*(.*)$'
  file="${XINIT_ROOT:-}${XINIT_LAYOUT[CONFIG_DIR]-}/hibernate.cfg.xml"
  if [ -n "${XINIT_LAYOUT[CONFIG_DIR]-}" ] && [ -r "$file" ]; then
    xinit_hibernate_get "$file" connection.password 2>/dev/null || true
  fi
  file="$(_xinit_db_credentials)"
  if [ -f "$file" ] && [ -r "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$file" in
        *.cnf)
          [[ "$line" =~ $re_mycnf ]] || continue
          value="${BASH_REMATCH[1]%"${BASH_REMATCH[1]##*[![:space:]]}"}"
          if [[ "$value" == \"*\" ]]; then
            value="${value#\"}"
            _xinit_report_unescape "${value%\"}"
          else
            printf '%s\n' "$value"
          fi
          ;;
        *)
          [[ "$line" =~ $re_pgpass ]] || continue
          _xinit_report_unescape "${BASH_REMATCH[3]}"
          ;;
      esac
    done <"$file"
  fi
  file="${XINIT_CFG[HTTP_NETRC]-}"
  [ -n "$file" ] || file="${XINIT_CONF_DIR:-/etc/xinit}/credentials/$XINIT_INSTANCE.netrc"
  if [ -f "$file" ] && [ -r "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      for word in $line; do
        [ "$next" -eq 0 ] || printf '%s\n' "$word"
        next=0
        [ "$word" != password ] || next=1
      done
    done <"$file"
  fi
  return 0
}

# _xinit_report_scrub <directory>: replace the secrets this user can read, wherever they show in
# the files of the directory. A thread dump, a log line or a command line may hold one.
_xinit_report_scrub() {
  local dir="$1" secret secrets=() file
  while IFS= read -r secret; do
    [ "${#secret}" -ge "$XINIT_REPORT_SECRET_MIN" ] || continue
    [[ "$secret" != *[[:cntrl:]]* ]] || continue
    secrets+=("$secret")
  done < <(_xinit_report_secrets)
  [ "${#secrets[@]}" -gt 0 ] || return 0
  while IFS= read -r -d '' file; do
    # The secrets come on the standard input: never on a command line.
    printf '%s\n' "${secrets[@]}" | awk '
      NR == FNR { secret[++count] = $0; next }
      {
        line = $0
        for (i = 1; i <= count; i++) {
          out = ""
          while ((at = index(line, secret[i])) > 0) {
            out = out substr(line, 1, at - 1) "<redacted>"
            line = substr(line, at + length(secret[i]))
          }
          line = out line
        }
        print line
      }' - "$file" >"$file.scrubbed" && mv -f -- "$file.scrubbed" "$file" || return 1
  done < <(find "$dir" -type f -print0)
}

# _xinit_report_basics <directory>: the layout, the configuration and the results of the checks.
_xinit_report_basics() {
  xinit_layout_print text >"$1/layout.txt"
  xinit_config_dump >"$1/config.txt"
  xinit_results_print json >"$1/checks.json"
  _xinit_report_section layout ok
  _xinit_report_section checks ok
}

# _xinit_report_system <directory>: the load and the memory of the host. Sets
# XINIT_REPORT[SYSTEM], a line for the summary.
_xinit_report_system() {
  local dir="$1" proc="${XINIT_ROOT:-}/proc" load="" key value _unit total="" available="" line
  XINIT_REPORT[SYSTEM]=""
  if [ ! -r "$proc/meminfo" ] || [ ! -r "$proc/loadavg" ]; then
    _xinit_report_section system "skipped: /proc cannot be read"
    return 0
  fi
  read -r load <"$proc/loadavg" || true
  {
    printf 'Load: %s\n\n' "$load"
    while IFS= read -r line; do
      case "$line" in
        MemTotal:* | MemFree:* | MemAvailable:* | Buffers:* | Cached:* | SwapTotal:* | SwapFree:* | Committed_AS:*)
          printf '%s\n' "$line"
          ;;
      esac
    done <"$proc/meminfo"
  } >"$dir/system.txt"
  while read -r key value _unit; do
    case "$key" in
      MemTotal:) total="$value" ;;
      MemAvailable:) available="$value" ;;
    esac
  done <"$proc/meminfo"
  load="${load% * *}"
  XINIT_REPORT[SYSTEM]="Host: load $load"
  if [[ "$total" =~ ^[0-9]+$ && "$available" =~ ^[0-9]+$ ]]; then
    XINIT_REPORT[SYSTEM]+=", $((available / 1024)) MB of memory available out of $((total / 1024)) MB"
  fi
  _xinit_report_section system ok
}

# _xinit_report_jvm <directory>: the process of the JVM: its command line, without the values
# that look like secrets, and its memory. Sets XINIT_REPORT[JVM], a line for the summary.
_xinit_report_jvm() {
  local dir="$1" pid="${XINIT_LAYOUT[JVM_PID]-}" proc arg name hide=0 age="" line
  local threads="" rss="" key value _unit
  local re_secret='pass|secret|token|key|credential'
  XINIT_REPORT[JVM]="JVM: not running"
  if [ -z "$pid" ]; then
    _xinit_report_section jvm "skipped: no JVM is running"
    return 0
  fi
  proc="${XINIT_ROOT:-}/proc/$pid"
  age="$(xinit_jvm_age)" || age=""
  {
    printf 'PID: %s\n' "$pid"
    [ -z "$age" ] || printf 'Running for: %s\n' "$(xinit_duration_text "$age")"
    if [ -r "$proc/cmdline" ]; then
      printf '\nCommand line, one argument per line:\n'
      while IFS= read -r -d '' arg || [ -n "$arg" ]; do
        arg="${arg//[[:cntrl:]]/ }"
        name="${arg%%=*}"
        if [ "$hide" -eq 1 ]; then
          arg="<redacted>"
          hide=0
        elif [[ "${name,,}" =~ $re_secret ]]; then
          if [ "$name" != "$arg" ]; then
            arg="$name=<redacted>"
          elif [[ "$arg" == -* ]]; then
            # --password secret: the value is the next argument.
            hide=1
          fi
        fi
        printf '  %s\n' "$arg"
      done <"$proc/cmdline"
    fi
    if [ -r "$proc/status" ]; then
      printf '\nFrom /proc/%s/status:\n' "$pid"
      while IFS= read -r line; do
        case "$line" in
          VmPeak:* | VmSize:* | VmHWM:* | VmRSS:* | VmSwap:* | Threads:*) printf '  %s\n' "$line" ;;
        esac
      done <"$proc/status"
    fi
    if [ -r "$proc/limits" ]; then
      printf '\nLimits:\n'
      while IFS= read -r line; do
        printf '  %s\n' "${line//[[:cntrl:]]/ }"
      done <"$proc/limits"
    fi
  } >"$dir/jvm.txt"
  if [ -r "$proc/status" ]; then
    while read -r key value _unit; do
      case "$key" in
        VmRSS:) rss="$value" ;;
        Threads:) threads="$value" ;;
      esac
    done <"$proc/status"
  fi
  XINIT_REPORT[JVM]="JVM: PID $pid"
  [ -z "$age" ] || XINIT_REPORT[JVM]+=", running for $(xinit_duration_text "$age")"
  [[ ! "$threads" =~ ^[0-9]+$ ]] || XINIT_REPORT[JVM]+=", $threads threads"
  [[ ! "$rss" =~ ^[0-9]+$ ]] || XINIT_REPORT[JVM]+=", $((rss / 1024)) MB in memory"
  _xinit_report_section jvm ok
}

# _xinit_report_journal <directory>: the end of the log of XWiki.
_xinit_report_journal() {
  local dir="$1" source="${XINIT_LAYOUT[LOG_SOURCE]-}"
  if [[ "$source" != journal:* ]]; then
    _xinit_report_section journal "skipped: the log is only read from the systemd journal"
    return 0
  fi
  if ! _xinit_journal -u "${source#journal:}" -o short-iso -n "${XINIT_REPORT[LINES]}"; then
    _xinit_report_section journal "skipped: the journal cannot be read: $XINIT_JOURNAL_ERROR"
    return 0
  fi
  printf '%s\n' "$XINIT_JOURNAL_OUTPUT" >"$dir/journal.txt"
  _xinit_report_section journal ok
}

# _xinit_report_url_port <URL>: print the port of a URL: the one it names, else the one of its
# scheme. Returns 1 when it has none.
_xinit_report_url_port() {
  local re='^(https?)://(\[[^]]*\]|[^/:?#]*)(:([0-9]+))?'
  [[ "$1" =~ $re ]] || return 1
  if [ -n "${BASH_REMATCH[4]}" ]; then
    printf '%s\n' "${BASH_REMATCH[4]}"
  elif [ "${BASH_REMATCH[1]}" = https ]; then
    echo 443
  else
    echo 80
  fi
}

# _xinit_report_sockets <directory>: the TCP sockets, counted by port and state. Sets
# XINIT_REPORT[SOCKETS], lines for the summary.
_xinit_report_sockets() {
  local dir="$1" raw counted http_port db_port="${XINIT_LAYOUT[DB_PORT]-}" line
  XINIT_REPORT[SOCKETS]=""
  if ! command -v ss >/dev/null 2>&1; then
    _xinit_report_section sockets "skipped: ss (iproute2) is not installed"
    return 0
  fi
  if ! raw="$(ss -H -t -a -n 2>/dev/null)"; then
    _xinit_report_section sockets "skipped: ss failed"
    return 0
  fi
  [[ "$db_port" =~ ^[0-9]+$ ]] || db_port=""
  http_port="$(_xinit_report_url_port "${XINIT_LAYOUT[BASE_URL]-}")" || http_port=""
  # State Recv-Q Send-Q Local:Port Peer:Port. For a listening socket, the queues are the
  # connections that wait to be accepted, and how many may wait.
  counted="$(printf '%s\n' "$raw" | awk -v db="$db_port" '
    NF >= 5 {
      count = split($4, parts, ":"); here = parts[count]
      count = split($5, parts, ":"); there = parts[count]
      if ($1 == "LISTEN") { listening[here] = $2 " waiting to be accepted, of " $3 " at most"; next }
      incoming[here, $1]++
      outgoing[there, $1]++
      states[$1] = 1
    }
    END {
      for (port in listening) {
        line = "port " port ": " listening[port]
        for (state in states) {
          if ((port, state) in incoming) line = line ", " state " " incoming[port, state]
        }
        print line
      }
      if (db != "") {
        line = ""
        for (state in states) {
          if ((db, state) in outgoing) line = line (line == "" ? "" : ", ") state " " outgoing[db, state]
        }
        print "to port " db " (the database): " (line == "" ? "no connection" : line)
      }
    }' | sort -t ' ' -k 1,1 -k 2,2n)" || counted=""
  {
    printf 'TCP sockets, counted by port and state:\n%s\n\n' "$counted"
    printf 'State Recv-Q Send-Q Local:Port Peer:Port\n%s\n' "$raw"
  } >"$dir/sockets.txt"
  while IFS= read -r line; do
    case "$line" in
      "port $http_port: "* | "to port "*) XINIT_REPORT[SOCKETS]+="  $line"$'\n' ;;
    esac
  done < <(printf '%s\n' "$counted")
  _xinit_report_section sockets ok
}

# _xinit_report_database <directory>: what the database is doing, and its size. The text of the
# queries is left out unless REPORT_DB_QUERIES is yes. Sets XINIT_REPORT[DATABASE], a line for
# the summary.
_xinit_report_database() {
  local dir="$1" type="${XINIT_LAYOUT[DB_TYPE]-}" host="${XINIT_LAYOUT[DB_HOST]-}"
  local port="${XINIT_LAYOUT[DB_PORT]-}" name="${XINIT_LAYOUT[DB_NAME]-}"
  local user="${XINIT_LAYOUT[DB_USER]-}" credentials timeout summary="" detail rc=0
  local connect=() query="" sql_summary sql_activity sql_size
  XINIT_REPORT[DATABASE]=""
  case "$type" in
    postgresql | mysql | mariadb) ;;
    *)
      _xinit_report_section database "skipped: no database to ask (${type:-not known})"
      return 0
      ;;
  esac
  credentials="$(_xinit_db_credentials)"
  if [ ! -r "$credentials" ]; then
    _xinit_report_section database "skipped: no credentials file $credentials"
    return 0
  fi
  if [ -z "$host" ] || [[ ! "$port" =~ ^[0-9]+$ ]] ||
    [[ ! "$name" =~ $XINIT_DB_RE_NAME || ! "$user" =~ $XINIT_DB_RE_NAME ]]; then
    _xinit_report_section database "skipped: the host, port, name or user of the database is not usable"
    return 0
  fi
  timeout="$(xinit_config_number DB_TIMEOUT)" || timeout=10
  connect=("$type" "$host" "$port" "$name" "$user" "$credentials" "$timeout")
  # A database that hangs must not keep the report waiting.
  XINIT_DB_CLIENT_LIMIT="$((timeout + 20))"
  if [ "$type" = postgresql ]; then
    [ "${XINIT_REPORT[QUERIES]}" != yes ] ||
      query=", left(regexp_replace(query, '[[:space:]]+', ' ', 'g'), 500) AS query"
    sql_summary="SELECT 'sessions: ' || count(*) || ', active: ' || count(*) FILTER (WHERE state = 'active') || ', idle in transaction: ' || count(*) FILTER (WHERE state LIKE 'idle in transaction%') || ', waiting for a lock: ' || count(*) FILTER (WHERE wait_event_type = 'Lock') || ', oldest transaction: ' || coalesce(date_trunc('second', max(now() - xact_start))::text, 'none') || ', size: ' || pg_size_pretty(pg_database_size(current_database())) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid()"
    sql_activity="SELECT pid, usename AS \"user\", coalesce(state, '') AS state, coalesce(wait_event_type || ':' || wait_event, '') AS waiting_for, coalesce(date_trunc('second', now() - xact_start)::text, '') AS transaction_age, coalesce(date_trunc('second', now() - state_change)::text, '') AS state_age$query FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid() ORDER BY xact_start NULLS LAST"
    sql_size="SELECT pg_size_pretty(pg_database_size(current_database())) AS database_size"
    summary="$(_xinit_db_client "${connect[@]}" value "$sql_summary")" || rc=$?
    [ "$rc" -ne 0 ] || detail="$(_xinit_db_client "${connect[@]}" table "$sql_activity" "$sql_size")" || rc=$?
  else
    sql_size="SELECT table_schema AS db, ROUND(SUM(data_length + index_length) / 1048576) AS size_mb FROM information_schema.tables WHERE table_schema NOT IN ('information_schema', 'performance_schema', 'mysql', 'sys') GROUP BY table_schema"
    detail="$(_xinit_db_client "${connect[@]}" table 'SHOW FULL PROCESSLIST')" || rc=$?
    if [ "$rc" -eq 0 ]; then
      # Without the session that asks. The text of the queries is the Info column.
      summary="$(printf '%s\n' "$detail" | awk -F '\t' '
        NR == 1 { for (i = 1; i <= NF; i++) column[$i] = i; next }
        $(column["Info"]) ~ /^SHOW FULL PROCESSLIST/ { next }
        {
          sessions++
          if ($(column["Command"]) == "Query") {
            running++
            if ($(column["Time"]) + 0 > longest) longest = $(column["Time"]) + 0
          }
        }
        END { printf "sessions: %d, running a query: %d, longest for: %d s\n", sessions, running, longest }')"
      [ "${XINIT_REPORT[QUERIES]}" = yes ] || detail="$(printf '%s\n' "$detail" | awk -F '\t' '
        BEGIN { OFS = "\t" }
        NR == 1 { for (i = 1; i <= NF; i++) if ($i == "Info") info = i }
        { if (info) $info = (NR == 1 ? "Info" : "-"); print }')"
      detail+=$'\n\n'"$(_xinit_db_client "${connect[@]}" table "$sql_size")" || rc=$?
    fi
  fi
  XINIT_DB_CLIENT_LIMIT=""
  if [ "$rc" -eq 127 ]; then
    _xinit_report_section database "skipped: no client for $type is installed"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    summary="${summary:-$detail}"
    summary="${summary%%$'\n'*}"
    _xinit_report_section database "skipped: the database did not answer: $(xinit_state_text "$summary" 200)"
    return 0
  fi
  summary="$(xinit_state_text "$summary" 300)"
  printf '%s\n\n%s\n' "$summary" "$detail" >"$dir/database.txt"
  XINIT_REPORT[DATABASE]="Database ($type): $summary"
  _xinit_report_section database ok
}

# _xinit_report_disk <directory>: the space and the inodes of the file systems.
_xinit_report_disk() {
  local dir="$1"
  if ! { df -P -k && echo && df -P -i; } >"$dir/disk.txt" 2>/dev/null; then
    rm -f -- "$dir/disk.txt"
    _xinit_report_section disk "skipped: df failed"
    return 0
  fi
  _xinit_report_section disk ok
}

# _xinit_report_dns <directory>: when a check failed because a host name does not resolve, what
# the resolver of this host says.
_xinit_report_dns() {
  local dir="$1" i host hosts=() seen=0 file line
  local re_host='^[A-Za-z0-9][A-Za-z0-9._-]*$' re_url='^[a-z]+://([^/:?#@]+)'
  for i in "${!XINIT_RESULT_CHECK[@]}"; do
    [ "${XINIT_RESULT_REASON[$i]}" = dns ] || continue
    seen=1
    case "${XINIT_RESULT_CHECK[$i]}" in
      db) host="${XINIT_LAYOUT[DB_HOST]-}" ;;
      *)
        host=""
        [[ "${XINIT_LAYOUT[BASE_URL]-}" =~ $re_url ]] && host="${BASH_REMATCH[1]}"
        ;;
    esac
    [[ "$host" =~ $re_host ]] && [[ " ${hosts[*]} " != *" $host "* ]] && hosts+=("$host")
  done
  [ "$seen" -eq 1 ] || return 0
  {
    for host in "${hosts[@]}"; do
      printf '$ getent ahosts %s\n' "$host"
      getent ahosts "$host" 2>&1 || printf '(no answer: status %s)\n' "$?"
      echo
    done
    for file in /etc/resolv.conf /etc/nsswitch.conf; do
      [ -r "${XINIT_ROOT:-}$file" ] || continue
      printf '%s:\n' "$file"
      while IFS= read -r line; do
        case "$file:$line" in
          /etc/nsswitch.conf:hosts:* | /etc/resolv.conf:[!#]*) printf '  %s\n' "${line//[[:cntrl:]]/ }" ;;
        esac
      done <"${XINIT_ROOT:-}$file"
    done
  } >"$dir/dns.txt"
  XINIT_REPORT[DNS]="$(head -n 40 -- "$dir/dns.txt")"
  _xinit_report_section dns ok
}

# _xinit_report_threads <directory>: thread dumps of the JVM, some seconds apart, and what they
# say. Sets XINIT_REPORT[DUMPS], [DEADLOCK] and [THREADS], the text for the summary.
_xinit_report_threads() {
  local dir="$1" files=() file
  XINIT_REPORT[DUMPS]=0
  XINIT_REPORT[DEADLOCK]=false
  XINIT_REPORT[THREADS]=""
  if ! xinit_thread_dumps "$XINIT_REPORT_DUMPS" "${XINIT_REPORT[INTERVAL]}"; then
    _xinit_report_section threads "skipped: $XINIT_ACT_ERROR"
    return 0
  fi
  mkdir -- "$dir/threads" || return 1
  # One file per dump. A dump starts with the line of its time, when there is one, and holds
  # what the JVM wrote up to the next dump.
  printf '%s\n' "$XINIT_THREAD_DUMPS_TEXT" | (cd "$dir/threads" && awk '
    /^Full thread dump / {
      if (dumps > 0) close(file)
      dumps++
      previous = file
      file = "dump-" dumps ".txt"
      if (dumps > 9) { held = ""; have = 0; next }
      if (have && held ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9:]+$/) print held >file
      else if (have && dumps > 1) print held >previous
      have = 0
      print >file
      next
    }
    dumps > 9 { next }
    {
      if (have && dumps > 0) print held >file
      held = $0
      have = 1
    }
    END { if (have && dumps > 0 && dumps <= 9) print held >file }') || return 1
  for file in "$dir"/threads/dump-*.txt; do
    [ -f "$file" ] && files+=("$file")
  done
  if [ "${#files[@]}" -eq 0 ]; then
    _xinit_report_section threads "skipped: the JVM wrote no thread dump"
    return 0
  fi
  XINIT_REPORT[DUMPS]="${#files[@]}"
  XINIT_REPORT[THREADS]="$(awk -f "$XINIT_LIB_DIR/threads.awk" "${files[@]}" 2>/dev/null)" ||
    XINIT_REPORT[THREADS]="Thread dumps: ${#files[@]} (they could not be read for a summary)"
  case $'\n'"${XINIT_REPORT[THREADS]}" in
    *$'\n'"Deadlock, in dump "*) XINIT_REPORT[DEADLOCK]=true ;;
  esac
  _xinit_report_section threads ok
}

# _xinit_report_summary <time>: print the summary of the report: what goes in a mail.
_xinit_report_summary() {
  local now="$1" section skipped=""
  printf 'XWiki diagnostics report, by xinit %s\n' "$XINIT_VERSION"
  printf 'Instance: %s\n' "$XINIT_INSTANCE"
  printf 'Host: %s\n' "${HOSTNAME:-unknown}"
  printf 'Time: %s\n' "$(_xinit_report_time "$now" '%Y-%m-%d %H:%M:%S UTC')"
  [ -z "${XINIT_REPORT[CAUSE]-}" ] || printf 'Cause: %s\n' "${XINIT_REPORT[CAUSE]}"
  printf '\nChecks:\n'
  xinit_results_print text
  printf '\n%s\n' "${XINIT_REPORT[JVM]}"
  [ -z "${XINIT_REPORT[SYSTEM]}" ] || printf '%s\n' "${XINIT_REPORT[SYSTEM]}"
  [ -z "${XINIT_REPORT[DATABASE]}" ] || printf '%s\n' "${XINIT_REPORT[DATABASE]}"
  [ -z "${XINIT_REPORT[SOCKETS]}" ] || printf 'TCP sockets:\n%s' "${XINIT_REPORT[SOCKETS]}"
  [ -z "${XINIT_REPORT[DNS]-}" ] || printf '\nName resolution:\n%s\n' "${XINIT_REPORT[DNS]}"
  [ -z "${XINIT_REPORT[THREADS]}" ] || printf '\n%s\n' "${XINIT_REPORT[THREADS]}"
  for section in "${XINIT_REPORT_SECTIONS[@]}"; do
    case "$section" in
      *$'\t'skipped:*) skipped+="  ${section%%$'\t'*}: ${section#*$'\t'skipped: }"$'\n' ;;
    esac
  done
  [ -z "$skipped" ] || printf '\nNot in this report:\n%s' "$skipped"
}

# _xinit_report_store <archive, or - for the standard input>: put an archive with the reports of
# this instance, and remove the oldest ones. Sets XINIT_REPORT[FILE]. Returns 1 when that fails,
# with XINIT_REPORT[ERROR].
_xinit_report_store() {
  local archive="$1" state dir tmp file old files=()
  state="$(xinit_state_dir)"
  dir="$state/reports"
  if ! xinit_dir_ensure "$state" || ! xinit_dir_ensure "$dir" ||
    ! tmp="$(mktemp -- "$dir/.report.XXXXXX" 2>/dev/null)"; then
    XINIT_REPORT[ERROR]="cannot write in $dir"
    return 1
  fi
  file="$dir/report-$(_xinit_report_time "$(xinit_now)" '%Y%m%dT%H%M%SZ').tar.gz"
  # The standard input is read as it is: opening it again by a name, /dev/stdin, needs a right
  # on the file behind it, which the owner of the state does not have on a file of root.
  if ! { if [ "$archive" = - ]; then cat; else cat -- "$archive"; fi; } >"$tmp" ||
    ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    XINIT_REPORT[ERROR]="cannot write $file"
    return 1
  fi
  XINIT_REPORT[FILE]="$file"
  # Keep the last ones: their names sort by time.
  for old in "$dir"/report-*.tar.gz; do
    [ -f "$old" ] && files+=("$old")
  done
  while [ "${#files[@]}" -gt "${XINIT_REPORT[KEEP]}" ]; do
    rm -f -- "${files[0]}"
    files=("${files[@]:1}")
  done
  return 0
}

# _xinit_report_build <output file, or nothing>: see xinit_report_build.
_xinit_report_build() {
  local output="$1" now work name dir archive stored i
  now="$(xinit_now)"
  XINIT_REPORT[FILE]=""
  XINIT_REPORT[ARCHIVE]=""
  XINIT_REPORT[NAME]=""
  XINIT_REPORT[DNS]=""
  XINIT_REPORT[OOM]=false
  XINIT_REPORT_SUMMARY=""
  XINIT_REPORT_SECTIONS=()
  if ! work="$(mktemp -d -- "${TMPDIR:-/tmp}/xinit-report.XXXXXX" 2>/dev/null)"; then
    XINIT_REPORT[ERROR]="cannot create a temporary directory in ${TMPDIR:-/tmp}"
    return 1
  fi
  XINIT_REPORT[WORK]="$work"
  xinit_on_exit _xinit_report_cleanup
  name="xinit-report-$XINIT_INSTANCE-$(_xinit_report_time "$now" '%Y%m%dT%H%M%SZ')"
  dir="$work/$name"
  archive="$work/report.tar.gz"
  XINIT_REPORT[ERROR]="cannot write in $work"
  mkdir -- "$dir" || return 1
  for i in "${!XINIT_RESULT_CHECK[@]}"; do
    [ "${XINIT_RESULT_CHECK[$i]}" = oom ] || continue
    case "${XINIT_RESULT_STATUS[$i]}" in warn | crit) XINIT_REPORT[OOM]=true ;; esac
  done
  # What is quick first, as close as can be to the time of the checks. The log before the
  # thread dumps, which would fill it.
  _xinit_report_basics "$dir" || return 1
  _xinit_report_system "$dir" || return 1
  _xinit_report_jvm "$dir" || return 1
  _xinit_report_sockets "$dir" || return 1
  _xinit_report_database "$dir" || return 1
  _xinit_report_disk "$dir" || return 1
  _xinit_report_dns "$dir" || return 1
  _xinit_report_journal "$dir" || return 1
  _xinit_report_threads "$dir" || return 1
  # A line of a mail holds 998 characters at most.
  # Much of it comes from the log, where a remote user can have a line written: no control
  # character reaches a terminal or a mail.
  XINIT_REPORT_SUMMARY="$(_xinit_report_summary "$now" |
    LC_ALL=C tr '\000-\011\013-\037\177' '[ *]' | LC_ALL=C cut -c 1-900)" || return 1
  printf '%s\n' "$XINIT_REPORT_SUMMARY" >"$dir/summary.txt" || return 1
  _xinit_report_scrub "$dir" || return 1
  XINIT_REPORT_SUMMARY="$(cat -- "$dir/summary.txt")" || return 1
  tar -czf "$archive" -C "$work" -- "$name" 2>/dev/null || return 1
  XINIT_REPORT[ERROR]=""
  XINIT_REPORT[ARCHIVE]="$archive"
  XINIT_REPORT[NAME]="$name"
  if [ -n "$output" ]; then
    # Never over a file that exists, nor through a link.
    if ! (set -o noclobber && cat -- "$archive" >"$output") 2>/dev/null; then
      XINIT_REPORT[ERROR]="cannot create $output: it must not exist, in a directory that does"
      return 1
    fi
    XINIT_REPORT[FILE]="$output"
  elif xinit_state_owner; then
    # Root writes nothing in the directory of another user: the owner stores what root built.
    if ! stored="$(xinit_state_run_as_owner "$archive" "${XINIT_ARGV[@]}" --store)" || [ -z "$stored" ]; then
      XINIT_REPORT[ERROR]="the owner of ${XINIT_CFG[STATE_DIR]} could not store the report"
      return 1
    fi
    XINIT_REPORT[FILE]="$(xinit_state_text "${stored%%$'\n'*}" 300)"
  else
    _xinit_report_store "$archive" || return 1
  fi
  return 0
}

# xinit_report_build [output file]: build a report from the layout and the results of the
# checks that ran, and store it with the reports of this instance, or in the output file. Sets
# XINIT_REPORT[FILE], [DUMPS], [OOM], [DEADLOCK], XINIT_REPORT_SUMMARY and XINIT_REPORT_SECTIONS.
# Call xinit_report_config first. Returns 1 when there is no report, with XINIT_REPORT[ERROR].
xinit_report_build() {
  local old_umask rc=0
  old_umask="$(umask)"
  # For its owner only, from the first file on.
  umask 077
  _xinit_report_build "${1:-}" || rc=$?
  umask "$old_umask"
  # Kept for the one who asked, when there is something to keep.
  if [ "$rc" -ne 0 ] || [ "${XINIT_REPORT[HOLD]-}" != true ]; then
    xinit_report_release
  fi
  [ "$rc" -eq 0 ] || [ -n "${XINIT_REPORT[ERROR]}" ] || XINIT_REPORT[ERROR]="the report could not be written"
  return "$rc"
}

# xinit_report_release: remove what xinit_report_build kept with HOLD=true.
xinit_report_release() {
  _xinit_report_cleanup
  XINIT_REPORT[ARCHIVE]=""
  XINIT_REPORT[HOLD]=""
}

# _xinit_report_json [what became of the mail]: print the result of `xinit report` as JSON.
_xinit_report_json() {
  local section sep=""
  local mail=null
  [ -z "${1:-}" ] || mail="\"$1\""
  printf '{"instance":%s,"report":%s,"status":"%s","oom":%s,"deadlock":%s,"thread_dumps":%s,"mail":%s,"sections":{' \
    "$(xinit_json_string "$XINIT_INSTANCE")" "$(xinit_json_string "${XINIT_REPORT[FILE]}")" \
    "$(xinit_results_status)" "${XINIT_REPORT[OOM]}" "${XINIT_REPORT[DEADLOCK]:-false}" \
    "${XINIT_REPORT[DUMPS]:-0}" "$mail"
  for section in "${XINIT_REPORT_SECTIONS[@]}"; do
    printf '%s"%s":%s' "$sep" "${section%%$'\t'*}" "$(xinit_json_string "${section#*$'\t'}")"
    sep=","
  done
  printf '}}\n'
}

# xinit_cmd_report [--output FILE] [--send] [--format text|json]: the `xinit report` command.
# With --send, the report is mailed to MAIL. With --store, which xinit uses itself: store the
# archive read from the standard input.
xinit_cmd_report() {
  local format=text output="" store=false send=false name names=() mail="" rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --output)
        [ $# -ge 2 ] && [ -n "$2" ] || xinit_die "--output needs a file" "$XINIT_EXIT_USAGE"
        output="$2"
        shift 2
        ;;
      --output=*) output="${1#--output=}" && shift ;;
      --format)
        [ $# -ge 2 ] || xinit_die "--format needs a value" "$XINIT_EXIT_USAGE"
        format="$2"
        shift 2
        ;;
      --format=*) format="${1#--format=}" && shift ;;
      --store) store=true && shift ;;
      --send) send=true && shift ;;
      *) xinit_die "report: unexpected argument $1" "$XINIT_EXIT_USAGE" ;;
    esac
  done
  case "$format" in
    text | json) ;;
    *) xinit_die "report: unknown format $format (text, json)" "$XINIT_EXIT_USAGE" ;;
  esac
  xinit_report_config || xinit_die "${XINIT_REPORT[ERROR]}"
  if [ "$send" = true ]; then
    [ "$store" = false ] || xinit_die "report: --send does not go with --store" "$XINIT_EXIT_USAGE"
    xinit_notify_config || xinit_die "${XINIT_NOTIFY[ERROR]}"
    [ "${#XINIT_NOTIFY_RCPT[@]}" -gt 0 ] ||
      xinit_die "report: --send needs MAIL, the addresses to send to (for one run: -o MAIL=...)"
  fi
  if [ "$store" = true ]; then
    xinit_state_is_mine || xinit_die "report: the state in ${XINIT_CFG[STATE_DIR]} belongs to another user"
    umask 077
    _xinit_report_store - || xinit_die "report: ${XINIT_REPORT[ERROR]}"
    printf '%s\n' "${XINIT_REPORT[FILE]}"
    return 0
  fi
  for name in ${XINIT_CFG[CHECKS]//,/ }; do
    names+=("$name")
  done
  xinit_checks_known "${names[@]}" ||
    xinit_die "CHECKS: unknown check $XINIT_CHECK_UNKNOWN (the checks are: ${XINIT_CHECK_NAMES[*]})"
  if ! xinit_checks_run "${names[@]}"; then
    xinit_results_print "$format"
    xinit_layout_explain_missing
    return "$XINIT_EXIT_UNKNOWN"
  fi
  XINIT_REPORT[CAUSE]=""
  XINIT_REPORT[HOLD]="$send"
  xinit_report_build "$output" || xinit_die "report: ${XINIT_REPORT[ERROR]}"
  if [ "$send" = true ]; then
    # Root mails what it built: it opens nothing in the directory of another user.
    xinit_notify_reset
    XINIT_NOTIFY[TITLE]="report"
    XINIT_NOTIFY[STATUS]="$(xinit_results_status)"
    XINIT_NOTIFY[BODY]="$XINIT_REPORT_SUMMARY"
    XINIT_NOTIFY[REPORT]="${XINIT_REPORT[FILE]}"
    XINIT_NOTIFY[ATTACH]="${XINIT_REPORT[ARCHIVE]}"
    XINIT_NOTIFY[ATTACH_NAME]="${XINIT_REPORT[NAME]}.tar.gz"
    # Someone asked for it: it is sent whatever was sent before.
    XINIT_NOTIFY[UNLIMITED]=true
    ! xinit_notify_oom || XINIT_NOTIFY[OOM]=true
    xinit_notify report "Report asked by $(xinit_state_text "$(xinit_invoker)" 64)." || rc="$XINIT_EXIT_UNKNOWN"
    mail="${XINIT_NOTIFY[MAIL]}"
    xinit_report_release
  fi
  if [ "$format" = json ]; then
    _xinit_report_json "$mail"
  else
    printf '%s\n\nreport: %s\n' "$XINIT_REPORT_SUMMARY" "${XINIT_REPORT[FILE]}"
    case "$mail" in
      sent) printf 'mail: sent to %s\n' "${XINIT_NOTIFY_RCPT[*]}" ;;
      failed) xinit_log error "the mail was not sent: ${XINIT_NOTIFY[ERROR]}" ;;
    esac
  fi
  return "$rc"
}
