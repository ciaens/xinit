#!/usr/bin/env bash
# Build and run disposable XWiki test instances for xinit: Debian + systemd (PID 1) + one official
# XWiki Debian package, already provisioned (flavor installed, Admin:admin and standard:standard).
#
# Usage:
#   xwiki-env.sh build <variant>             build the image xinit-test/xwiki:<variant> (~10min once)
#   xwiki-env.sh start <variant> [name]      start a container from it (default name: xinit-<variant>)
#   xwiki-env.sh wait  <name>                wait until XWiki answers 200 on the main page
#   xwiki-env.sh exec  <name> <cmd...>       run a command inside it (as root)
#   xwiki-env.sh rm    <name>                remove the container
#   xwiki-env.sh list                        list test images and containers
#
# <variant>  the package name without "xwiki-": tomcat10-pgsql, tomcat11-mariadb, xjetty-pgsql...
#
# Environment:
#   BASE_IMAGE        Debian base image (default debian:13)
#   XINIT_TEST_CA     a PEM bundle to trust inside the container, for an HTTPS-intercepting proxy.
#                     Injected at build and start, and removed before the image is committed.
#   XINIT_TEST_PORT   if set, publish XWiki's 8080 on 127.0.0.1:<port>
#   XINIT_TEST_KEEP   if set, keep the build container (xinit-build-<variant>) when the build fails
#
# The repository is mounted read-only at /src/xinit in every started container.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BASE_IMAGE="${BASE_IMAGE:-debian:13}"
BASE_TAG="xinit-test/systemd:${BASE_IMAGE//[:\/]/-}"

die() { echo "ERROR: $*" >&2; exit 1; }
usage() { awk 'NR>1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit "${1:-1}"; }

check_variant() {
  [[ "${1:-}" =~ ^(tomcat[0-9]+|xjetty)-(pgsql|mysql|mariadb)$ ]] \
    || die "'${1:-}' is not a variant like tomcat10-pgsql or xjetty-mariadb"
}

# Flags systemd needs to run as PID 1. --cgroupns=host + the cgroup mount work on cgroup v1 and v2
# hosts; SYSTEMD_CGROUP_ENABLE_LEGACY_FORCE lets systemd >= 256 boot on a cgroup v1 host.
SYSTEMD_FLAGS=(--privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw
  --tmpfs /run --tmpfs /run/lock -e SYSTEMD_CGROUP_ENABLE_LEGACY_FORCE=1)

wait_systemd() {
  local state
  for _ in $(seq 1 60); do
    state="$(docker exec "$1" systemctl is-system-running 2>/dev/null || true)"
    [[ "$state" == running || "$state" == degraded ]] && return 0
    sleep 1
  done
  die "systemd did not boot in $1 (state: ${state:-none})"
}

inject_ca() {
  [ -n "${XINIT_TEST_CA:-}" ] || return 0
  [ -r "$XINIT_TEST_CA" ] || die "XINIT_TEST_CA=$XINIT_TEST_CA is not readable"
  # One certificate per file: Java's trust store (ca-certificates-java) only imports the first
  # certificate of each file, and the bundle may hold many.
  docker exec -i "$1" sh -c 'cd /usr/local/share/ca-certificates &&
    awk "/BEGIN CERT/{n++} {print > (\"xinit-test-ca-\" n \".crt\")}" && update-ca-certificates >/dev/null 2>&1' \
    < "$XINIT_TEST_CA"
}

cmd_build() {
  check_variant "${1:-}"
  local variant="$1" name="xinit-build-$1" version
  docker build -q --build-arg BASE="$BASE_IMAGE" -t "$BASE_TAG" "$HERE" >/dev/null
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" "${SYSTEMD_FLAGS[@]}" "$BASE_TAG" >/dev/null
  [ -n "${XINIT_TEST_KEEP:-}" ] || trap 'docker rm -f "'"$name"'" >/dev/null 2>&1 || true' EXIT
  wait_systemd "$name"
  inject_ca "$name"
  docker cp "$HERE/provision.sh" "$name":/root/provision.sh
  docker exec "$name" bash /root/provision.sh "xwiki-$variant"
  version="$(docker exec "$name" dpkg-query -W -f='${Version}' xwiki-common)"
  echo "stopping services before committing"
  docker exec "$name" bash -c 'systemctl stop xwiki tomcat9 tomcat10 tomcat11 2>/dev/null;
    systemctl stop postgresql mariadb mysql 2>/dev/null;
    rm -f /usr/local/share/ca-certificates/xinit-test-ca-*.crt /root/provision.sh;
    update-ca-certificates --fresh >/dev/null 2>&1; apt-get clean; rm -rf /var/lib/apt/lists/*;
    journalctl --rotate >/dev/null 2>&1; journalctl --vacuum-time=1s >/dev/null 2>&1; true'
  docker stop "$name" >/dev/null
  docker commit -c 'CMD ["/sbin/init"]' -c 'STOPSIGNAL SIGRTMIN+3' \
    "$name" "xinit-test/xwiki:$variant-$version" >/dev/null
  docker tag "xinit-test/xwiki:$variant-$version" "xinit-test/xwiki:$variant"
  docker rm -f "$name" >/dev/null
  echo "built xinit-test/xwiki:$variant (= $variant-$version)"
}

cmd_start() {
  check_variant "${1:-}"
  local variant="$1" name="${2:-xinit-$1}" ports=()
  docker image inspect "xinit-test/xwiki:$variant" >/dev/null 2>&1 \
    || die "no image xinit-test/xwiki:$variant - run: $0 build $variant"
  [ -n "${XINIT_TEST_PORT:-}" ] && ports=(-p "127.0.0.1:$XINIT_TEST_PORT:8080")
  docker run -d --name "$name" --hostname "$name" "${SYSTEMD_FLAGS[@]}" "${ports[@]}" \
    -v "$REPO:/src/xinit:ro" "xinit-test/xwiki:$variant" >/dev/null
  wait_systemd "$name"
  inject_ca "$name"
  echo "$name"
}

cmd_wait() {
  local name="${1:?container name}" c
  for _ in $(seq 1 200); do
    c="$(docker exec "$name" curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
      http://localhost:8080/xwiki/bin/view/Main/ || true)"
    [ "$c" = 200 ] && { echo "XWiki is up in $name"; return 0; }
    sleep 3
  done
  die "XWiki did not answer 200 in $name (last code: $c)"
}

case "${1:-}" in
  build) shift; cmd_build "$@" ;;
  start) shift; cmd_start "$@" ;;
  wait)  shift; cmd_wait "$@" ;;
  exec)  shift; name="${1:?container name}"; shift; docker exec -i "$name" "$@" ;;
  rm)    shift; docker rm -f "${1:?container name}" >/dev/null ;;
  list)  docker images 'xinit-test/*'; docker ps -a --filter 'ancestor=xinit-test/xwiki' ;;
  -h|--help) usage 0 ;;
  *) usage 1 ;;
esac
