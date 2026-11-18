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
# Profile debian-tomcat: XWiki from the xwiki-tomcat<N>-<db> Debian packages, in the
# distribution's Tomcat. Sourced, never executed.

# The Tomcat major version the installed package is for.
_XINIT_TOMCAT_N=""

xinit_profile_debian_tomcat_detect() {
  local package _version
  local re_package='^xwiki-tomcat([0-9]+)-common$'
  while IFS=$'\t' read -r package _version; do
    if [[ "$package" =~ $re_package ]]; then
      _XINIT_TOMCAT_N="${BASH_REMATCH[1]}"
      return 0
    fi
  done < <(xinit_dpkg_installed 'xwiki-tomcat*-common')
  return 1
}

# xinit_tomcat_context_path <context file>: print the context path Tomcat derives from the name
# of a context file: xwiki.xml gives /xwiki, ROOT.xml gives nothing, a#b.xml gives /a/b.
xinit_tomcat_context_path() {
  local name="${1##*/}"
  name="${name%.xml}"
  name="${name%%##*}"
  [ "$name" = ROOT ] && return 0
  printf '/%s\n' "${name//#//}"
}

# xinit_tomcat_http_endpoint <server.xml>: print the "host:port" to reach the first plain HTTP
# connector at. The host is localhost, unless the connector listens on one address only.
xinit_tomcat_http_endpoint() {
  local tag protocol port address
  while IFS= read -r tag; do
    protocol="$(xinit_xml_attr "$tag" protocol)" || protocol="HTTP/1.1"
    [[ "$protocol" == AJP* || "$protocol" == *.ajp.* ]] && continue
    [ "$(xinit_xml_attr "$tag" SSLEnabled)" = true ] && continue
    port="$(xinit_xml_attr "$tag" port)" || continue
    # A port can be a ${property}: then it is not known from this file.
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    address="$(xinit_xml_attr "$tag" address)" || address=""
    case "$address" in
      "" | 0.0.0.0 | :: | "[::]" | localhost | 127.0.0.1) address=localhost ;;
      *:*) [[ "$address" == "["* ]] || address="[$address]" ;;
    esac
    [[ "$address" =~ ^[][A-Za-z0-9:.-]+$ ]] || continue
    [ "$port" = 80 ] && port="" || port=":$port"
    printf '%s%s\n' "$address" "$port"
    return 0
  done < <(xinit_xml_elements "$1" Connector)
  return 1
}

# xinit_tomcat_base_url <tomcat config dir> <webapp dir>: print the local URL of the webapp, from
# the connector's port and the context file whose docBase is the webapp.
xinit_tomcat_base_url() {
  local conf="$1" webapp="$2" file tag doc_base host_port path="" found=1
  host_port="$(xinit_tomcat_http_endpoint "$conf/server.xml")" || return 1
  for file in "$conf"/Catalina/localhost/*.xml; do
    [ -e "$file" ] || continue
    tag="$(xinit_xml_elements "$file" Context | head -n 1)"
    doc_base="$(xinit_xml_attr "$tag" docBase)" || continue
    while [ "${#doc_base}" -gt 1 ] && [ "${doc_base: -1}" = "/" ]; do doc_base="${doc_base%/}"; done
    if [ "$doc_base" = "$webapp" ]; then
      path="$(xinit_tomcat_context_path "$file")"
      found=0
      break
    fi
  done
  [ "$found" -eq 0 ] || return 1
  printf 'http://%s%s\n' "$host_port" "$path"
}

xinit_profile_debian_tomcat_fill() {
  local n="$_XINIT_TOMCAT_N" root="${XINIT_ROOT:-}"
  # PROFILE=debian-tomcat was configured, so detection did not run.
  if [ -z "$n" ]; then
    xinit_profile_debian_tomcat_detect || true
    n="$_XINIT_TOMCAT_N"
  fi
  xinit_layout_set WEBAPP_DIR /usr/lib/xwiki detected
  xinit_layout_set CONFIG_DIR /etc/xwiki detected
  [ -n "$n" ] || return 0
  xinit_layout_set UNIT "tomcat$n.service" detected
  xinit_layout_set BASE_URL \
    "$(xinit_tomcat_base_url "$root/etc/tomcat$n" "${XINIT_LAYOUT[WEBAPP_DIR]}")" detected || true
}
