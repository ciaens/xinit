# Testing xinit

There are three test layers. All run through one command, `tests/run.sh`, which writes a
machine-readable summary. The layers:

| Layer | What | Where | Needs | Time |
|---|---|---|---|---|
| **lint** | `shellcheck -x -S warning` on the new tree (`bin/`, `lib/`) and the tests | host | shellcheck | seconds |
| **unit** | functions in isolation; external commands (`systemctl`, `curl`, `dpkg-query`, `psql`, `jcmd`) are fakes on `PATH`; inputs are real files from `tests/fixtures/` | host | bats | seconds |
| **integration** | xinit against a real XWiki in a systemd container, with faults injected | host → `docker exec` | bats, Docker, the test image | minutes |

`xinit-application/` (1.3.x) is not linted or tested. It is legacy and is replaced in Phase 5.

## Running

```bash
tests/run.sh                                        # lint + unit + integration on tomcat10-pgsql
```

```bash
tests/run.sh --suite lint --suite unit              # fast, no Docker
```

```bash
tests/run.sh --suite integration --variant tomcat10-pgsql --variant xjetty-pgsql
```

```bash
tests/run.sh --suite integration --filter 'S-HTTP' --reuse xinit-tomcat10-pgsql   # iterate on one area
```

- A missing image is built first. That takes about 10 minutes, once per variant; see
  [test-env.md](test-env.md).
- Each integration run uses a **fresh container** that is removed afterwards. Pass `--keep` to keep
  it, or `--reuse NAME` to run in a container you already started (faster, but state from earlier
  runs may leak into it).
- Behind an HTTPS-intercepting proxy, export `XINIT_TEST_CA` (see test-env.md).

### Results

`tests/results/<UTC timestamp>/` (git-ignored) contains:

- `summary.json`: **the file to read**.
  ```json
  {"overall":"failed","commit":"8c6a102","date":"…","results":[
    {"suite":"lint","status":"passed","passed":4,"failed":0,"skipped":0,"failures":[],"tap":"lint.tap"},
    {"suite":"integration-tomcat10-pgsql","status":"failed","passed":15,"failed":1,"skipped":6,
     "failures":["S-PROC-02 hung JVM is restarted once"],"tap":"integration-tomcat10-pgsql.tap"}]}
  ```
- `<suite>.tap`: the TAP stream, with timings. A failing test's diagnostics are the `#` lines under
  its `not ok` line.
- `<suite>.log` and `build-<variant>.log`: stderr of the tools.
- `journal-<variant>.log`: the container's whole journal (servlet container, database, xinit units).

The exit code is 0 when everything passed, 1 when a test failed, and 2 on a setup error: no bats,
no Docker, the image build failed, and so on.

## Procedure for an agent

Use this when asked to test xinit, or to verify a change.

1. Run `tests/run.sh --suite lint --suite unit`, and fix what fails before going further.
2. Run `tests/run.sh --suite integration` on the default variant. Add `--variant` for the variants
   the change touches: a profile change means that profile's variants, and a check change means at
   least one Tomcat and one xjetty variant.
3. Read `summary.json`. For each failure:
   - read its block in the `.tap` file;
   - then read `journal-<variant>.log` around the failure's time;
   - decide whether it is an xinit bug, a test bug, or an environment problem (image, network,
     host).
   - Never "fix" a failure by weakening the assertion, or by skipping the test without saying so.
4. Report:
   - the overall result and the commit;
   - the variants run;
   - each failure, with its scenario id, the cause and the evidence (log excerpt);
   - every test skipped because its phase is not implemented, counted, not listed.
5. Leave no containers behind, unless asked: run `tests/env/xwiki-env.sh list`.

`00-env.bats` checks the instance itself: the unit is active, there's no Distribution Wizard, and
the accounts work. **If it fails, no other result is meaningful.** Report an environment problem
instead.

## Writing tests

- File naming:
  - `00-env.bats` is the baseline;
  - `10-faults.bats` tests the fault library;
  - `<NN>-<area>.bats` holds xinit scenarios (`20-layout`, `30-check-http`, `40-watch`…).
- Each xinit scenario test starts with its scenario id from the catalogue below, for example
  `@test "S-HTTP-03 slow answer is warn, not crit"`, so that `--filter S-HTTP` selects an area.
- A scenario whose phase is not implemented yet calls `skip "Phase N"` as its first line. It is
  written as soon as the scenario is agreed, so the catalogue and the tests cannot drift apart.
- Every fault has a heal. `teardown` calls `heal_all`, so that a failing test doesn't break the
  next one.
- Assert on **xinit's machine output** (`--format json`, its exit code, files in its state dir),
  never on human-readable text.
- Integration helpers are in `tests/integration/helpers.bash`:
  - `in_env`, `in_env_sh`: run in the container;
  - `http_code`, `wait_http`, `wait_healthy`: query XWiki from inside the container;
  - `jvm_pid`: the unit's MainPID when it is a java process;
  - the `fault_*` and `heal_*` functions below.

## Fault library

Each fault is verified by `10-faults.bats`, with no xinit involved.

| Fault | Injection | Symptom | Heal |
|---|---|---|---|
| slow page | fault page `?action=sleep&ms=N` | answers after N ms | — |
| HTTP status | fault page `?action=status&code=N` | answers N | — |
| frozen JVM | `kill -STOP <MainPID>` | requests time out (000), the process is still "active" | `kill -CONT` |
| killed JVM | `kill -9 <MainPID>` | connection refused, then systemd restarts it (the package unit has `Restart=on-abort`) | automatic |
| stopped unit | `systemctl stop <unit>` | connection refused, unit inactive | `systemctl start` |
| DB down | `systemctl stop postgresql\|mariadb` | XWiki answers errors | `systemctl start` |
| DB auth | wrong password in `hibernate.cfg.xml` + restart | XWiki never becomes healthy | restore the file + restart |
| deadlock | fault page `?action=deadlock` | `Found one Java-level deadlock` in a thread dump | restart |
| heap OOM | drop-in `JDK_JAVA_OPTIONS=-Xmx768m` + fault page `?action=hog&mb=100` ×8 | `java.lang.OutOfMemoryError` in the journal | remove the drop-in + restart |
| kernel OOM | drop-in `MemoryMax=1200M` + `JDK_JAVA_OPTIONS=-Xmx4g` + hog | the kernel's `oom-kill` message in the journal, then the JVM is restarted. systemd did not report the unit's result as `oom-kill` on the cgroup v1 host where this was verified | remove the drop-in + restart |

Two facts the faults (and xinit) depend on:
- JVM options go through `JDK_JAVA_OPTIONS`, which the `java` launcher reads itself. A `JAVA_OPTS`
  set in the unit is overridden by the Tomcat start script, which sources `/etc/default/tomcatN`.
- Without `-Xmx` the JVM sizes its heap from the cgroup limit (25%), so a memory limit alone gives
  a heap OOM, not a kernel OOM kill.

A cached page is still served while the database is down. Probes that must reach the database
request a page that was never loaded.

The fault page (`XinitTest.Faults`) is a Groovy page created at test time by `install_fault_page`
(Admin has programming rights). It is not part of the image.

Faults that depend on configuration rather than injection:
- disk space: a threshold above the current usage;
- DNS failure: a `BASE_URL` with an unresolvable host;
- TLS: a self-signed HTTPS front.

These are set up by the scenario itself.

## Scenario catalogue

What xinit must do. **Phase** is when the scenario becomes a required test. Expected results use
DESIGN.md's statuses and exit codes: 0 ok, 1 warn, 2 crit, 3 unknown.

### Layout and detection: `20-layout.bats`
| Id | Phase | Setup | Expected |
|---|---|---|---|
| S-LAYOUT-01 | 1 | each Debian variant, no xinit config | `xinit layout --format json` has the right `PROFILE`, `UNIT`, `WEBAPP_DIR=/usr/lib/xwiki`, `CONFIG_DIR=/etc/xwiki`, `PERMDIR=/var/lib/xwiki/data`, `BASE_URL`, `DB_TYPE`, `VERSION` (= `dpkg-query` of `xwiki-common`) |
| S-LAYOUT-02 | 1 | `UNIT=` / `BASE_URL=` set in config | config value wins; `source` is `config` |
| S-LAYOUT-03 | 1 | WAR variant, three config lines | complete layout |
| S-LAYOUT-04 | 1 | XWiki served at `/` (ROOT.xml) | `BASE_URL` has no `/xwiki` |
| S-LAYOUT-05 | 1 | unit stopped | layout still resolves; `JVM_PID` empty, not an error |
| S-LAYOUT-06 | 1 | unknown key in config | warning naming the key; exit 0 |

### Read-only checks: `30-check.bats`
| Id | Phase | Setup | Expected |
|---|---|---|---|
| S-CHECK-00 | 1 | healthy instance | every check `ok`, exit 0; no file changed outside `/var/lib/xinit`, `/run/xinit` (compared with a file list) |
| S-PROC-01 | 1 | stopped unit | `process` crit |
| S-PROC-03 | 1 | frozen JVM | `process` ok (still running), `http` crit |
| S-HTTP-01 | 1 | stopped unit | `http` crit, connection refused in the message |
| S-HTTP-02 | 1 | `BASE_URL` → fault page `status&code=503` | `http` crit, code 503 |
| S-HTTP-03 | 1 | fault page `sleep` > `HTTP_SLOW` and < `HTTP_TIMEOUT` | `http` warn, duration in the metrics |
| S-HTTP-04 | 1 | the Distribution Wizard redirect (set `distribution.automaticStartOnMainWiki=true` on a wiki without a flavor; a dedicated fresh-install variant may be needed) | `http` warn "Distribution Wizard pending" |
| S-HTTP-05 | 1 | right after a restart | `http` warn "initializing", not crit |
| S-HTTP-06 | 1 | `BASE_URL` host does not resolve | `http` unknown (DNS), not crit |
| S-HTTP-07 | 1 | basic auth through a netrc file | ok; the password is not in `ps` output during the check |
| S-REST-01 | 1 | healthy | `rest` ok, version = the package version |
| S-DB-01 | 1 | DB down | `db` crit |
| S-DB-02 | 1 | no DB client installed / no credentials | `db` unknown, others unaffected |
| S-DISK-01 | 1 | `DISK_WARN` above the current usage | `disk` warn |
| S-OOM-01 | 1 | heap OOM fault | `oom` crit "heap" |
| S-OOM-02 | 1 | heap OOM fault, then restart | `oom` ok (OOM older than the last start) |
| S-OOM-03 | 1 | kernel OOM fault | `oom` crit "kernel" |
| S-FMT-01 | 1 | any | `--format json` parses; `--format nagios` first line `XINIT <STATUS> - …` and exit code matches |

### Acting: `40-watch.bats`
| Id | Phase | Setup | Expected |
|---|---|---|---|
| S-PROC-02 | 2 | `xinit setup`, then killed JVM | systemd restarts it; `xinit-notify@` ran once (journal); no `xinit watch` restart |
| S-WATCH-01 | 2 | frozen JVM, `RESTART_AFTER=3` | runs 1–2 only count; run 3 stores a thread dump, restarts once, sets cooldown |
| S-WATCH-02 | 2 | still frozen during cooldown | no second restart |
| S-WATCH-03 | 2 | maintenance on | no restart; failures recorded |
| S-WATCH-04 | 2 | maintenance `--for 1m`, wait | maintenance off by itself |
| S-WATCH-05 | 2 | DB auth fault (permanent) | ≤ `MAX_RESTARTS` restarts, then a flapping escalation, then no more restarts |
| S-WATCH-06 | 2 | two `xinit watch` at once | one runs, the other exits on the lock |
| S-WATCH-07 | 2 | healthy for N runs | counters reset, nothing restarted |
| S-SETUP-01 | 2 | `setup` then `setup --undo` | `systemctl cat <unit>` identical to before; no file left from the manifest |
| S-SETUP-02 | 2 | `setup` with `JVM_OPTS_APPEND` | the JVM command line has both the package options and the added ones |
| S-SETUP-03 | 2 | watch timer | runs as user `xinit`; restart allowed by polkit for `<unit>` only (restarting another unit is refused) |
| S-WARMUP-01 | 2 | `WARMUP_URLS` with two URLs | both requested after each start (access log) |
| S-SEC-01 | 2 | after any scenario | no xinit file world-readable; no password in `/proc/*/cmdline` captured during runs |

### Diagnostics and notifications: `50-report.bats`
| Id | Phase | Setup | Expected |
|---|---|---|---|
| S-REPORT-01 | 3 | healthy | bundle 0600, has layout, results, thread dump, journal excerpt, DB activity |
| S-REPORT-02 | 3 | any | no test password (DB, `Admin`'s, netrc) appears anywhere in the bundle |
| S-REPORT-03 | 3 | deadlock fault | the summary names the deadlock |
| S-REPORT-04 | 3 | 30 concurrent requests on a slow page | summary of the most frequent URLs across request threads lists the slow page first |
| S-REPORT-05 | 3 | no `jcmd` (Debian packages ship a JRE) | thread dump taken through `SIGQUIT` and read from the journal |
| S-NOTIFY-01 | 3 | S-WATCH-01 with a local MTA | one mail; the subject has the instance and the check; lines ≤ 900 chars |
| S-NOTIFY-02 | 3 | heap OOM + restart | the subject has `[OOM]` |
| S-NOTIFY-03 | 3 | webhook to a local listener | one POST, valid JSON |
| S-NOTIFY-04 | 3 | the same failure twice within `NOTIFY_REPEAT` | one notification |
| S-PROM-01 | 3 | `PROM_TEXTFILE_DIR` set | valid exposition format (`promtool check metrics` when available) |

### Containers: `60-container.bats` (Phase 4; uses the official `xwiki` image, not the systemd test image)
| Id | Phase | Setup | Expected |
|---|---|---|---|
| S-CONT-01 | 4 | xinit inside the official image | `check --health` exit 0; no `systemctl` attempted |
| S-CONT-02 | 4 | frozen JVM | `check --health` exits 1 within the timeout |
| S-CONT-03 | 4 | sidecar with a shared PID namespace | report holds a thread dump |
| S-CONT-04 | 4 | network-only sidecar | http/rest/db checks only, the others `unknown` |
| S-CONT-05 | 4 | just started | the grace period: not unhealthy while starting |

### Packaging and migration: `70-install.bats`
| Id | Phase | Setup | Expected |
|---|---|---|---|
| S-INST-01 | 5 | `make install DESTDIR=…` | exact file list; no write outside DESTDIR |
| S-INST-02 | 5 | `.deb` install, then purge | user, units, polkit rule created, then removed; `/etc/xinit` kept on remove, removed on purge |
| S-MIG-01 | 5 | 1.3.3 installed with its `install.sh` | `config migrate` + `setup --migrate`: same monitoring settings, 1.3 init script and cron disabled |
