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
# Profile war: an XWiki WAR deployed by hand in a servlet container. Nothing is detected: the
# admin declares UNIT, WEBAPP_DIR and BASE_URL. Sourced, never executed.

# Chosen when the admin declared where XWiki is, and no package was found.
xinit_profile_war_detect() {
  [ -n "${XINIT_LAYOUT[WEBAPP_DIR]-}" ] || [ -n "${XINIT_LAYOUT[UNIT]-}" ]
}

# Everything else comes from the files under WEBAPP_DIR, which every profile reads the same way.
xinit_profile_war_fill() {
  return 0
}
