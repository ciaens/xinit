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
# Readers for the files of an XWiki installation: XML configuration, Java properties, JDBC URLs.
# They only need bash, awk, grep and tr. Sourced, never executed.

# xinit_xml_strip_comments <file>: print the file without its <!-- comments -->, which may span
# lines. Lines are kept, so line numbers still match. As in XML, a comment ends at the first -->.
xinit_xml_strip_comments() {
  [ -f "$1" ] && [ -r "$1" ] || return 1
  awk '
    {
      line = $0; out = ""
      while (length(line) > 0) {
        if (in_comment) {
          i = index(line, "-->")
          if (i == 0) { line = "" } else { line = substr(line, i + 3); in_comment = 0 }
        } else {
          i = index(line, "<!--")
          if (i == 0) { out = out line; line = "" }
          else { out = out substr(line, 1, i - 1); line = substr(line, i + 4); in_comment = 1 }
        }
      }
      print out
    }' "$1"
}

# _xinit_xml_decode <text>: print it with the five predefined XML entities replaced.
_xinit_xml_decode() {
  # Quoted, because bash 5.2 otherwise reads & in a replacement as "the matched text".
  local text="$1" amp='&'
  text="${text//&lt;/<}"
  text="${text//&gt;/>}"
  text="${text//&quot;/\"}"
  text="${text//&apos;/\'}"
  text="${text//&amp;/"$amp"}"
  printf '%s\n' "$text"
}

# _xinit_regex_quote <text>: print it with the characters special in an ERE escaped.
_xinit_regex_quote() {
  printf '%s\n' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g'
}

# xinit_xml_elements <file> <tag>: print the start tag of every element <tag> that is not in a
# comment, one per line, attributes included.
xinit_xml_elements() {
  local file="$1" tag
  tag="$(_xinit_regex_quote "$2")"
  xinit_xml_strip_comments "$file" | tr '\n\r\t' '   ' |
    grep -oE "<${tag}([[:space:]/][^>]*)?>" || true
}

# xinit_xml_attr <start tag> <attribute>: print the value of an attribute of a start tag, as
# printed by xinit_xml_elements. Returns 1 when the tag does not have it.
xinit_xml_attr() {
  local tag="$1" name
  name="$(_xinit_regex_quote "$2")"
  local re_double="[[:space:]]${name}[[:space:]]*=[[:space:]]*\"([^\"]*)\""
  local re_single="[[:space:]]${name}[[:space:]]*=[[:space:]]*'([^']*)'"
  if [[ "$tag" =~ $re_double ]] || [[ "$tag" =~ $re_single ]]; then
    _xinit_xml_decode "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# xinit_xml_property <file> <name>: print the text of the first <property name="NAME"> element that
# is not in a comment, trimmed. Returns 1 when there is none.
xinit_xml_property() {
  local file="$1" name match value
  name="$(_xinit_regex_quote "$2")"
  match="$(xinit_xml_strip_comments "$file" | tr '\n\r\t' '   ' |
    grep -oE "<property[[:space:]]+name[[:space:]]*=[[:space:]]*[\"']${name}[\"'][[:space:]]*>[^<]*</property>" |
    head -n 1)" || true
  [ -n "$match" ] || return 1
  value="${match#*>}"
  value="${value%</property>}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  _xinit_xml_decode "$value"
}

# xinit_hibernate_get <hibernate.cfg.xml> <name>: print a Hibernate property, such as
# connection.url. The name is looked up with and without the "hibernate." prefix, as both are valid.
xinit_hibernate_get() {
  xinit_xml_property "$1" "hibernate.$2" || xinit_xml_property "$1" "$2"
}

# xinit_properties_get <file> <key>: print the value of a key of a Java properties file. As in
# Java, the last definition wins. Returns 1 when the key is not defined. Line continuations and
# backslash escapes are not interpreted.
xinit_properties_get() {
  local file="$1" want="$2" line value="" found=1
  local re_line='^([^=:[:space:]]+)[[:space:]]*[=:]?[[:space:]]*(.*)$'
  [ -f "$file" ] && [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      '' | '#'* | '!'*) continue ;;
    esac
    if [[ "$line" =~ $re_line ]] && [ "${BASH_REMATCH[1]}" = "$want" ]; then
      value="${BASH_REMATCH[2]}"
      value="${value%"${value##*[![:space:]]}"}"
      found=0
    fi
  done <"$file"
  [ "$found" -eq 0 ] || return 1
  printf '%s\n' "$value"
}

# xinit_extension_version <extension.xed>: print the version of the extension the file describes.
xinit_extension_version() {
  local line
  local re_version='<version>[[:space:]]*([^<[:space:]]+)[[:space:]]*</version>'
  [ -f "$1" ] && [ -r "$1" ] || return 1
  # The extension's own <version> comes first, before those of its dependencies.
  while IFS= read -r line; do
    if [[ "$line" =~ $re_version ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done <"$1"
  return 1
}

# xinit_jdbc_parse <url> <array name>: split a JDBC URL into the keys type, host, port and name of
# an associative array. A key is empty when the URL does not tell and the type has no default.
# type is postgresql, mysql, mariadb, oracle, hsqldb, h2, derby... (the JDBC subprotocol).
# Returns 1 when the text is not a JDBC URL.
xinit_jdbc_parse() {
  local url="$1" rest authority
  local -n _jdbc="$2"
  local re_url='^jdbc:([A-Za-z0-9]+):(.*)$'
  local re_hostport='^(\[[^]]*\]|[^:]*)(:([0-9]+))?$'
  _jdbc=([type]="" [host]="" [port]="" [name]="")
  [[ "$url" =~ $re_url ]] || return 1
  _jdbc[type]="${BASH_REMATCH[1],,}"
  rest="${BASH_REMATCH[2]}"
  case "${_jdbc[type]}" in
    postgresql | mysql | mariadb)
      rest="${rest%%\?*}"
      if [ "${rest:0:2}" = "//" ]; then
        rest="${rest:2}"
        # user:password@ in front of the host: the password may hold any character, / included.
        [[ "$rest" == *@* ]] && rest="${rest##*@}"
        authority="${rest%%/*}"
        _jdbc[name]=""
        [ "$rest" != "$authority" ] && _jdbc[name]="${rest#*/}"
        # Several hosts can be listed for failover: the first one is checked.
        authority="${authority%%,*}"
        if [[ "$authority" =~ $re_hostport ]]; then
          _jdbc[host]="${BASH_REMATCH[1]}"
          _jdbc[port]="${BASH_REMATCH[3]}"
        fi
      else
        _jdbc[name]="$rest"
      fi
      [ -n "${_jdbc[host]}" ] || _jdbc[host]=localhost
      if [ -z "${_jdbc[port]}" ]; then
        case "${_jdbc[type]}" in
          postgresql) _jdbc[port]=5432 ;;
          *) _jdbc[port]=3306 ;;
        esac
      fi
      ;;
    oracle)
      # jdbc:oracle:thin:@host:1521:SID  or  jdbc:oracle:thin:@//host:1521/service
      rest="${rest#*@}"
      rest="${rest#//}"
      local re_oracle='^([^:/]+)(:([0-9]+))?[:/](.*)$'
      if [[ "$rest" =~ $re_oracle ]]; then
        _jdbc[host]="${BASH_REMATCH[1]}"
        _jdbc[port]="${BASH_REMATCH[3]:-1521}"
        _jdbc[name]="${BASH_REMATCH[4]}"
      fi
      ;;
    *)
      # Embedded databases (hsqldb, h2, derby) and anything else: no server to reach.
      ;;
  esac
  return 0
}
