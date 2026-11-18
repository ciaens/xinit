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
# Profile debian-xjetty: XWiki from the xwiki-xjetty-<db> Debian packages, with their own Jetty
# and the xwiki.service unit. Sourced, never executed.

xinit_profile_debian_xjetty_detect() {
  [ -n "$(xinit_dpkg_installed xwiki-xjetty-common)" ]
}

# xinit_xjetty_port <unit>: print the port Jetty listens on. The start script takes it from -p or
# --port, else from JETTY_PORT, else uses 8080.
xinit_xjetty_port() {
  local unit="$1" exec_start environment
  local re_option='[[:space:]](-p|--port)[[:space:]]+([0-9]+)([[:space:]]|$)'
  local re_env='(^|[[:space:]])JETTY_PORT=([0-9]+)([[:space:]]|$)'
  exec_start="$(xinit_systemctl_show "$unit" ExecStart)" || exec_start=""
  # ExecStart={ path=... ; argv[]=/bin/bash start_xwiki.sh -p 8081 ; ignore_errors=no ; ... }
  exec_start="${exec_start#*argv\[\]=}"
  exec_start="${exec_start%% ; *}"
  if [[ "$exec_start" =~ $re_option ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
    return 0
  fi
  environment="$(xinit_systemctl_show "$unit" Environment)" || environment=""
  if [[ "$environment" =~ $re_env ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
    return 0
  fi
  echo 8080
}

xinit_profile_debian_xjetty_fill() {
  local port
  xinit_layout_set UNIT xwiki.service detected
  xinit_layout_set WEBAPP_DIR /usr/lib/xwiki detected
  xinit_layout_set CONFIG_DIR /etc/xwiki detected
  port="$(xinit_xjetty_port "${XINIT_LAYOUT[UNIT]}")"
  [ "$port" = 80 ] && port="" || port=":$port"
  # The package always deploys XWiki at /xwiki; / redirects to it.
  xinit_layout_set BASE_URL "http://localhost$port/xwiki" detected
}
