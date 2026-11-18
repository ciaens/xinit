#!/usr/bin/env bash
# Copy the files and command outputs xinit reads from a test image into tests/fixtures/<variant>/.
#
# Usage: tests/fixtures/collect.sh [variant...]     (default: every variant in tests/env/variants
#                                                    whose image exists locally)
#
# For each variant it starts a disposable container, waits for XWiki, copies the files, replaces
# secrets with REDACTED, and removes the container. See README.md for the layout of the result.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENV_SH="$HERE/../env/xwiki-env.sh"

die() { echo "collect: $*" >&2; exit 1; }

# The files to copy, one path per line, for a variant. Missing files are skipped.
files_for() {
  local variant=$1 n
  case "$variant" in
    war-tomcat*)
      n=${variant#war-tomcat}; n=${n%%-*}
      printf '%s\n' \
        "/var/lib/tomcat$n/webapps/xwiki/WEB-INF/hibernate.cfg.xml" \
        "/var/lib/tomcat$n/webapps/xwiki/WEB-INF/xwiki.properties" \
        "/var/lib/tomcat$n/webapps/xwiki/META-INF/extension.xed" \
        "/etc/tomcat$n/server.xml" \
        "/etc/default/tomcat$n"
      ;;
    tomcat*)
      n=${variant#tomcat}; n=${n%%-*}
      printf '%s\n' \
        /etc/xwiki/hibernate.cfg.xml \
        /etc/xwiki/xwiki.properties \
        "/etc/tomcat$n/Catalina/localhost/xwiki.xml" \
        "/etc/tomcat$n/server.xml" \
        "/etc/default/tomcat$n" \
        /usr/lib/xwiki/META-INF/extension.xed
      ;;
    xjetty*)
      printf '%s\n' \
        /etc/xwiki/hibernate.cfg.xml \
        /etc/xwiki/xwiki.properties \
        /etc/xwiki/xjetty-web.xml \
        /usr/lib/xwiki-jetty/start.d/xwiki.ini \
        /usr/lib/xwiki/META-INF/extension.xed
      ;;
    *) die "unknown variant family: $variant" ;;
  esac
}

unit_for() {
  local variant=${1#war-}
  case "$variant" in
    tomcat*) echo "${variant%%-*}" ;;
    xjetty*) echo xwiki ;;
  esac
}

collect() {
  local variant=$1 name="xinit-fixtures-$1" out="$HERE/$1" unit hib password
  unit=$(unit_for "$variant")
  docker image inspect "xinit-test/xwiki:$variant" >/dev/null 2>&1 \
    || die "no image for $variant: build it with tests/env/xwiki-env.sh build $variant"

  echo "== $variant"
  docker rm -f "$name" >/dev/null 2>&1 || true
  "$ENV_SH" start "$variant" "$name" >/dev/null
  # shellcheck disable=SC2064  # expand $name now
  trap "docker rm -f '$name' >/dev/null 2>&1 || true" EXIT
  "$ENV_SH" wait "$name" >/dev/null

  rm -rf "$out"
  mkdir -p "$out/cmd"

  # Files. -h copies what a symlink points to: the package links Tomcat's context file to
  # /etc/xwiki, and an absolute link would dangle in the fixture tree.
  files_for "$variant" | docker exec -i "$name" \
    tar -ch --ignore-failed-read -T - -f - 2>/dev/null | tar -x -C "$out" -f -

  # Command outputs.
  in_c() { docker exec "$name" "$@"; }
  in_c systemctl show "$unit" > "$out/cmd/systemctl-show-$unit.txt"
  in_c systemctl cat "$unit" > "$out/cmd/systemctl-cat-$unit.txt"
  in_c sh -c "dpkg-query -W -f '\${Package}\t\${Version}\t\${db:Status-Abbrev}\n' \
    'xwiki*' 'tomcat*' 2>/dev/null || true" > "$out/cmd/dpkg-query.txt"
  # The unit's processes, without their arguments: which one is MainPID, which one is java.
  in_c sh -c "ps -o pid,ppid,user,comm -u \"\$(systemctl show -p User --value $unit)\"" \
    > "$out/cmd/ps-unit-user.txt"
  in_c cat /proc/1/comm > "$out/cmd/proc-1-comm.txt"
  in_c sh -c 'systemd-detect-virt --container || true' > "$out/cmd/systemd-detect-virt.txt"

  # extension.xed lists every bundled extension (~300 KB). Only its header is read.
  local xed
  xed=$(find "$out" -name extension.xed)
  [ -n "$xed" ] || die "$variant: extension.xed not found"
  { sed -n '1,/<\/summary>/p' "$xed"; echo '    <!-- truncated by tests/fixtures/collect.sh -->'
      echo '</extension>'; } > "$xed.tmp"
  mv "$xed.tmp" "$xed"

  # Redact the database password, then check the real one is nowhere in the fixtures.
  hib=$(find "$out" -name hibernate.cfg.xml)
  [ -n "$hib" ] || die "$variant: hibernate.cfg.xml not found"
  password=$(python3 - "$hib" <<'PYEOF'
import re, sys
text = re.sub(r'<!--.*?-->', '', open(sys.argv[1]).read(), flags=re.S)
found = re.findall(r'name="(?:hibernate\.)?connection\.password">([^<]*)<', text)
print(found[0] if found else '')
PYEOF
)
  sed -i -E 's#(name="(hibernate\.)?connection\.password">)[^<]*<#\1REDACTED<#' "$hib"
  if [ "${#password}" -ge 6 ] && grep -rqF -- "$password" "$out"; then
    die "$variant: the database password is still present in $out"
  fi

  chmod -R u=rwX,go=rX "$out"
  docker rm -f "$name" >/dev/null
  trap - EXIT
  (cd "$out" && find . -type f | sort | sed 's#^\./#   #')
}

if [ $# -eq 0 ]; then
  while read -r variant _; do
    case "$variant" in ''|'#'*) continue ;; esac
    docker image inspect "xinit-test/xwiki:$variant" >/dev/null 2>&1 && set -- "$@" "$variant"
  done < "$HERE/../env/variants"
fi
[ $# -gt 0 ] || die "no variant given and no local test image found"

for variant in "$@"; do
  collect "$variant"
done
