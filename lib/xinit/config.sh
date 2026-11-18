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
# Configuration: KEY=value files, parsed and never sourced. Sourced, never executed.
#
# Layers, each one overriding the previous:
#   1. the defaults given to xinit_config_define;
#   2. $XINIT_CONF_DIR/xinit.conf            (global, and the "default" instance);
#   3. $XINIT_CONF_DIR/instances/<name>.conf (one instance);
#   4. XINIT_<KEY> environment variables;
#   5. -o KEY=value on the command line.
#
# File grammar: one KEY=value per line. Blank lines and lines starting with # are ignored. A value
# is bare (to the end of the line, trimmed), "double quoted" or 'single quoted'. It is always
# literal: no variable, command or backslash expansion, and no comment after a value.

# XINIT_CFG[KEY]      the value
# XINIT_CFG_SRC[KEY]  where it comes from: default, file:<path>, env or cli
# Both are unset for a key that has no default and that no layer sets.
declare -gA XINIT_CFG=() XINIT_CFG_SRC=() _XINIT_CFG_KNOWN=()
# The known keys in definition order, for a stable output.
declare -ga XINIT_CFG_KEYS=()
# The -o KEY=value arguments, in order.
declare -ga XINIT_CLI_OVERRIDES=()
# The instance xinit_instance_resolve chose.
XINIT_INSTANCE=""

# xinit_config_define <KEY> [default]: declare a configuration key. Each module declares its own
# keys when it is sourced, before the configuration is loaded.
xinit_config_define() {
  local key="$1"
  # XINIT_<these> are xinit's own environment variables, not configuration values.
  case "$key" in
    CONF_DIR | LIB_DIR | ROOT | INSTANCE | VERSION | TEST_*)
      xinit_die "internal error: $key is reserved and cannot be a configuration key" ;;
  esac
  if [ -z "${_XINIT_CFG_KNOWN[$key]+x}" ]; then
    _XINIT_CFG_KNOWN[$key]=1
    XINIT_CFG_KEYS+=("$key")
  fi
  if [ $# -ge 2 ]; then
    XINIT_CFG[$key]="$2"
    XINIT_CFG_SRC[$key]=default
  fi
}

# xinit_config_get <KEY>: print the value. Returns 1 when the key is not set.
xinit_config_get() {
  [ -n "${XINIT_CFG[$1]+x}" ] || return 1
  printf '%s\n' "${XINIT_CFG[$1]}"
}

# xinit_config_number <KEY> [decimal]: print the value of a key that has to be a whole number, or
# with "decimal" a number that may have a fraction. Leading zeros are dropped, so that the value
# is never read as octal. Returns 1 when the value is not such a number.
xinit_config_number() {
  local value="${XINIT_CFG[$1]-}" whole fraction=""
  local re_whole='^[0-9]+$' re_decimal='^[0-9]+(\.[0-9]+)?$'
  if [ "${2:-}" = decimal ]; then
    [[ "$value" =~ $re_decimal ]] || return 1
    [[ "$value" == *.* ]] && fraction=".${value#*.}"
    whole="${value%%.*}"
  else
    [[ "$value" =~ $re_whole ]] || return 1
    whole="$value"
  fi
  printf '%s%s\n' "$((10#$whole))" "$fraction"
}

# xinit_config_dump: one "KEY<tab>source<tab>value" line per key that is set.
xinit_config_dump() {
  local key
  for key in "${XINIT_CFG_KEYS[@]}"; do
    [ -n "${XINIT_CFG[$key]+x}" ] || continue
    printf '%s\t%s\t%s\n' "$key" "${XINIT_CFG_SRC[$key]}" "${XINIT_CFG[$key]}"
  done
}

# _xinit_config_parse_line <line>: returns 0 and sets _cfg_key, _cfg_value and _cfg_quote (none,
# double or single); returns 1 for a line to ignore; returns 2 and sets _cfg_err for a malformed
# line.
_xinit_config_parse_line() {
  local line="$1" rest
  local re_line='^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$'
  local re_double='^"([^"]*)"$' re_single="^'([^']*)'\$"
  line="${line%$'\r'}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  if [ -z "$line" ] || [ "${line:0:1}" = "#" ]; then
    return 1
  fi
  if [[ ! "$line" =~ $re_line ]]; then
    _cfg_err="expected KEY=value"
    return 2
  fi
  _cfg_key="${BASH_REMATCH[1]}"
  rest="${BASH_REMATCH[2]}"
  _cfg_quote=none
  case "$rest" in
    \"*)
      if [[ ! "$rest" =~ $re_double ]]; then
        _cfg_err="$_cfg_key: a value starting with \" must end with \" and contain no other \""
        return 2
      fi
      _cfg_value="${BASH_REMATCH[1]}"
      _cfg_quote=double
      ;;
    \'*)
      if [[ ! "$rest" =~ $re_single ]]; then
        _cfg_err="$_cfg_key: a value starting with ' must end with ' and contain no other '"
        return 2
      fi
      _cfg_value="${BASH_REMATCH[1]}"
      _cfg_quote=single
      ;;
    *) _cfg_value="$rest" ;;
  esac
  return 0
}

# xinit_config_load_file <file>: apply one configuration file. A malformed line is fatal. An
# unknown key gives a warning and is ignored.
xinit_config_load_file() {
  local file="$1" line n=0 rc
  local _cfg_key="" _cfg_value="" _cfg_quote="" _cfg_err=""
  local -A seen=()
  # A value from a file that was once sourced by a shell may count on an expansion.
  local re_expansion='\$[A-Za-z_({]|`'
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    xinit_die "cannot read the configuration file $file"
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    rc=0
    _xinit_config_parse_line "$line" || rc=$?
    if [ "$rc" -eq 1 ]; then
      continue
    elif [ "$rc" -eq 2 ]; then
      xinit_die "$file:$n: $_cfg_err"
    fi
    if [ -z "${_XINIT_CFG_KNOWN[$_cfg_key]+x}" ]; then
      xinit_log warning "$file:$n: unknown key $_cfg_key, ignored"
      continue
    fi
    if [ -n "${seen[$_cfg_key]+x}" ]; then
      xinit_log warning "$file:$n: $_cfg_key is set again, replacing line ${seen[$_cfg_key]}"
    fi
    seen[$_cfg_key]=$n
    if [ "$_cfg_quote" != single ] && [[ "$_cfg_value" =~ $re_expansion ]]; then
      xinit_log warning "$file:$n: $_cfg_key is taken literally, nothing in it is expanded"
    fi
    XINIT_CFG[$_cfg_key]="$_cfg_value"
    XINIT_CFG_SRC[$_cfg_key]="file:$file"
  done <"$file"
}

# xinit_instance_resolve [name]: set XINIT_INSTANCE. Without a name, it is the only instance in
# instances/, or "default" when there is none.
xinit_instance_resolve() {
  local requested="${1:-}" dir="${XINIT_CONF_DIR:-/etc/xinit}" f names=()
  local re_name='^[A-Za-z0-9][A-Za-z0-9_.-]*$'
  if [ -n "$requested" ]; then
    if [[ ! "$requested" =~ $re_name ]]; then
      xinit_die "invalid instance name: $requested" "$XINIT_EXIT_USAGE"
    fi
    if [ "$requested" != default ] && [ ! -e "$dir/instances/$requested.conf" ]; then
      xinit_die "unknown instance $requested: $dir/instances/$requested.conf does not exist" \
        "$XINIT_EXIT_USAGE"
    fi
    XINIT_INSTANCE="$requested"
    return 0
  fi
  for f in "$dir"/instances/*.conf; do
    [ -e "$f" ] || continue
    f="${f##*/}"
    names+=("${f%.conf}")
  done
  case "${#names[@]}" in
    0) XINIT_INSTANCE=default ;;
    1) XINIT_INSTANCE="${names[0]}" ;;
    *) xinit_die "several instances exist (${names[*]}): choose one with -i" "$XINIT_EXIT_USAGE" ;;
  esac
}

# xinit_config_load: apply every layer for $XINIT_INSTANCE, on top of the defaults.
xinit_config_load() {
  local dir="${XINIT_CONF_DIR:-/etc/xinit}" key ref override
  if [ -e "$dir/xinit.conf" ]; then
    xinit_config_load_file "$dir/xinit.conf"
  fi
  if [ -n "$XINIT_INSTANCE" ] && [ -e "$dir/instances/$XINIT_INSTANCE.conf" ]; then
    xinit_config_load_file "$dir/instances/$XINIT_INSTANCE.conf"
  fi
  # Only exported variables: a shell variable of xinit itself is not configuration.
  for key in "${XINIT_CFG_KEYS[@]}"; do
    ref="XINIT_$key"
    if [[ -v "$ref" && "${!ref@a}" == *x* ]]; then
      XINIT_CFG[$key]="${!ref}"
      XINIT_CFG_SRC[$key]="env"
    fi
  done
  for override in "${XINIT_CLI_OVERRIDES[@]}"; do
    key="${override%%=*}"
    if [ -z "${_XINIT_CFG_KNOWN[$key]+x}" ]; then
      xinit_die "-o $override: unknown key $key" "$XINIT_EXIT_USAGE"
    fi
    XINIT_CFG[$key]="${override#*=}"
    XINIT_CFG_SRC[$key]=cli
  done
}
