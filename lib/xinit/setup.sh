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
# `xinit check`: run the read-only checks on one instance. Sourced, never executed.
# `xinit setup`: install what makes xinit run by itself on a host with systemd. Sourced, never
# executed.
#
# For one instance, it writes:
#   - a sysusers.d file, for the user the periodic job runs as;
#   - a drop-in of the unit that runs XWiki: restart on failure, and a notification on a crash;
#   - xinit-watch@<instance>.service and .timer: the periodic job;
#   - xinit-act@<instance>.path and .service: how the periodic job, which is not root, gets
#     XWiki restarted or a thread dump taken;
#   - xinit-notify@<instance>.service: the notification of a crash;
#   - xinit-warmup@<instance>.service: the first requests after each start of XWiki, which the
#     drop-in starts;
#   - the credentials file of the db check, from XWiki's own configuration;
#   - a manifest of all this, which `xinit setup --undo` removes.

# JVM options to add to the unit that runs XWiki, as -Xmx2g or a Java agent.
xinit_config_define JVM_OPTS_APPEND ""

# The user the periodic job runs as.
XINIT_SERVICE_USER=xinit
# What _xinit_setup_groups and _xinit_setup_jvm_options found.
XINIT_SETUP_GROUPS=""
XINIT_SETUP_JVM=""

# The plan: the files to write, in order.
declare -ga XINIT_SETUP_PATH=() XINIT_SETUP_CONTENT=() XINIT_SETUP_MODE=() XINIT_SETUP_OWNER=()
declare -ga XINIT_SETUP_SECRET=() XINIT_SETUP_CHANGE=()
# The units to enable, the commands to run, and what the administrator has to know.
declare -ga XINIT_SETUP_ENABLE=() XINIT_SETUP_COMMANDS=() XINIT_SETUP_WARNINGS=()

# _xinit_setup_file <path> <mode> <owner, or empty for root> <secret: 0|1> <content>: add a file
# to the plan.
_xinit_setup_file() {
  XINIT_SETUP_PATH+=("$1")
  XINIT_SETUP_MODE+=("$2")
  XINIT_SETUP_OWNER+=("$3")
  XINIT_SETUP_SECRET+=("$4")
  XINIT_SETUP_CONTENT+=("$5")
}

# _xinit_setup_manifest: print the path of the manifest of this instance. It is kept with the
# configuration, which only root writes: --undo removes what it lists.
_xinit_setup_manifest() {
  printf '%s/setup/%s.manifest\n' "${XINIT_CONF_DIR:-/etc/xinit}" "$XINIT_INSTANCE"
}

# _xinit_setup_groups: set XINIT_SETUP_GROUPS to the groups the periodic job needs to read what
# root reads: the journal, and the files of the installation that are not readable by everyone.
# Not called as $(...): its warnings would be lost.
_xinit_setup_groups() {
  local root="${XINIT_ROOT:-}" file path info mode group other mine want
  local groups=" systemd-journal "
  local files=("$root${XINIT_LAYOUT[CONFIG_DIR]-}/hibernate.cfg.xml"
    "$root${XINIT_LAYOUT[CONFIG_DIR]-}/xwiki.properties"
    "$root${XINIT_LAYOUT[WEBAPP_DIR]-}/META-INF/extension.xed")
  local hook="xinit_profile_${XINIT_LAYOUT[PROFILE]//-/_}_files"
  if declare -F "$hook" >/dev/null; then
    while IFS= read -r file; do
      [ -n "$file" ] && files+=("$file")
    done < <("$hook")
  fi
  for file in "${files[@]}"; do
    [ -e "$file" ] || continue
    # The file, then each directory above it, up to the root of the installation.
    path="$file"
    while [ -n "$path" ] && [ "$path" != "$root" ] && [ "$path" != / ]; do
      info="$(stat -L -c '%A %G' -- "$path" 2>/dev/null)" || break
      mode="${info%% *}"
      group="${info#* }"
      # -rw-r--r-- or drwxr-xr-x: a file has to be read, a directory entered. The 8th or 10th
      # character says whether everyone may, the 5th or 7th whether its group may.
      if [ -d "$path" ]; then other="${mode:9:1}" && mine="${mode:6:1}" && want=x; else other="${mode:7:1}" && mine="${mode:4:1}" && want=r; fi
      if [ "$other" != "$want" ] && [ "$other" != t ]; then
        case "$group" in
          root | shadow | disk | sudo | wheel | adm | staff | kmem | docker | lxd) mine="" ;;
        esac
        if [ "$mine" = "$want" ] && [[ "$group" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]]; then
          [[ "$groups" == *" $group "* ]] || groups+="$group "
        else
          XINIT_SETUP_WARNINGS+=("the user $XINIT_SERVICE_USER cannot read ${file#"$root"}: set in the configuration what xinit reads from it")
          break
        fi
      fi
      path="${path%/*}"
    done
  done
  groups="${groups# }"
  XINIT_SETUP_GROUPS="${groups% }"
}

# _xinit_setup_sandbox: print the options that confine a unit of xinit.
_xinit_setup_sandbox() {
  printf '%s\n' "ProtectSystem=strict" "PrivateTmp=yes" "PrivateDevices=yes" \
    "NoNewPrivileges=yes" "ProtectKernelTunables=yes" "ProtectKernelModules=yes" \
    "ProtectControlGroups=yes" "RestrictSUIDSGID=yes" "LockPersonality=yes"
  # Unless xinit itself is installed there.
  case "$XINIT_SELF" in
    /home/* | /root/* | /run/user/*) ;;
    *) printf '%s\n' "ProtectHome=yes" ;;
  esac
}

# _xinit_setup_check_self: warn when someone else than root can change the xinit that the units
# will run, some of them as root.
_xinit_setup_check_self() {
  local path info
  for path in "$XINIT_SELF" "$XINIT_LIB_DIR"; do
    while [ -n "$path" ]; do
      info="$(stat -c '%u %a' -- "$path" 2>/dev/null)" || info=""
      # Owned by root, and writable neither by its group nor by the others. A sticky directory,
      # as /tmp, is fine: nobody can replace there what belongs to root.
      if [[ ! "$info" =~ ^0\ (1[0-7]{3}|[0-7]?[0-7][0145][0145])$ ]]; then
        XINIT_SETUP_WARNINGS+=("xinit is installed where another user than root can change it ($path): the units run it, some as root. Install it in a directory of root")
        return 0
      fi
      path="${path%/*}"
    done
  done
}

# _xinit_setup_credentials: add the credentials file of the db check to the plan, when the
# password can be read from XWiki's configuration and the file is not the administrator's own.
_xinit_setup_credentials() {
  local type="${XINIT_LAYOUT[DB_TYPE]-}" file hibernate password content
  local bs='\\' colon='\:' dq='\"'
  # A file the administrator names with DB_CREDENTIALS is the administrator's to write.
  [ -z "${XINIT_CFG[DB_CREDENTIALS]-}" ] || return 0
  file="${XINIT_CONF_DIR:-/etc/xinit}/credentials/$XINIT_INSTANCE"
  case "$type" in
    postgresql) file+=".pgpass" ;;
    mysql | mariadb) file+=".my.cnf" ;;
    *) return 0 ;;
  esac
  if [ -e "$file" ] && ! _xinit_setup_listed "$file"; then
    # Not written by an earlier setup: it stays as it is.
    return 0
  fi
  hibernate="${XINIT_ROOT:-}${XINIT_LAYOUT[CONFIG_DIR]-}/hibernate.cfg.xml"
  password="$(xinit_hibernate_get "$hibernate" connection.password 2>/dev/null)" || password=""
  if [ -z "$password" ] || [[ "$password" == *[[:cntrl:]]* ]]; then
    XINIT_SETUP_WARNINGS+=("no database password could be read from ${hibernate#"${XINIT_ROOT:-}"}: the db check will only test the port")
    return 0
  fi
  # Quoted replacements: bash 5.2 otherwise reads & in a replacement as "the matched text".
  case "$type" in
    postgresql)
      password="${password//\\/"$bs"}"
      password="${password//:/"$colon"}"
      content="*:*:*:*:$password"
      ;;
    *)
      password="${password//\\/"$bs"}"
      password="${password//\"/"$dq"}"
      content="[client]"$'\n'"password=\"$password\""
      ;;
  esac
  _xinit_setup_file "$file" 0600 "$XINIT_SERVICE_USER" 1 "$content"
}

# _xinit_setup_listed <path>: the manifest of this instance lists this file.
_xinit_setup_listed() {
  local manifest kind path
  manifest="$(_xinit_setup_manifest)"
  [ -f "$manifest" ] || return 1
  while read -r kind path; do
    [ "$kind" = file ] && [ "$path" = "$1" ] && return 0
  done <"$manifest"
  return 1
}

# _xinit_setup_jvm_options: set XINIT_SETUP_JVM to the Environment= line that adds
# JVM_OPTS_APPEND, or to nothing. The java launcher reads JDK_JAVA_OPTIONS itself, whatever
# starts it. Not called as $(...): its warnings and its errors would be lost.
_xinit_setup_jvm_options() {
  local options="${XINIT_CFG[JVM_OPTS_APPEND]-}" pid="${XINIT_LAYOUT[JVM_PID]-}" cmdline=""
  local percent='%%'
  XINIT_SETUP_JVM=""
  [ -n "$options" ] || return 0
  if [[ "$options" == *[\"\\[:cntrl:]]* ]]; then
    xinit_die "JVM_OPTS_APPEND cannot hold a double quote, a backslash or a control character"
  fi
  # An option on the command line wins over the same one in JDK_JAVA_OPTIONS.
  if [ -n "$pid" ] && [ -r "${XINIT_ROOT:-}/proc/$pid/cmdline" ]; then
    cmdline="$(tr '\0' ' ' <"${XINIT_ROOT:-}/proc/$pid/cmdline")"
  fi
  if [[ " $options" == *" -Xmx"* && " $cmdline" == *" -Xmx"* ]]; then
    XINIT_SETUP_WARNINGS+=("-Xmx is already on the command line of the JVM, where it wins over JVM_OPTS_APPEND: change it where it is set")
  fi
  XINIT_SETUP_JVM="Environment=\"JDK_JAVA_OPTIONS=${options//%/"$percent"}\""
}

# _xinit_setup_plan: fill the plan for this instance.
_xinit_setup_plan() {
  local root="${XINIT_ROOT:-}" i="$XINIT_INSTANCE" unit="${XINIT_LAYOUT[UNIT]}"
  local systemd="$root/etc/systemd/system" self="$XINIT_SELF" user="$XINIT_SERVICE_USER"
  local state run state_name run_name groups sandbox jvm warmup_timeout
  local header="# Written by 'xinit setup' for the instance $i. Removed by 'xinit setup --undo'."
  state="$(_xinit_instance_dir STATE_DIR)"
  run="$(_xinit_instance_dir RUN_DIR)"
  state="${state%/*}"
  run="${run%/*}"
  # systemd creates them, for the user of the periodic job.
  [[ "$state" =~ ^/var/lib/[A-Za-z0-9_.-]+$ ]] ||
    xinit_die "setup: STATE_DIR has to be a directory of /var/lib: $state"
  [[ "$run" =~ ^/run/[A-Za-z0-9_.-]+$ ]] ||
    xinit_die "setup: RUN_DIR has to be a directory of /run: $run"
  [[ "$self" != *[[:space:]%\"\\\']* ]] ||
    xinit_die "setup: xinit cannot be run by systemd from $self: install it in a path without spaces or quotes"
  state_name="${state#/var/lib/}"
  run_name="${run#/run/}"
  _xinit_setup_groups
  groups="$XINIT_SETUP_GROUPS"
  sandbox="$(_xinit_setup_sandbox)"
  _xinit_setup_jvm_options
  jvm="$XINIT_SETUP_JVM"
  warmup_timeout="$(xinit_duration_seconds "${XINIT_CFG[WARMUP_TIMEOUT]-}")" ||
    xinit_die "WARMUP_TIMEOUT is not a duration: ${XINIT_CFG[WARMUP_TIMEOUT]-}"

  _xinit_setup_file "$root/etc/sysusers.d/xinit.conf" 0644 "" 0 \
    "# Written by 'xinit setup'. Removed by 'xinit setup --undo'.
u $user - \"Xinit, the monitoring of XWiki\" $state /usr/sbin/nologin"

  _xinit_setup_file "$systemd/$unit.d/50-xinit.conf" 0644 "" 0 \
    "$header
[Service]
# A crashed XWiki is started again, and the crash is notified at once: not a stop someone asked
# for, and not one the periodic job asked for, even when XWiki had to be killed to stop.
Restart=on-failure
RestartSec=10
ExecStopPost=-+/bin/sh -c '[ \"\$\$SERVICE_RESULT\" = success ] || [ \"\$\$(systemctl show -p ActiveState --value xinit-act@$i.service)\" = activating ] || systemctl start --no-block xinit-notify@$i.service'
# The first requests are made after each start, whoever started it.
ExecStartPost=-+systemctl start --no-block xinit-warmup@$i.service${jvm:+
$jvm}"

  _xinit_setup_file "$systemd/xinit-watch@$i.service" 0644 "" 0 \
    "$header
[Unit]
Description=Xinit: check the XWiki instance $i, and restart it after repeated failures

[Service]
Type=oneshot
User=$user
Group=$user
SupplementaryGroups=$groups
ExecStart=$self -i $i watch
# What a run does is in the journal (journalctl -t xinit), and its results in the state.
StandardOutput=null
TimeoutStartSec=15min
StateDirectory=$state_name $state_name/$i
StateDirectoryMode=0700
RuntimeDirectory=$run_name/$i
RuntimeDirectoryMode=0700
RuntimeDirectoryPreserve=yes
$sandbox"

  _xinit_setup_file "$systemd/xinit-watch@$i.timer" 0644 "" 0 \
    "$header
[Unit]
Description=Xinit: check the XWiki instance $i every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=5s

[Install]
WantedBy=timers.target"

  _xinit_setup_file "$systemd/xinit-act@$i.path" 0644 "" 0 \
    "$header
[Unit]
Description=Xinit: requests of the periodic job of the XWiki instance $i

[Path]
PathExists=$run/$i/request-thread-dump
PathExists=$run/$i/request-restart

[Install]
WantedBy=multi-user.target"

  _xinit_setup_file "$systemd/xinit-act@$i.service" 0644 "" 0 \
    "$header
[Unit]
Description=Xinit: restart the XWiki instance $i, or take a thread dump of it

[Service]
Type=oneshot
ExecStart=$self -i $i act
TimeoutStartSec=10min
ReadWritePaths=-$run
$sandbox"

  _xinit_setup_file "$systemd/xinit-notify@$i.service" 0644 "" 0 \
    "$header
[Unit]
Description=Xinit: notify that the XWiki instance $i has crashed

[Service]
Type=oneshot
User=$user
Group=$user
SupplementaryGroups=$groups
ExecStart=$self -i $i notify crash
# It remembers what it notified, not to say it again and again.
StateDirectory=$state_name $state_name/$i
StateDirectoryMode=0700
$sandbox"

  _xinit_setup_file "$systemd/xinit-warmup@$i.service" 0644 "" 0 \
    "$header
[Unit]
Description=Xinit: first requests to the XWiki instance $i after its start
After=$unit
PartOf=$unit

[Service]
Type=oneshot
User=$user
Group=$user
SupplementaryGroups=$groups
ExecStart=$self -i $i warmup
TimeoutStartSec=$((warmup_timeout + 60))
$sandbox"

  _xinit_setup_credentials
  _xinit_setup_check_self
  XINIT_SETUP_ENABLE=("xinit-act@$i.path" "xinit-watch@$i.timer")
}

# _xinit_setup_compare: set XINIT_SETUP_CHANGE for each file of the plan: create, update or
# unchanged.
_xinit_setup_compare() {
  local n path
  for n in "${!XINIT_SETUP_PATH[@]}"; do
    path="${XINIT_SETUP_PATH[$n]}"
    if [ ! -e "$path" ]; then
      XINIT_SETUP_CHANGE[n]=create
    elif printf '%s\n' "${XINIT_SETUP_CONTENT[$n]}" | cmp -s - "$path"; then
      XINIT_SETUP_CHANGE[n]=unchanged
    else
      XINIT_SETUP_CHANGE[n]=update
    fi
  done
}

# _xinit_setup_print <format> <action> <dry run: true|false>: print the plan.
_xinit_setup_print() {
  local format="$1" action="$2" dry="$3" n sep="" item path
  if [ "$format" = json ]; then
    printf '{"instance":%s,"action":"%s","dry_run":%s,"files":[' \
      "$(xinit_json_string "$XINIT_INSTANCE")" "$action" "$dry"
    for n in "${!XINIT_SETUP_PATH[@]}"; do
      printf '%s{"path":%s,"change":"%s"}' "$sep" \
        "$(xinit_json_string "${XINIT_SETUP_PATH[$n]#"${XINIT_ROOT:-}"}")" "${XINIT_SETUP_CHANGE[$n]}"
      sep=","
    done
    printf '],"commands":['
    sep=""
    for item in "${XINIT_SETUP_COMMANDS[@]}"; do
      printf '%s%s' "$sep" "$(xinit_json_string "$item")"
      sep=","
    done
    printf '],"warnings":['
    sep=""
    for item in "${XINIT_SETUP_WARNINGS[@]}"; do
      printf '%s%s' "$sep" "$(xinit_json_string "$item")"
      sep=","
    done
    printf ']}\n'
    return 0
  fi
  for n in "${!XINIT_SETUP_PATH[@]}"; do
    path="${XINIT_SETUP_PATH[$n]}"
    printf '%s: %s\n' "${XINIT_SETUP_CHANGE[$n]}" "${path#"${XINIT_ROOT:-}"}"
    case "${XINIT_SETUP_CHANGE[$n]}" in
      create | update)
        if [ "${XINIT_SETUP_SECRET[$n]}" = 1 ]; then
          printf '    (a secret: its content is not shown)\n'
        else
          # What changes, as a diff against what is there.
          printf '%s\n' "${XINIT_SETUP_CONTENT[$n]}" |
            diff -u --label "${path#"${XINIT_ROOT:-}"}" --label "${path#"${XINIT_ROOT:-}"}" \
              "$([ -e "$path" ] && printf '%s' "$path" || printf /dev/null)" - | sed 's/^/    /' || true
        fi
        ;;
    esac
  done
  for item in "${XINIT_SETUP_COMMANDS[@]}"; do
    printf 'run: %s\n' "$item"
  done
  for item in "${XINIT_SETUP_WARNINGS[@]}"; do
    printf 'warning: %s\n' "$item"
  done
  [ "$dry" = false ] || printf 'dry run: nothing was written or run\n'
}

# _xinit_setup_write <n>: write one file of the plan, in one rename.
_xinit_setup_write() {
  local n="$1" path="${XINIT_SETUP_PATH[$1]}" owner="${XINIT_SETUP_OWNER[$1]}" tmp
  mkdir -p -- "${path%/*}" || return 1
  tmp="$(mktemp -- "$path.XXXXXX")" || return 1
  if printf '%s\n' "${XINIT_SETUP_CONTENT[$n]}" >"$tmp" && chmod "${XINIT_SETUP_MODE[$n]}" -- "$tmp" &&
    { [ -z "$owner" ] || chown "$owner:$owner" -- "$tmp"; } && mv -f -- "$tmp" "$path"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# _xinit_setup_run <command...>: run a command of the plan, and stop when it fails. What it
# prints is only shown then.
_xinit_setup_run() {
  local output
  output="$("$@" 2>&1)" || xinit_die "setup: '$*' failed${output:+: $output}"
}

# _xinit_setup_do: carry the plan out.
_xinit_setup_do() {
  local n manifest path run lines=() user="$XINIT_SERVICE_USER"
  manifest="$(_xinit_setup_manifest)"
  # The manifest first: whatever happens next, --undo knows what to remove.
  for n in "${!XINIT_SETUP_PATH[@]}"; do
    [ "${XINIT_SETUP_CHANGE[$n]}" = remove ] || lines+=("file ${XINIT_SETUP_PATH[$n]}")
  done
  for path in "${XINIT_SETUP_ENABLE[@]}"; do
    lines+=("unit $path")
  done
  # What this setup no longer writes goes first: it is still in the old manifest until then.
  for n in "${!XINIT_SETUP_PATH[@]}"; do
    [ "${XINIT_SETUP_CHANGE[$n]}" != remove ] || _xinit_setup_remove "${XINIT_SETUP_PATH[$n]}"
  done
  mkdir -p -- "${manifest%/*}" && printf '%s\n' "${lines[@]}" >"$manifest" ||
    xinit_die "setup: cannot write $manifest"

  # The user first: files are given to it.
  _xinit_setup_write 0 || xinit_die "setup: cannot write ${XINIT_SETUP_PATH[0]}"
  _xinit_setup_run systemd-sysusers "${XINIT_SETUP_PATH[0]}"
  for n in "${!XINIT_SETUP_PATH[@]}"; do
    [ "$n" -gt 0 ] && [ "${XINIT_SETUP_CHANGE[$n]}" != remove ] || continue
    if [ -n "${XINIT_SETUP_OWNER[$n]}" ]; then
      # Its directory: for root, and for the group of that user to enter.
      path="${XINIT_SETUP_PATH[$n]%/*}"
      mkdir -p -- "$path" && chown "root:$user" -- "$path" && chmod 0750 -- "$path" ||
        xinit_die "setup: cannot prepare $path"
    fi
    _xinit_setup_write "$n" || xinit_die "setup: cannot write ${XINIT_SETUP_PATH[$n]}"
  done
  # The runtime directory of all the instances is root's, and for the job to enter: a run of
  # xinit by root before this setup may have left it closed.
  run="$(_xinit_instance_dir RUN_DIR)"
  run="${run%/*}"
  [ ! -d "$run" ] || chmod 0755 -- "$run" || xinit_die "setup: cannot open $run to the job"
  _xinit_setup_run systemctl daemon-reload
  _xinit_setup_run systemctl enable --now "${XINIT_SETUP_ENABLE[@]}"
}

# _xinit_setup_manifest_trusted <manifest>: it says what to remove, so only root may have written
# it: owned by root, and writable neither by its group nor by the others. Else xinit stops.
_xinit_setup_manifest_trusted() {
  local info
  info="$(stat -c '%u %a' -- "$1" 2>/dev/null)" || info=""
  if [ "$(id -u)" = 0 ] && [[ ! "$info" =~ ^0\ [0-7]?[0-7][0145][0145]$ ]]; then
    xinit_die "setup: $1 is not a file that only root can write: not removing what it lists"
  fi
}

# _xinit_setup_removable <path>: a file that a manifest lists may be removed: it is where setup
# writes, and no other instance uses it. A manifest is never a way to remove another file.
_xinit_setup_removable() {
  local path="$1" root="${XINIT_ROOT:-}" manifest other
  manifest="$(_xinit_setup_manifest)"
  case "$path" in
    *..*) return 1 ;;
    "$root/etc/systemd/system/"* | "$root/etc/sysusers.d/xinit.conf") ;;
    "${XINIT_CONF_DIR:-/etc/xinit}/credentials/"*) ;;
    *) return 1 ;;
  esac
  for other in "${manifest%/*}"/*.manifest; do
    [ "$other" != "$manifest" ] && [ -f "$other" ] || continue
    ! grep -qxF -- "file $path" "$other" || return 1
  done
  return 0
}

# _xinit_setup_remove <path>: remove a file of setup, and its drop-in directory when it is empty.
_xinit_setup_remove() {
  rm -f -- "$1" || xinit_die "setup: cannot remove $1"
  case "$1" in *.d/50-xinit.conf) rmdir -- "${1%/*}" 2>/dev/null || true ;; esac
}

# _xinit_setup_stale: add to the plan, to be removed, what an earlier setup wrote for this
# instance and this one does not: the drop-in of another unit, the credentials of another
# database.
_xinit_setup_stale() {
  local manifest kind path planned
  manifest="$(_xinit_setup_manifest)"
  [ -f "$manifest" ] || return 0
  _xinit_setup_manifest_trusted "$manifest"
  while read -r kind path; do
    [ "$kind" = file ] && [ -e "$path" ] || continue
    for planned in "${XINIT_SETUP_PATH[@]}"; do
      [ "$planned" != "$path" ] || continue 2
    done
    _xinit_setup_removable "$path" || continue
    _xinit_setup_file "$path" "" "" 0 ""
    XINIT_SETUP_CHANGE[${#XINIT_SETUP_PATH[@]} - 1]=remove
  done <"$manifest"
}

# _xinit_setup_undo_plan: fill the plan with what the manifest lists. Returns 1 without manifest.
_xinit_setup_undo_plan() {
  local manifest kind path
  manifest="$(_xinit_setup_manifest)"
  [ -f "$manifest" ] || return 1
  _xinit_setup_manifest_trusted "$manifest"
  while read -r kind path; do
    case "$kind" in
      unit)
        [[ "$path" =~ ^xinit-[a-z]+@[A-Za-z0-9_.-]+\.(service|timer|path)$ ]] || continue
        XINIT_SETUP_ENABLE+=("$path")
        ;;
      file)
        _xinit_setup_removable "$path" || continue
        XINIT_SETUP_PATH+=("$path")
        XINIT_SETUP_CONTENT+=("")
        XINIT_SETUP_SECRET+=(0)
        if [ -e "$path" ]; then XINIT_SETUP_CHANGE+=(remove); else XINIT_SETUP_CHANGE+=(unchanged); fi
        ;;
    esac
  done <"$manifest"
  return 0
}

# _xinit_setup_undo_do: remove what the plan lists.
_xinit_setup_undo_do() {
  local n unit i="$XINIT_INSTANCE"
  for unit in "${XINIT_SETUP_ENABLE[@]}"; do
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
  done
  systemctl stop "xinit-watch@$i.service" "xinit-act@$i.service" "xinit-notify@$i.service" \
    "xinit-warmup@$i.service" >/dev/null 2>&1 || true
  for n in "${!XINIT_SETUP_PATH[@]}"; do
    _xinit_setup_remove "${XINIT_SETUP_PATH[$n]}"
  done
  _xinit_setup_run systemctl daemon-reload
  # A job that was stopped halfway is not left behind as a failed unit.
  systemctl reset-failed "xinit-watch@$i.service" "xinit-act@$i.service" "xinit-notify@$i.service" \
    "xinit-warmup@$i.service" >/dev/null 2>&1 || true
  rm -f -- "$(_xinit_setup_manifest)"
  rmdir -- "${XINIT_CONF_DIR:-/etc/xinit}/setup" "${XINIT_CONF_DIR:-/etc/xinit}/credentials" \
    2>/dev/null || true
}

# xinit_cmd_setup [--undo] [--dry-run] [--format text|json]: the `xinit setup` command.
xinit_cmd_setup() {
  local format=text dry=false undo=false key i="$XINIT_INSTANCE"
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=true && shift ;;
      --undo) undo=true && shift ;;
      --format)
        [ $# -ge 2 ] || xinit_die "--format needs a value" "$XINIT_EXIT_USAGE"
        format="$2"
        shift 2
        ;;
      --format=*) format="${1#--format=}" && shift ;;
      *) xinit_die "setup: unexpected argument $1" "$XINIT_EXIT_USAGE" ;;
    esac
  done
  case "$format" in
    text | json) ;;
    *) xinit_die "setup: unknown format $format (text, json)" "$XINIT_EXIT_USAGE" ;;
  esac
  if [ "$dry" = false ] && [ "$(id -u)" != 0 ]; then
    xinit_die "setup: only root can do this (--dry-run shows what it would do)"
  fi
  # What is written is for root to change and for everyone to read, whatever the caller's umask.
  umask 022

  if [ "$undo" = true ]; then
    if ! _xinit_setup_undo_plan; then
      XINIT_SETUP_WARNINGS+=("nothing to undo: xinit setup was not run for the instance $i")
      _xinit_setup_print "$format" undo "$dry"
      return 0
    fi
    XINIT_SETUP_COMMANDS=("systemctl disable --now ${XINIT_SETUP_ENABLE[*]}" "systemctl daemon-reload")
    XINIT_SETUP_WARNINGS+=("the user $XINIT_SERVICE_USER and the state in ${XINIT_CFG[STATE_DIR]} are kept")
    [ "$dry" = true ] || _xinit_setup_undo_do
    _xinit_setup_print "$format" undo "$dry"
    return 0
  fi

  if ! xinit_layout_resolve; then
    xinit_layout_explain_missing >&2 || true
    xinit_die "setup: the installation is not known well enough: see 'xinit layout'"
  fi
  for key in UNIT CONFIG_DIR WEBAPP_DIR; do
    [ -n "${XINIT_LAYOUT[$key]-}" ] || xinit_die "setup: $key is not known: see 'xinit layout'"
  done
  _xinit_setup_plan
  _xinit_setup_compare
  _xinit_setup_stale
  XINIT_SETUP_COMMANDS=("systemd-sysusers ${XINIT_SETUP_PATH[0]#"${XINIT_ROOT:-}"}"
    "systemctl daemon-reload"
    "systemctl enable --now ${XINIT_SETUP_ENABLE[*]}")
  if [ -n "${XINIT_CFG[JVM_OPTS_APPEND]-}" ]; then
    XINIT_SETUP_WARNINGS+=("JVM_OPTS_APPEND applies at the next start of ${XINIT_LAYOUT[UNIT]}: restart it when it suits")
  fi
  [ "$dry" = true ] || _xinit_setup_do
  _xinit_setup_print "$format" setup "$dry"
}
