# Xinit 2 — Design

Status: **proposal** (to be validated before Phase 1 starts). It replaces the 1.3.x code base. The
`rework-systemd-xjetty-tomcat10` branch is not a base: a few of its ideas are reused, listed in
[Reused from the rework branch](#reused-from-the-rework-branch).

## 1. Goals

Xinit monitors **one or more XWiki instances**. It reports on their health and, when allowed, fixes
them. It must work for:

| Install type | How XWiki runs | What xinit can do |
|---|---|---|
| **Debian/Ubuntu package, Tomcat** (`xwiki-tomcat{9,10,11}-*`) | `tomcatN.service`, plus the drop-in `xwiki-tomcatN-systemd.conf` | everything |
| **Debian/Ubuntu package, Jetty** (`xwiki-xjetty-*`) | `xwiki.service` | everything |
| **WAR** in any servlet container (distribution Tomcat, a tarball Tomcat or Jetty, any distro) | a systemd unit the admin names, or start/stop commands | everything, once the admin declares the unit, webapp directory and log location |
| **Container: in the XWiki container** | PID 1 is the servlet container, there is no systemd | checks and diagnostics only; the orchestrator restarts |
| **Container: sidecar** | a separate container in the same pod or compose project | HTTP and DB checks; JVM diagnostics if the PID namespace is shared |

Non-goals:
- Installing XWiki or the servlet container.
- Replacing the init system. systemd restarts a dead process better than any poller.
- Replacing a full monitoring stack. Xinit plugs into Nagios and Prometheus; it does not replace them.

## 2. Principles

1. **Use the platform, don't re-implement it.**
   - Process supervision belongs to systemd (`Restart=on-failure`, `OnFailure=`).
   - Logs come from journald, or from the declared log file.
   - Scheduling uses systemd timers, with cron only as a fallback.
   - Restricted restart rights use polkit.
   - Secrets use systemd credentials or 0600 files.
   - Thread dumps use `jcmd` when it is there. The XWiki Debian packages only pull in a JRE, which
     has no `jcmd`; then xinit uses `kill -3` and reads the dump from the journal or the declared
     log, in the window between before and after the signal.
2. **Checks are read-only. Actions are separate and explicit.**
   - `xinit check` never changes anything.
   - `xinit watch`, run by the timer, is the only command that decides to act, and only within a
     restart policy: N consecutive failures, a cooldown, maintenance mode, and a lock.
3. **Describe the install, then act on the description.**
   - Detection produces a *layout*: the unit, webapp dir, permanent dir, config dir, logs, DB, URL
     and Java.
   - Every key can be overridden in the configuration.
   - `xinit layout` prints the result, so a wrong guess is visible and can be fixed in one line.
   - No code path greps for paths on its own.
4. **Machine-readable first.** Every check has a stable id, a status (`ok`/`warn`/`crit`/`unknown`),
   a message and metrics. The same result is rendered as text, JSON, Nagios, Prometheus textfile or
   a container health exit code.
5. **Never modify files owned by packages.**
   - Configuration goes into drop-ins (`/etc/systemd/system/<unit>.d/50-xinit.conf`) or into xinit's
     own files.
   - Everything is reversible with `xinit setup --undo`.
6. **Safe by default.**
   - No passwords on command lines.
   - No world-readable reports.
   - No `eval` of configuration values; the configuration is parsed, not sourced.
   - No `--insecure` unless the admin configures it.
   - `--location-trusted` is never used.
7. **Portable Bash.**
   - Bash ≥ 4.4, coreutils, `curl`, `awk`; `ss` from iproute2.
   - Optional tools: `jcmd` (comes with the JDK), `psql`/`mariadb`/`mysql`, `systemctl`,
     `journalctl`, a mail transport (`sendmail`-compatible).
   - Each optional feature degrades with a clear `unknown` result when its tool is missing.

## 3. Architecture

```
            ┌──────────── xinit (CLI, /usr/bin/xinit) ────────────┐
            │ check | watch | report | layout | setup | maint ... │
            └───────────────┬─────────────────────────────────────┘
                            │ sources only what the command needs
  lib/core.sh     config parsing, logging, locking, state, output renderers
  lib/layout.sh   detection + overrides  →  the layout (associative array)
  lib/profiles/   debian-tomcat.sh  debian-xjetty.sh  war.sh  container.sh
  lib/checks/     http.sh  process.sh  jvm.sh  db.sh  disk.sh  xwiki.sh  oom.sh ...
  lib/actions.sh  restart (systemctl / custom command), maintenance, warmup
  lib/report.sh   diagnostics bundle (jcmd, journal, ss, DB activity, disk, config summary)
  lib/notify/     mail.sh  webhook.sh  journal.sh
```

### 3.1 Instances

An **instance** is one monitored XWiki.
- Its config is `/etc/xinit/instances/<name>.conf`. The default instance `default` may also be
  configured in `/etc/xinit/xinit.conf`.
- Its state is in `/var/lib/xinit/<name>/` (failure counters, last results, reports).
- Every command takes `-i <name>`. With one instance there is nothing to type.

This covers XINIT-2 (several XWiki instances on one host) from day one.

### 3.2 Profiles and the layout

A profile has two functions:
- `detect` returns a confidence score.
- `fill` sets layout keys it can derive.

The highest-scoring profile wins, unless `PROFILE=` is set. Detection sources:
- package database: `dpkg-query -W` / `rpm -q`;
- `systemctl show <unit> -p MainPID,FragmentPath,DropInPaths,Environment,ExecStart`;
- the Tomcat context file (`docBase`) / Jetty web xml;
- `/proc/<pid>/cmdline` and `/proc/<pid>/environ` for the JVM.

| Layout key | Debian Tomcat | Debian xjetty | WAR (admin declares) | Container |
|---|---|---|---|---|
| `UNIT` | `tomcatN.service` | `xwiki.service` | required (or `START_CMD`/`STOP_CMD`) | none |
| `WEBAPP_DIR` | `/usr/lib/xwiki` (from `docBase`) | `/usr/lib/xwiki` | required | `/usr/local/tomcat/webapps/ROOT` (official image) |
| `CONFIG_DIR` | `/etc/xwiki` | `/etc/xwiki` | `$WEBAPP_DIR/WEB-INF` | `$WEBAPP_DIR/WEB-INF` |
| `PERMDIR` | from `xwiki.properties` `environment.permanentDirectory` (`/var/lib/xwiki/data`) | same | same | `/usr/local/xwiki/data` |
| `LOG_SOURCE` | `journal:tomcatN.service` | `journal:xwiki.service` / `/var/log/xwiki/*.jetty.log` | declared | container stdout |
| `JVM_PID` | `systemctl show -p MainPID` | same | same, else from a pid file | PID of `java`, or via a shared PID namespace |
| `BASE_URL` | `http://localhost:8080/xwiki` (port from `server.xml`) | from the Jetty config | required | `http://localhost:8080` |
| `DB_TYPE`/`DB_*` | parsed from `hibernate.cfg.xml` (active, un-commented block) | same | same | env vars `DB_HOST`… or `hibernate.cfg.xml` |

The XWiki version comes from `WEB-INF/../META-INF/extension.xed`, or from the REST root
(`/rest/`) when the webapp isn't on disk (sidecar). `version.properties` no longer exists in 18.x.

### 3.3 Checks

| id | What | Default |
|---|---|---|
| `process` | the unit is active and its MainPID is a JVM; uptime | on (off in sidecar) |
| `http` | `BASE_URL` (or `CHECK_URLS`): code ∈ expected, total time < threshold; detects the Distribution Wizard redirect and the "XWiki is initializing" page | on |
| `rest` | `/rest/` answers and reports the expected version | on |
| `jvm` | via `jcmd`: heap usage after GC, GC time ratio, thread count, deadlocks | on if `jcmd` and the PID are reachable |
| `oom` | heap OOM in recent logs (time-bounded); kernel OOM-kill of *this* JVM (`journalctl -k --since`) | on |
| `db` | connect + trivial query with credentials from a 0600 file; connection count vs the pool limit | on if a client is installed |
| `disk` | free space on the permanent dir, the DB data dir and the log dir | on |
| `solr` | embedded Solr core sizes / remote Solr ping | later |
| `config` | the 1.3 `check-install` checks rewritten: `hibernate.cfg.xml` readable by all users (the Debian package installs it 0644 with the DB password), encoding, short URLs coherence, superadmin enabled (warn), `xwiki.cfg` secrets left at default | on demand (`xinit check --deep`) |

A check function receives the layout. It returns one or more result lines
(`id|status|message|metric=value...`) and never exits the process.

### 3.4 Actions and the restart policy

`xinit watch` (timer, every minute by default):
1. Takes `flock /run/xinit/<instance>.lock`. If another run holds it, it exits.
2. Runs the checks marked `ACT_ON` (default `http process`).
3. Updates the failure counters in the state dir.
4. If a check has been `crit` for `RESTART_AFTER` consecutive runs (default 3), and there is no
   maintenance and no cooldown, it does:
   1. build the diagnostics report **before** restarting, since thread dumps must be taken while it hangs;
   2. send a notification;
   3. `systemctl restart <UNIT>` (or `RESTART_CMD`);
   4. enter `COOLDOWN` (default 15 min, the old `MAINTENANCE_TIME`).
5. If there are more than `MAX_RESTARTS` within `MAX_RESTARTS_WINDOW`, it stops acting and sends an
   escalation ("flapping") mail.

Container mode never restarts. `xinit check --health` exits 0 or 1 for `HEALTHCHECK` or a probe;
the orchestrator owns restarts.

**Maintenance** has an expiry: `xinit maint on [--for 2h] [--reason …]`, `off`, `status`. The
expiry epoch is stored in the state file, so a forgotten maintenance ends by itself.

**Warm-up** (XINIT-14) is `xinit-warmup@<instance>.service`. It is ordered after the servlet unit
and `PartOf` it. It requests `WARMUP_URLS`, one URL per subwiki, without blocking the servlet
unit's start.

### 3.5 Diagnostics report

`xinit report [--send]` writes `/var/lib/xinit/<instance>/reports/<ts>.tar.gz`. The file is mode
0600, and only the last `REPORT_KEEP` reports are kept. It contains:
- layout and config summary, with secrets redacted;
- check results;
- thread dumps, 3 times, 5 s apart: `jcmd Thread.print -l` when available, otherwise `kill -3`
  plus the journal or log; with `jcmd`, also `GC.heap_info`, `VM.flags` and `VM.system_properties`
  with secrets redacted;
- the last N lines of the journal / log;
- `ss -tanp` summary per port;
- DB activity (`pg_stat_activity` / `SHOW FULL PROCESSLIST`), with query text optional;
- disk usage;
- top threads by CPU (`top -H -p`, mapped to the thread dump's `nid`).

A mail carries a text summary (wrapped lines) plus the bundle when it is small enough. Webhooks
carry the summary only.

### 3.6 systemd integration (`xinit setup`)

`xinit setup` generates, and `xinit setup --undo` removes:
- `/etc/systemd/system/<UNIT>.d/50-xinit.conf`:
  - `Restart=on-failure`, `RestartSec=10`;
  - `OnFailure=xinit-notify@%n.service`, which mails a crash report the moment systemd sees the
    process die (no polling delay);
  - optional JVM options (`JAVA_OPTS` additions such as heap or agents). These are **appended** to
    the package's environment, never replacing it, and `%` is escaped.
- `xinit-watch@<instance>.timer` / `.service`: a `Type=oneshot` service that runs as the `xinit`
  user with hardening (`ProtectSystem=strict`, `StateDirectory=xinit`, `LoadCredential=` for
  secrets).
- A polkit rule letting the `xinit` user `restart` only `<UNIT>`, so that xinit runs without root
  (XINIT-15).
- `xinit-warmup@<instance>.service`.

Without systemd (containers, some WAR installs), it installs a cron file (`/etc/cron.d/xinit`)
instead. Its locking and state are the same.

### 3.7 Configuration

```
/etc/xinit/xinit.conf               # global + default instance, KEY=value, parsed (not sourced)
/etc/xinit/instances/<name>.conf    # per instance
/etc/xinit/credentials/<name>.*     # 0600: db.cnf / .pgpass / http.netrc — or systemd credentials
```

- Unknown keys are reported as warnings, so typos are caught.
- `xinit config check` validates the configuration.
- `xinit config migrate /etc/xinit/xinit.cfg` translates 1.3 keys: `CHECK_HTTP_URL`→`BASE_URL`,
  `EXPECT_HTTP_RESPONSE_CODE`→`HTTP_EXPECT`, `MAIL`, `MAINTENANCE_TIME`→`COOLDOWN`, and so on.
- `MEM_START`/`MEM_MAX`/`MAX_PERM_SIZE` are reported as obsolete, with a hint.

### 3.8 Output and integrations

`--format text|json|nagios|prom`.
- `nagios` replaces `nagios-info`, following the plugin exit-code convention.
- `prom` writes `xinit_check_status{instance,check}` and the metrics to the node_exporter textfile
  directory, when `PROM_TEXTFILE_DIR` is set.

## 4. Repository layout (target)

```
bin/xinit
lib/xinit/{core,layout,actions,report}.sh  lib/xinit/{profiles,checks,notify}/*.sh
share/xinit/sql/{sanity-pg,sanity-my}.sql
systemd/{xinit-watch@.service,xinit-watch@.timer,xinit-notify@.service,xinit-warmup@.service}
etc/xinit.conf.example  polkit/50-xinit.rules.in  cron/xinit
container/Dockerfile.sidecar  container/examples/{compose.yaml,k8s.yaml}
tests/unit/*.bats  tests/integration/*.bats  tests/env/   tests/fixtures/
docs/
Makefile   (install with PREFIX/DESTDIR, lint, test)
```

The Maven build (`pom.xml`, `Jenkinsfile`) stays: XWiki's CI and release process use it. Its
assembly then packages the tree above.

## 5. Reused from the rework branch

The idea of putting the systemd configuration in a drop-in, auto-expiring maintenance, appending
JVM agents and their `ReadWritePaths`, the `ss` port helper, wrapping long mail lines (`fold`),
`sanitycheck-pg.sql`, and a curl argument array run with `LC_ALL=C`.

**Not reused:**
- `dpkg -l | grep` detection (it uses the wrong package names);
- `pgrep` PID fallbacks;
- xinit's own `xwiki.service` (it collides with the xjetty unit);
- `CATALINA_PID`;
- hardening on by default;
- passwords in argv;
- reports in `/var/tmp`;
- `update.sh`.

## 6. Open questions

1. Minimum supported distros. Proposal: Debian 12/13 and Ubuntu 24.04 (tested in CI); RHEL 9
   family with tarball Tomcat as WAR (tested in Phase 5).
2. Is Jabber/XMPP still wanted? Proposal: drop it and use the generic webhook (Matrix, Mattermost,
   Slack).
3. Should OpenOffice/LibreOffice monitoring stay? XWiki now starts and stops its own LibreOffice
   server. Proposal: an optional `office` check (port answering), with no start/stop.
4. Spam detection (MySQL-only in 1.3): keep as `xinit db spam-report` for both MySQL and PostgreSQL,
   or drop it?
