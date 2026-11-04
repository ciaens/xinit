# Phase 1 — Detection and read-only checks

Goal: `xinit layout` and `xinit check` are correct on every supported install type, **without
changing anything** on the host. This alone is useful: you can run it from Nagios, from a container
`HEALTHCHECK`, or by hand.

## Tasks

### 1.1 Core (`lib/xinit/core.sh`)
- Config parser: `KEY=value` with optional quotes, `#` comments, no command substitution or
  expansion. Layering: built-in defaults < `xinit.conf` < `instances/<name>.conf` < `XINIT_*`
  environment < CLI flags. Unknown keys produce a warning.
- Instance resolution: `-i <name>`, defaulting to `default` when only one instance exists.
- Logging to stderr and the journal (`systemd-cat`/`logger` when available). There is no
  `/var/log/xinit.log` by default; it can be enabled with `LOG_FILE`.
- Result model and renderers: `text`, `json`, `nagios`. Exit codes:
  0 ok, 1 warn, 2 crit, 3 unknown (Nagios convention).

### 1.2 Layout and profiles
Profiles, in detection order:
- `debian-tomcat`: `dpkg-query -W 'xwiki-tomcat*-common'` gives N, then `tomcatN.service`.
  `WEBAPP_DIR` comes from `docBase` in `/etc/tomcatN/Catalina/localhost/*.xml` and the context path
  from the file name (`xwiki.xml` → `/xwiki`, `ROOT.xml` → `/`). The port comes from
  `/etc/tomcatN/server.xml`.
- `debian-xjetty`: `xwiki-xjetty-common` gives `xwiki.service`. Its paths come from the unit
  (`systemctl cat xwiki.service`) and `/etc/xwiki/xjetty-web.xml` / `jetty-web.xml`.
- `war`: no detection. It requires `UNIT` (or `START_CMD` + `STOP_CMD` + `PID_FILE`), `WEBAPP_DIR`,
  `BASE_URL`, and optionally `LOG_FILE`.
- `container`: `/.dockerenv`, `container=` env or cgroup hints, *and* no systemd as PID 1.
  Defaults to the official image paths.

Common fillers, used by all profiles:
- `PERMDIR` from `xwiki.properties`.
- DB type and connection from `hibernate.cfg.xml`. The parser must handle the multi-line comments
  that the Debian templates use; it takes the **un-commented** `connection.url`.
- The version from `META-INF/extension.xed`.
- The JVM PID from `systemctl show -p MainPID`, checked to be a `java` process, else unknown.

`xinit layout [--format json]` prints every key with its **source**: detected, config or default.

### 1.3 Checks (read-only)
`process`, `http`, `rest`, `oom` (logs only, time-bounded), `db`, `disk`.

- `http`:
  - Uses a curl argv array. Basic auth comes from a netrc file (`--netrc-file`). It never uses
    `--location-trusted`. TLS verification is on unless `HTTP_INSECURE=yes`.
  - Results: code ∈ `HTTP_EXPECT`, total time vs `HTTP_SLOW` (warn) and `HTTP_TIMEOUT` (crit).
  - A redirect to `/bin/distribution/` gives warn "Distribution Wizard pending".
  - The initialization page (verify which code and marker XWiki 18 uses while starting) gives
    warn "initializing", not crit. That way a starting wiki is not restarted.
  - DNS failure (curl exit 6) gives `unknown`, not crit (XINIT-5).
- `db`: PostgreSQL and MySQL/MariaDB through `psql`/`mariadb`/`mysql`, with credentials from a 0600
  `db.cnf`/`.pgpass` that `xinit setup` can create from `hibernate.cfg.xml` (Phase 2). Without a
  client or credentials the result is `unknown`, not an error (XINIT-11).
- `disk`: free % and free bytes, with thresholds.

### 1.4 Tests
- Unit tests (bats): parser, renderers, each profile's `detect`/`fill` against fixtures (real config
  files copied from the packages), and each check against stubbed `curl`/`systemctl`/`psql`.
- Integration tests: for each image variant, `layout` matches the expected keys, and `check` is all
  `ok` on a healthy instance. Each scenario from [../TESTING.md](../TESTING.md) marked Phase 1 gives
  the expected status.

## Acceptance
- `xinit layout` is correct with **zero configuration** on `tomcat9/10/11-*` and `xjetty-*`, and
  with three lines of configuration on the WAR variant.
- `xinit check --format nagios` can be used directly as a Nagios/Icinga plugin.
- No command in this phase writes outside `/var/lib/xinit` or `/run/xinit` (checked in the
  integration tests by comparing a file list before and after).
