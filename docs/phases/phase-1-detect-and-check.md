# Phase 1 — Detection and read-only checks

Goal: `xinit layout` and `xinit check` are correct on every supported install type, **without
changing anything** on the host. This alone is useful: you can run it from Nagios, from a container
`HEALTHCHECK`, or by hand.

## Tasks

### 1.1 Core (`lib/xinit/core.sh`, `lib/xinit/config.sh`)
- Config parser (done): one `KEY=value` per line, with `#` comment lines. A value is bare, `"…"` or
  `'…'`, and always literal: nothing is expanded, and the file is never sourced.
  - There is no comment after a value, because `#` is legal in URLs.
  - A malformed line is fatal (exit 3) and names its file and line.
  - An unknown key gives a warning and is ignored.
  - Layers: built-in defaults < `xinit.conf` < `instances/<name>.conf` < `XINIT_<KEY>` environment
    < `-o KEY=value` on the command line. Each value keeps its source.
  - The configuration directory is `/etc/xinit`, or `$XINIT_CONF_DIR`.
- Instance resolution (done): `-i <name>`. Without it, the instance is the only file in
  `instances/`, or `default` when there is none. With several files, `-i` is required.
- Logging (done): to stderr. A run started by systemd has its stderr in the journal. Logging
  what xinit does to the journal comes with `xinit watch` (Phase 2), which is the first command
  to do anything.
- Result model and renderers (done): `text`, `json`, `nagios`. A result has a status, a `reason`
  for programs, a message for people, and metrics. Exit codes: 0 ok, 1 warn, 2 crit, 3 unknown
  (Nagios convention). The overall status is the worst one, in the order crit, warn, unknown, ok.

### 1.2 Layout and profiles (done)
Profiles, in detection order:
- `debian-tomcat`: `dpkg-query -W 'xwiki-tomcat*-common'` gives N, then `tomcatN.service`.
  `WEBAPP_DIR` comes from `docBase` in `/etc/tomcatN/Catalina/localhost/*.xml` and the context path
  from the file name (`xwiki.xml` → `/xwiki`, `ROOT.xml` → `/`). The port comes from
  `/etc/tomcatN/server.xml`, which has commented-out `<Connector>` elements to skip.
- `debian-xjetty`: `xwiki-xjetty-common` gives `xwiki.service`. The port is `JETTY_PORT` in the
  unit's environment, or `-p` in its `ExecStart`, and 8080 otherwise. The context path is always
  `/xwiki`. `xjetty-web.xml` holds neither.
- `war`: no detection. It requires `UNIT` (or `START_CMD` + `STOP_CMD` + `PID_FILE`), `WEBAPP_DIR`,
  `BASE_URL`, and optionally `LOG_FILE`.

The `container` profile is part of [Phase 4](phase-4-containers.md), where the official image is
there to test it against.

Common fillers, used by all profiles:
- `PERMDIR` from `xwiki.properties`.
- DB type and connection from `hibernate.cfg.xml`. The parser must handle the multi-line comments
  that the Debian templates use; it takes the **un-commented** `connection.url`.
- The version from `META-INF/extension.xed`.
- The JVM PID from `systemctl show -p MainPID`, checked to be a `java` process, else unknown.
  `MainPID` is the JVM for Tomcat and for xjetty.

`xinit layout [--format json]` prints every key with its **source**: detected, config or default.

### 1.3 Checks (read-only, done)
`process`, `http`, `rest`, `oom`, `db`, `disk`. The statuses, reasons and metrics of each one are
in [../checks.md](../checks.md).

- `http`:
  - Uses a curl argv array. Credentials come from a netrc file (`--netrc-file`). Redirects are not
    followed. TLS verification is on unless `HTTP_INSECURE=yes`.
  - Results: code ∈ `HTTP_EXPECT`, total time vs `HTTP_SLOW` (warn) and `HTTP_TIMEOUT` (crit).
  - A redirect to `/bin/distribution/` gives warn `wizard`. A fresh XWiki 18.9.0 answers
    `302` with `Location: …/bin/distribution/XWiki/Distribution?xredirect=…` to every page
    request. It does not redirect REST requests.
  - A starting wiki is not a failure, so that it is not restarted (Phase 2). A restarted XWiki
    18.9.0 first refuses connections, then accepts them without answering while Tomcat deploys
    the webapp, then answers `202` with the page "XWiki is initializing (N%)", then `200`.
    - `202` gives warn `initializing`.
    - Refused connections and timeouts give warn `starting` while the JVM is younger than
      `STARTUP_GRACE` (300 s), and crit after.
  - DNS failure (curl exit 6) gives `unknown`, not crit (XINIT-5).
- `rest`: `/rest/` answers as the REST API. A running version that differs from the installed one
  gives warn `restart-pending`.
- `oom`:
  - `java.lang.OutOfMemoryError` in the unit's journal since the JVM started is crit `heap`.
  - A kill by the kernel's OOM killer is warn `kernel`, and not crit: systemd has usually
    restarted XWiki by then, and a restart does not fix the memory settings. It is recognised
    by the unit's control group in the kernel's message, or by systemd's own message.
  - Both look back `OOM_WINDOW` seconds at most (1 hour).
- `db`: PostgreSQL, MySQL and MariaDB (XINIT-10).
  - It first opens a connection to the database's port. This needs no client and no password
    (XINIT-11), and tells a database that is down.
  - With a 0600 credentials file (`.pgpass` / `my.cnf`) and `psql` / `mariadb` / `mysql`, it also
    logs in and runs `SELECT 1`. `xinit setup` will create that file from `hibernate.cfg.xml`
    (Phase 2).
- `disk`: free space and free inodes of the permanent directory's file system, in percent, with
  the thresholds `DISK_WARN` and `DISK_CRIT`.

Not ported from 1.3, by decision: the JVM memory options (XINIT-24: xinit no longer sets any), the
OpenOffice server (XINIT-28) and the MySQL spam detection (XINIT-29).

### 1.4 Tests (done)
- Unit tests (bats): the parser, the renderers, each profile against the fixtures (real files
  copied from the images), and each check against stubbed `curl`/`systemctl`/`journalctl`/`df`
  and database clients.
- Integration tests: `20-layout.bats` and `30-check.bats` hold the scenarios of
  [../TESTING.md](../TESTING.md) marked Phase 1. They run on each image variant.

## Acceptance
- `xinit layout` is correct with **zero configuration** on `tomcat10/11-*` and `xjetty-*`, and
  with three lines of configuration on the WAR variant. **Met**, on the five local variants.
- `xinit check --format nagios` can be used directly as a Nagios/Icinga plugin. **Met.**
- No command in this phase writes anything. **Met**: the integration tests run `xinit layout` and
  `xinit check` with every file system read-only.

Verified on the five local variants (cgroup v1): `tomcat10-pgsql`, `tomcat11-mariadb`,
`xjetty-pgsql`, `war-tomcat10-pgsql` and `tomcat10-mariadb-lts-debian12`. Each one ran the whole
integration suite: 41 tests, of which 3 or 4 are skipped because they are for another kind of
installation, or are S-HTTP-04. Every xinit scenario passed. Two tests of the fault library failed
for reasons in the tests themselves; they were fixed, and rerun with the scenarios that use them.

Still to verify, once the workflows are on the default branch: `tomcat10-mysql-ubuntu2604`, and
cgroup v2. On cgroup v2, systemd reports an out-of-memory kill itself, and the oom check reads
that message: its unit test uses a hand-written line, not a capture.
