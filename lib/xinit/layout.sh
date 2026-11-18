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
# The layout: where things are for one XWiki installation. Sourced, never executed.
#
# Each key gets its value from the first of: the configuration, the profile (the kind of
# installation), what the installation's own files say, a default. XINIT_LAYOUT_SRC keeps which
# one it was: config, detected or default. A key that could not be determined is not set.
#
# Every file of the installation is read under $XINIT_ROOT (empty by default), so that xinit can
# inspect a file tree that is not mounted at /.

declare -gA XINIT_LAYOUT=() XINIT_LAYOUT_SRC=()
# The layout keys, in display order.
XINIT_LAYOUT_KEYS=(PROFILE UNIT WEBAPP_DIR CONFIG_DIR PERMDIR BASE_URL LOG_SOURCE
  DB_TYPE DB_HOST DB_PORT DB_NAME DB_USER VERSION JVM_PID)
# The keys without which nothing can be checked.
XINIT_LAYOUT_ESSENTIAL=(PROFILE UNIT WEBAPP_DIR CONFIG_DIR BASE_URL)
# The profiles, in detection order. "war" is not detected: the admin declares it.
XINIT_PROFILES=(debian-tomcat debian-xjetty war)

# The layout keys the configuration may set. VERSION and JVM_PID are always read from the system.
for _key in PROFILE UNIT WEBAPP_DIR CONFIG_DIR PERMDIR BASE_URL LOG_SOURCE \
  DB_TYPE DB_HOST DB_PORT DB_NAME DB_USER; do
  xinit_config_define "$_key"
done
unset _key
# A file holding the JVM's PID, for a unit whose main process is not the JVM.
xinit_config_define PID_FILE

# xinit_layout_set <KEY> <value> <source>: set a key, unless it is already set or the value is
# empty. The first one to set a key wins.
xinit_layout_set() {
  [ -n "$2" ] || return 0
  [ -z "${XINIT_LAYOUT[$1]+x}" ] || return 0
  XINIT_LAYOUT[$1]="$2"
  XINIT_LAYOUT_SRC[$1]="$3"
}

# xinit_systemctl_show <unit> <property>: print one property of a unit. Returns 1 without systemd.
xinit_systemctl_show() {
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl show -p "$2" --value -- "$1" 2>/dev/null
}

# xinit_dpkg_installed <glob>: print "package<tab>version" for each installed package matching.
xinit_dpkg_installed() {
  local package version status
  command -v dpkg-query >/dev/null 2>&1 || return 0
  # shellcheck disable=SC2016  # ${...} is dpkg-query's own format syntax
  dpkg-query -W -f '${Package}\t${Version}\t${db:Status-Abbrev}\n' "$1" 2>/dev/null |
    while IFS=$'\t' read -r package version status; do
      # shellcheck disable=SC2254  # the argument is a pattern
      case "$package" in
        $1) [ "${status:0:2}" = "ii" ] && printf '%s\t%s\n' "$package" "$version" ;;
      esac
    done || true
  return 0
}

# _xinit_layout_from_config: the configured values come first. An empty value is as not set.
_xinit_layout_from_config() {
  local key value
  # The characters of a unit name. It never starts with a -, which systemctl would take for an
  # option.
  local re_unit='^[A-Za-z0-9:_.\\@][A-Za-z0-9:_.\\@-]*$'
  for key in "${XINIT_LAYOUT_KEYS[@]}"; do
    value="${XINIT_CFG[$key]-}"
    case "$key" in
      UNIT)
        if [ -n "$value" ]; then
          [[ "$value" =~ $re_unit ]] || xinit_die "UNIT=$value is not the name of a systemd unit"
          [[ "$value" != *.* ]] && value="$value.service"
        fi
        ;;
      BASE_URL | WEBAPP_DIR | CONFIG_DIR | PERMDIR)
        while [ "${#value}" -gt 1 ] && [ "${value: -1}" = "/" ]; do value="${value%/}"; done ;;
    esac
    xinit_layout_set "$key" "$value" config
  done
}

# _xinit_layout_profile: choose the profile, unless the configuration names it.
_xinit_layout_profile() {
  local profile
  if [ -n "${XINIT_LAYOUT[PROFILE]-}" ]; then
    for profile in "${XINIT_PROFILES[@]}"; do
      [ "$profile" = "${XINIT_LAYOUT[PROFILE]}" ] && return 0
    done
    xinit_die "PROFILE=${XINIT_LAYOUT[PROFILE]} is not one of: ${XINIT_PROFILES[*]}"
  fi
  for profile in "${XINIT_PROFILES[@]}"; do
    if "xinit_profile_${profile//-/_}_detect"; then
      xinit_layout_set PROFILE "$profile" detected
      return 0
    fi
  done
  return 1
}

# _xinit_layout_common: what every profile reads the same way, from XWiki's own files.
_xinit_layout_common() {
  local root="${XINIT_ROOT:-}" webapp="${XINIT_LAYOUT[WEBAPP_DIR]-}" config url pid
  local -A db=()
  [ -n "$webapp" ] && xinit_layout_set CONFIG_DIR "$webapp/WEB-INF" default
  config="${XINIT_LAYOUT[CONFIG_DIR]-}"
  if [ -n "$config" ]; then
    xinit_layout_set PERMDIR \
      "$(xinit_properties_get "$root$config/xwiki.properties" environment.permanentDirectory)" \
      detected || true
    # hibernate.cfg.xml holds the database password: xinit may well not be allowed to read it.
    if url="$(xinit_hibernate_get "$root$config/hibernate.cfg.xml" connection.url)" &&
      xinit_jdbc_parse "$url" db; then
      xinit_layout_set DB_TYPE "${db[type]}" detected
      xinit_layout_set DB_HOST "${db[host]}" detected
      xinit_layout_set DB_PORT "${db[port]}" detected
      xinit_layout_set DB_NAME "${db[name]}" detected
      xinit_layout_set DB_USER \
        "$(xinit_hibernate_get "$root$config/hibernate.cfg.xml" connection.username)" \
        detected || true
    fi
  fi
  if [ -n "$webapp" ]; then
    xinit_layout_set VERSION \
      "$(xinit_extension_version "$root$webapp/META-INF/extension.xed")" detected || true
  fi
  [ -n "${XINIT_LAYOUT[UNIT]-}" ] &&
    xinit_layout_set LOG_SOURCE "journal:${XINIT_LAYOUT[UNIT]}" default
  if pid="$(xinit_jvm_pid)"; then
    XINIT_LAYOUT[JVM_PID]="$pid"
    XINIT_LAYOUT_SRC[JVM_PID]=detected
  fi
  return 0
}

# xinit_jvm_pid: print the PID of the JVM running XWiki. Returns 1 when there is none or when it
# cannot be told: the unit's main process, else the one in PID_FILE, if it is a java process.
xinit_jvm_pid() {
  local root="${XINIT_ROOT:-}" unit="${XINIT_LAYOUT[UNIT]-}" pid_file="${XINIT_CFG[PID_FILE]-}"
  local pid comm
  for pid in \
    "$([ -n "$unit" ] && xinit_systemctl_show "$unit" MainPID)" \
    "$([ -n "$pid_file" ] && [ -r "$root$pid_file" ] && head -n 1 "$root$pid_file")"; do
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
    comm=""
    [ -r "$root/proc/$pid/comm" ] && read -r comm <"$root/proc/$pid/comm"
    if [ "$comm" = java ]; then
      printf '%s\n' "$pid"
      return 0
    fi
  done
  return 1
}

# xinit_layout_resolve: fill XINIT_LAYOUT. Returns 1 when an essential key is missing; the names
# of the missing keys are then in XINIT_LAYOUT_MISSING.
xinit_layout_resolve() {
  local key
  XINIT_LAYOUT=()
  XINIT_LAYOUT_SRC=()
  XINIT_LAYOUT_MISSING=()
  _xinit_layout_from_config
  if _xinit_layout_profile; then
    "xinit_profile_${XINIT_LAYOUT[PROFILE]//-/_}_fill"
    _xinit_layout_common
  fi
  for key in "${XINIT_LAYOUT_ESSENTIAL[@]}"; do
    [ -n "${XINIT_LAYOUT[$key]+x}" ] || XINIT_LAYOUT_MISSING+=("$key")
  done
  [ "${#XINIT_LAYOUT_MISSING[@]}" -eq 0 ]
}

# xinit_layout_explain_missing: say on stderr what is missing and what to do about it.
xinit_layout_explain_missing() {
  local conf="${XINIT_CONF_DIR:-/etc/xinit}/xinit.conf"
  if [ -z "${XINIT_LAYOUT[PROFILE]+x}" ]; then
    xinit_log error "no XWiki installation was detected: for an XWiki that is not installed" \
      "from a Debian package, set UNIT, WEBAPP_DIR and BASE_URL in $conf"
  else
    xinit_log error "the ${XINIT_LAYOUT[PROFILE]} installation is incomplete:" \
      "set ${XINIT_LAYOUT_MISSING[*]} in $conf"
  fi
}

# xinit_layout_print <text|json>: print the layout.
xinit_layout_print() {
  local format="$1" key sep=""
  case "$format" in
    text)
      for key in "${XINIT_LAYOUT_KEYS[@]}"; do
        printf '%-11s %-9s %s\n' "$key" "${XINIT_LAYOUT_SRC[$key]-unknown}" \
          "${XINIT_LAYOUT[$key]--}"
      done
      ;;
    json)
      printf '{"instance":%s,"layout":{' "$(xinit_json_string "$XINIT_INSTANCE")"
      for key in "${XINIT_LAYOUT_KEYS[@]}"; do
        printf '%s"%s":{"value":' "$sep" "$key"
        if [ -n "${XINIT_LAYOUT[$key]+x}" ]; then
          xinit_json_string "${XINIT_LAYOUT[$key]}"
        else
          printf 'null'
        fi
        printf ',"source":"%s"}' "${XINIT_LAYOUT_SRC[$key]-unknown}"
        sep=","
      done
      printf '}}\n'
      ;;
  esac
}

# xinit_cmd_layout [--format text|json]: the `xinit layout` command.
xinit_cmd_layout() {
  local format=text
  while [ $# -gt 0 ]; do
    case "$1" in
      --format)
        [ $# -ge 2 ] || xinit_die "--format needs a value" "$XINIT_EXIT_USAGE"
        format="$2"
        shift 2
        ;;
      --format=*)
        format="${1#--format=}"
        shift
        ;;
      *) xinit_die "layout: unknown option $1" "$XINIT_EXIT_USAGE" ;;
    esac
  done
  case "$format" in
    text | json) ;;
    *) xinit_die "layout: unknown format $format (text, json)" "$XINIT_EXIT_USAGE" ;;
  esac
  if xinit_layout_resolve; then
    xinit_layout_print "$format"
    return "$XINIT_EXIT_OK"
  fi
  xinit_layout_print "$format"
  xinit_layout_explain_missing
  return "$XINIT_EXIT_UNKNOWN"
}
