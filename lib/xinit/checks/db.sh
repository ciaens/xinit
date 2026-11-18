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
# Check db: the database XWiki uses is reachable. Sourced, never executed.
#
# The check first opens a connection to the database's port. If a credentials file and the
# database's client exist, it then logs in and runs a query. xinit never reads the password of
# hibernate.cfg.xml for this, and never puts a password on a command line.

# Seconds to wait for the database.
xinit_config_define DB_TIMEOUT 10
# The file with the password. By default, in $XINIT_CONF_DIR/credentials/: <instance>.pgpass for
# PostgreSQL (the format of ~/.pgpass), <instance>.my.cnf for MySQL and MariaDB (a [client]
# section with password=).
xinit_config_define DB_CREDENTIALS

# _xinit_tcp_probe <host> <port> <timeout>: open and close a connection. Returns 0 when the port
# accepts it; else 1 with the reason in XINIT_TCP_ERROR: refused, timeout, dns or the message.
_xinit_tcp_probe() {
  local host="$1" port="$2" timeout="$3" error rc=0
  # An IPv6 address is written [::1] in a JDBC URL.
  host="${host#[}"
  host="${host%]}"
  XINIT_TCP_ERROR=""
  # shellcheck disable=SC2016  # $1 and $2 are for the inner shell
  error="$(timeout "$timeout" bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$port" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  error="${error%%$'\n'*}"
  case "$rc:$error" in
    124:*) XINIT_TCP_ERROR=timeout ;;
    *"Connection refused"*) XINIT_TCP_ERROR=refused ;;
    *"Name or service not known"* | *"name resolution"* | *"No address associated"*)
      XINIT_TCP_ERROR=dns ;;
    *) XINIT_TCP_ERROR="${error##*: }" ;;
  esac
  return 1
}

# _xinit_db_query <type> <host> <port> <name> <user> <credentials file> <timeout>: log in and run
# SELECT 1. Returns 0 when it answers 1; else 1 with the client's message in XINIT_DB_ERROR.
# Returns 2 when there is no client for this type of database.
_xinit_db_query() {
  local type="$1" host="$2" port="$3" name="$4" user="$5" credentials="$6" timeout="$7"
  local client output rc=0
  XINIT_DB_ERROR=""
  host="${host#[}"
  host="${host%]}"
  case "$type" in
    postgresql)
      command -v psql >/dev/null 2>&1 || return 2
      output="$(PGPASSFILE="$credentials" PGCONNECT_TIMEOUT="$timeout" \
        psql -X -w -At -h "$host" -p "$port" -U "$user" -d "$name" -c 'SELECT 1' 2>&1)" || rc=$?
      ;;
    mysql | mariadb)
      client="$(command -v mariadb || command -v mysql)" || return 2
      # --defaults-file has to be the first option. With it, no other option file is read: a
      # password in the user's own ~/.my.cnf does not replace this one.
      output="$("$client" --defaults-file="$credentials" --protocol=tcp -h "$host" \
        -P "$port" -u "$user" --connect-timeout="$timeout" -N -B -e 'SELECT 1' "$name" 2>&1)" ||
        rc=$?
      ;;
    *) return 2 ;;
  esac
  if [ "$rc" -eq 0 ] && [ "$output" = 1 ]; then
    return 0
  fi
  XINIT_DB_ERROR="${output%%$'\n'*}"
  return 1
}

xinit_check_db() {
  local type="${XINIT_LAYOUT[DB_TYPE]-}" host="${XINIT_LAYOUT[DB_HOST]-}"
  local port="${XINIT_LAYOUT[DB_PORT]-}" name="${XINIT_LAYOUT[DB_NAME]-}"
  local user="${XINIT_LAYOUT[DB_USER]-}" timeout
  local credentials="${XINIT_CFG[DB_CREDENTIALS]-}" where rc=0 suffix
  # What a database or user name is made of. Anything else is not passed to a client, where a
  # leading - or a = would change the meaning of the argument.
  local re_name='^[A-Za-z0-9_][A-Za-z0-9_.$-]*$'
  if ! timeout="$(xinit_config_number DB_TIMEOUT)"; then
    xinit_result db unknown bad-config "DB_TIMEOUT must be a number of seconds"
    return 0
  fi
  if [ -n "$port" ] && [[ ! "$port" =~ ^[0-9]+$ ]]; then
    xinit_result db unknown bad-config "DB_PORT must be a number"
    return 0
  fi
  if [ -z "$type" ]; then
    xinit_result db unknown no-db \
      "the database is not known: hibernate.cfg.xml cannot be read, and DB_TYPE is not set"
    return 0
  fi
  case "$type" in
    hsqldb | h2 | derby)
      xinit_result db ok embedded "the $type database is embedded in XWiki: nothing to reach"
      return 0
      ;;
  esac
  if [ -z "$host" ] || [ -z "$port" ]; then
    xinit_result db unknown no-db "the host and port of the $type database are not known: set DB_HOST and DB_PORT"
    return 0
  fi
  where="$type at $host:$port"
  if ! _xinit_tcp_probe "$host" "$port" "$timeout"; then
    case "$XINIT_TCP_ERROR" in
      refused) xinit_result db crit refused "$where refuses connections" ;;
      timeout) xinit_result db crit timeout "$where does not answer within ${timeout}s" ;;
      dns) xinit_result db unknown dns "the host name of $where does not resolve" ;;
      *) xinit_result db crit error "cannot connect to $where: $XINIT_TCP_ERROR" ;;
    esac
    return 0
  fi
  if [ -z "$credentials" ]; then
    case "$type" in
      postgresql) suffix=pgpass ;;
      *) suffix=my.cnf ;;
    esac
    credentials="${XINIT_CONF_DIR:-/etc/xinit}/credentials/$XINIT_INSTANCE.$suffix"
  fi
  if [ ! -r "$credentials" ]; then
    xinit_result db ok port-only \
      "$where accepts connections (the login is not checked: no credentials file $credentials)"
    return 0
  fi
  if [[ ! "$name" =~ $re_name || ! "$user" =~ $re_name ]]; then
    xinit_result db ok port-only \
      "$where accepts connections (the login is not checked: unusual database or user name)"
    return 0
  fi
  _xinit_db_query "$type" "$host" "$port" "$name" "$user" "$credentials" "$timeout" || rc=$?
  case "$rc" in
    0) xinit_result db ok ok "$where: login as $user and query on $name succeeded" ;;
    2)
      xinit_result db ok port-only \
        "$where accepts connections (the login is not checked: no client for $type is installed)"
      ;;
    *)
      # A database that stops between the test of its port and the login is down, not one that
      # refuses this user.
      case "$XINIT_DB_ERROR" in
        *"Connection refused"* | *"Can't connect to"*)
          xinit_result db crit refused "$where refuses connections: $XINIT_DB_ERROR"
          ;;
        *) xinit_result db crit login-failed "$where: login as $user or query on $name failed: $XINIT_DB_ERROR" ;;
      esac
      ;;
  esac
}
