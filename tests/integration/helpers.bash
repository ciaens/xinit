# shellcheck shell=bash
# Helpers for the integration tests: run commands in the test container, query XWiki, and inject
# or heal faults. Loaded by every tests/integration/*.bats file (`load helpers`).
#
# The container comes from tests/env/xwiki-env.sh; tests/run.sh starts it and exports:
#   XT_CONTAINER   container name
#   XT_VARIANT     image variant (tomcat10-pgsql, xjetty-mariadb...)

: "${XT_CONTAINER:?XT_CONTAINER is not set - run the tests through tests/run.sh}"
: "${XT_VARIANT:?XT_VARIANT is not set - run the tests through tests/run.sh}"

XT_BASE_URL="http://localhost:8080/xwiki"

# The servlet container's unit, from the variant.
case "$XT_VARIANT" in
  xjetty-*) XT_UNIT=xwiki.service ;;
  tomcat*-*) XT_UNIT="${XT_VARIANT%%-*}.service" ;;
  *) XT_UNIT="" ;;
esac
case "$XT_VARIANT" in
  *-pgsql) XT_DB_UNIT=postgresql.service ;;
  *) XT_DB_UNIT=mariadb.service ;;
esac
export XT_BASE_URL XT_UNIT XT_DB_UNIT

# in_env <cmd...>: run a command in the container as root.
in_env() { docker exec -i "$XT_CONTAINER" "$@"; }
# in_env_sh <script>: run a shell script in the container.
in_env_sh() { docker exec -i "$XT_CONTAINER" bash -c "$1"; }

# http_code <path> [curl args...]: HTTP code of a request from inside the container, 000 if none.
http_code() {
  local path="$1"
  shift
  in_env curl -s -o /dev/null -w '%{http_code}' --max-time "${XT_HTTP_TIMEOUT:-30}" "$@" \
    "$XT_BASE_URL$path" || true
}

# wait_http <expected code> <timeout seconds> <path> [curl args...]
wait_http() {
  local expected="$1" timeout="$2" path="$3" end c
  shift 3
  end=$((SECONDS + timeout))
  while ((SECONDS < end)); do
    c="$(XT_HTTP_TIMEOUT=10 http_code "$path" "$@")"
    [ "$c" = "$expected" ] && return 0
    sleep 2
  done
  echo "wait_http: $path never answered $expected (last: $c)" >&2
  return 1
}

# jvm_pid: the servlet container's JVM (the unit's MainPID when it is a java process).
jvm_pid() {
  in_env_sh "pid=\$(systemctl show -p MainPID --value $XT_UNIT);
    [ \"\$pid\" != 0 ] && [ \"\$(cat /proc/\$pid/comm 2>/dev/null)\" = java ] && echo \$pid"
}

# wait_healthy [timeout]: XWiki answers 200 on its home page.
wait_healthy() { wait_http 200 "${1:-300}" /bin/view/Main/; }

# ---------------------------------------------------------------------------------------------
# Fault page: a Groovy page (Admin has programming rights) that misbehaves on request.
#   ?action=sleep&ms=N      answer after N ms (slow page)
#   ?action=status&code=N   answer with HTTP status N
#   ?action=deadlock        start two threads deadlocked on each other (visible in thread dumps)
#   ?action=hog&mb=N        keep N more MB of heap referenced (System property xinit.hog)
#   ?action=release         drop the heap hog
# ---------------------------------------------------------------------------------------------
install_fault_page() {
  local content
  content="$(cat <<'GROOVY'
{{groovy}}
def action = request.getParameter('action')
if (action == 'sleep') {
  Thread.sleep((request.getParameter('ms') ?: '1000') as long)
  println 'slept'
} else if (action == 'status') {
  response.setStatus((request.getParameter('code') ?: '500') as int)
  println 'status set'
} else if (action == 'deadlock') {
  def a = new Object(), b = new Object()
  def t1 = new Thread({ synchronized (a) { Thread.sleep(200); synchronized (b) {} } } as Runnable, 'xinit-deadlock-1')
  def t2 = new Thread({ synchronized (b) { Thread.sleep(200); synchronized (a) {} } } as Runnable, 'xinit-deadlock-2')
  [t1, t2].each { it.daemon = true; it.start() }
  println 'deadlock started'
} else if (action == 'hog') {
  def hog = System.properties.get('xinit.hog') ?: []
  System.properties.put('xinit.hog', hog)
  ((request.getParameter('mb') ?: '100') as int).times { hog << new byte[1024 * 1024] }
  println "hog: ${hog.size()} MB"
} else if (action == 'release') {
  System.properties.remove('xinit.hog')
  println 'released'
}
{{/groovy}}
GROOVY
)"
  local xml
  xml="<page xmlns=\"http://www.xwiki.org\"><title>Xinit test faults</title><syntax>xwiki/2.1</syntax><content>$(
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$content")</content></page>"
  local c
  c="$(in_env curl -s -o /dev/null -w '%{http_code}' --max-time 60 -u Admin:admin -X PUT \
    -H 'Content-Type: application/xml' --data-binary @- \
    "$XT_BASE_URL/rest/wikis/xwiki/spaces/XinitTest/pages/Faults" <<<"$xml")"
  [[ "$c" =~ ^20[12]$ ]] || { echo "install_fault_page: PUT answered $c" >&2; return 1; }
}

# fault_url <query>: path of the fault page with a query string.
fault_url() { echo "/bin/view/XinitTest/Faults?$1"; }

# ---------------------------------------------------------------------------------------------
# Faults on the process, the database and the configuration. Each fault_* has a heal_*.
# ---------------------------------------------------------------------------------------------
fault_kill_jvm()     { in_env kill -9 "$(jvm_pid)"; }
fault_freeze_jvm()   { in_env kill -STOP "$(jvm_pid)"; }
heal_freeze_jvm()    { in_env kill -CONT "$(jvm_pid)"; }
fault_stop_unit()    { in_env systemctl stop "$XT_UNIT"; }
heal_stop_unit()     { in_env systemctl start "$XT_UNIT"; }
fault_stop_db()      { in_env systemctl stop "$XT_DB_UNIT"; }
heal_stop_db()       { in_env systemctl start "$XT_DB_UNIT"; }

# A wrong DB password in hibernate.cfg.xml: XWiki can no longer connect after a restart.
fault_db_password() {
  in_env_sh "cp -a /etc/xwiki/hibernate.cfg.xml /etc/xwiki/hibernate.cfg.xml.xinit-test &&
    sed -i 's|<property name=\"hibernate.connection.password\">[^<]*<|<property name=\"hibernate.connection.password\">wrong-password<|' /etc/xwiki/hibernate.cfg.xml &&
    systemctl restart $XT_UNIT"
}
heal_db_password() {
  in_env_sh "mv /etc/xwiki/hibernate.cfg.xml.xinit-test /etc/xwiki/hibernate.cfg.xml &&
    systemctl restart $XT_UNIT"
}

# JVM options go through JDK_JAVA_OPTIONS, which the java launcher reads itself: a JAVA_OPTS in
# the unit is overridden by the Tomcat start script, which sources /etc/default/tomcatN.

# A small heap: with the fault page's hog, a real java.lang.OutOfMemoryError.
fault_small_heap() {
  in_env_sh "mkdir -p /etc/systemd/system/$XT_UNIT.d &&
    printf '[Service]\nEnvironment=JDK_JAVA_OPTIONS=-Xmx${1:-768m}\n' \
      > /etc/systemd/system/$XT_UNIT.d/90-xinit-test-heap.conf &&
    systemctl daemon-reload && systemctl restart $XT_UNIT"
}
heal_small_heap() {
  in_env_sh "rm -f /etc/systemd/system/$XT_UNIT.d/90-xinit-test-heap.conf &&
    systemctl daemon-reload && systemctl restart $XT_UNIT"
}

# A cgroup memory limit below the heap size: the kernel OOM killer kills the JVM before Java
# throws OutOfMemoryError. Without -Xmx the JVM would size its heap from the cgroup limit (25%).
fault_cgroup_memory() {
  in_env_sh "mkdir -p /etc/systemd/system/$XT_UNIT.d &&
    printf '[Service]\nMemoryMax=${1:-1200M}\nMemorySwapMax=0\nEnvironment=JDK_JAVA_OPTIONS=-Xmx4g\n' \
      > /etc/systemd/system/$XT_UNIT.d/90-xinit-test-memory.conf &&
    systemctl daemon-reload && systemctl restart $XT_UNIT"
}
heal_cgroup_memory() {
  in_env_sh "rm -f /etc/systemd/system/$XT_UNIT.d/90-xinit-test-memory.conf &&
    systemctl daemon-reload && systemctl restart $XT_UNIT"
}

# heal_all: best effort, used by teardown so that one failed test does not poison the next.
heal_all() {
  in_env_sh "pid=\$(systemctl show -p MainPID --value $XT_UNIT); [ \"\$pid\" != 0 ] && kill -CONT \$pid
    [ -f /etc/xwiki/hibernate.cfg.xml.xinit-test ] && mv /etc/xwiki/hibernate.cfg.xml.xinit-test /etc/xwiki/hibernate.cfg.xml
    restart=
    if ls /etc/systemd/system/$XT_UNIT.d/90-xinit-test-*.conf >/dev/null 2>&1; then
      rm -f /etc/systemd/system/$XT_UNIT.d/90-xinit-test-*.conf; systemctl daemon-reload; restart=1
    fi
    systemctl start $XT_DB_UNIT
    if [ -n \"\$restart\" ]; then systemctl restart $XT_UNIT; else systemctl is-active -q $XT_UNIT || systemctl start $XT_UNIT; fi
    true" >/dev/null 2>&1 || true
}
