# Phase 2 — Acting safely

Goal: xinit fixes a broken or hung XWiki on a host with systemd, without restart loops and without
needing root for the periodic job.

## Carried over from Phase 1

What Phase 1 built or found, that this phase has to use:
- A check result has a `reason` ([../checks.md](../checks.md)). The restart policy decides on the
  status **and** the reason. Results that must never cause a restart:
  - any `unknown`, and any `warn` (`starting`, `initializing`, `wizard`, `slow`, `kernel`);
  - `db` failures: restarting XWiki does not repair its database.
- The `xinit` user needs, to see what root sees:
  - the group `systemd-journal`, for the oom check;
  - read access to the servlet container's configuration (`server.xml` is 0640 `root:tomcat`),
    or `BASE_URL` in the configuration.
- `xinit setup` creates the credentials file of the db check (`DB_CREDENTIALS`) from
  `hibernate.cfg.xml`, 0600 and owned by the `xinit` user.
- `xinit watch` is the first command that changes something: it logs what it does to the journal
  (`systemd-cat` or `logger`), not only to stderr.
- `STARTUP_GRACE` already keeps a starting JVM from being a failure. The restart policy's own
  cooldown comes on top.

## Tasks

### 2.1 `xinit watch` (done, as root; the path unit comes with 2.3)
Reference: [../acting.md](../acting.md). What was decided while writing it:
- one count of failed runs for the instance, not one per check;
- an `unknown` leaves the count as it is; a `warn` is healthy;
- once it has stopped restarting (`flapping`), only a healthy run makes it act again, even when
  the restarts are older than the window;
- a restart is stored in the state before it is done, and counts even when it fails;
- `watch` exits 0 when it did its work, whatever the state of XWiki, so that its systemd service
  does not fail every minute while XWiki is down;
- a frozen JVM (`kill -STOP`) gives no thread dump: the signal stays pending. The thread dump is
  tested on a JVM that runs but serves an error page.

- `flock` on `/run/xinit/<instance>/lock` (done: `xinit_lock_acquire`). Each instance has its own
  runtime directory, which fits `RuntimeDirectory=xinit/%i`: stopping one instance's service
  cannot remove another's files.
- State lives in `/var/lib/xinit/<instance>/state` (failure counters, last restart times). The
  state files and the duration parser exist (`lib/xinit/state.sh`).
- Restart policy. The algorithm is in DESIGN §3.4. Defaults, decided:
  - `ACT_ON`: `process` crit, `http` crit, and `oom` crit `heap`;
  - `RESTART_AFTER=3` consecutive failed runs, with one run per minute;
  - `COOLDOWN=15min` after a restart;
  - `MAX_RESTARTS=3` per hour (`MAX_RESTARTS_WINDOW`), then it stops acting and escalates.
- Before a restart, store a thread dump in the state dir, since it must be taken before the JVM
  is gone. The Debian packages ship a JRE, without `jcmd`: the dump is `kill -3`, read back from
  the journal. The full report is in Phase 3.
- Restart through the path unit (2.3), or `RESTART_CMD` for an installation whose unit xinit does
  not manage.
- `--dry-run` shows what it would do.
- Notification hook: a stub that logs to the journal. Mail and webhook come in Phase 3.

### 2.2 Maintenance (done, except its use by `watch`)
- `xinit maint on [--for DURATION] [--reason TEXT] | off | status`. Reference:
  [../acting.md](../acting.md).
- The expiry is stored in `/var/lib/xinit/<instance>/maintenance`, a file of its own: `maint`
  never waits for a `watch` run. Without `--for` it lasts `MAINT_DURATION` (2 hours).
- Root, or the owner of the state directory, may set it. Root writes there as that owner.
- `watch` ignores the failures but still records them. A stored maintenance that cannot be read
  must not be taken for "off".
- `MAINTENANCE_REMINDER` comes in Phase 3, with notifications.

### 2.3 `xinit setup [--undo] [--dry-run]` (done)
Reference: [../acting.md](../acting.md). What differs from the plan below, and why:
- **Crash notification**: `ExecStopPost=` in the drop-in, not `OnFailure=`. With `Restart=`, a
  unit enters the failed state only when systemd gives up restarting it, so `OnFailure=` would
  stay silent for a crash that systemd repairs.
- **Warm-up**: started by `ExecStartPost=` in the drop-in, not by `WantedBy=<UNIT>`. Nothing has
  to be enabled then, so `--undo` has no link in `<UNIT>.wants/` to remove. (`WantedBy=` also
  works after an automatic restart: tried on systemd 252 and 257.)
- **Secrets**: no `LoadCredential=`. In the Docker test containers the credentials directory is
  not visible to the service. The credentials file is owned by `xinit`, mode 0600.
- **Reading the installation**: the job gets the group of each file it cannot read otherwise
  (`SupplementaryGroups=`), with a read-only file system.
- **Manifest**: in `/etc/xinit/setup/`, not in the state directory, which belongs to `xinit`:
  `--undo` runs as root and removes what the manifest lists.
- **Units**: one unit file per instance (`xinit-watch@<instance>.service`), not a template, since
  their content differs per instance.
- `ReadWritePaths=` for agent data directories is left to Phase 5, with the hardening.
- **`RESTART_CMD`**: a job that is not root asks root for the restart in every case, and root
  runs `RESTART_CMD`. The output of that command is not read, and it does not get the lock: a
  start script that leaves the JVM behind would otherwise keep the run waiting.
- A second run of setup removes what the first one wrote and it no longer writes.

The plan was to generate the following files and print a diff before writing them:
- the drop-in `/etc/systemd/system/<UNIT>.d/50-xinit.conf`:
  - `Restart=on-failure`, `RestartSec=`;
  - `OnFailure=xinit-notify@%n.service`;
  - optional `JVM_OPTS_APPEND` (heap, agents). For `tomcatN` these are appended to the package's
    environment, with `%` escaped. A drop-in `JAVA_OPTS` does **not** work for `tomcatN`: the start
    script sources `/etc/default/tomcatN` and overrides it (verified in the fault tests). Use
    `JDK_JAVA_OPTIONS`, which the `java` launcher reads itself. It works the same for Tomcat, xjetty
    and WAR installs. Options on the command line still win over it, so detect an `-Xmx` already
    there and report the conflict;
  - `ReadWritePaths=` for agent data dirs;
- `xinit-watch@<instance>.{service,timer}`:
  - the service runs `User=xinit`, `StateDirectory=xinit`, `RuntimeDirectory=xinit`,
    `ProtectSystem=strict`, `LoadCredential=`;
  - the timer is `OnUnitActiveSec=1min`;
- `xinit-act@<instance>.path` and `.service` (XINIT-15): how the `xinit` user restarts XWiki
  without root, polkit or sudo.
  - `watch` writes a request file in `/run/xinit/<instance>/`.
  - The path unit sees it and starts the service, as root.
  - The service does one of two fixed things, named by the request: restart `<UNIT>`, or send
    `kill -3` to its JVM. It takes nothing else from the request.
- credentials: `db.cnf` / `.pgpass` derived from `hibernate.cfg.xml`, mode 0600, owned by `xinit`;
- `xinit-warmup@<instance>.service` (XINIT-14): `After=<UNIT>`, `PartOf=<UNIT>`,
  `WantedBy=<UNIT>`. It retries `WARMUP_URLS` until 200 or `WARMUP_TIMEOUT`.

`--undo` removes exactly what `setup` wrote (tracked in a manifest in the state dir), then runs
`daemon-reload`.

### 2.4 Cron fallback (dropped)
Every supported distribution has systemd, and a container never restarts itself (Phase 4).

### 2.5 Multi-instance (XINIT-2) (done)
Each unit is written per instance. The test uses a second instance whose "wiki" is a
small stub HTTP service in the same container. It proves that the state, the lock and the restart
of one instance leave the other alone, without a second real XWiki and its image variant.

## Acceptance (integration scenarios, see TESTING.md)
- Killing the JVM with `kill -9`: systemd restarts it, and the crash is notified once. **Met**
  (S-PROC-02).
- A hung JVM (`kill -STOP`): after `RESTART_AFTER` runs, one restart happens, and cooldown is
  respected. **Met** (S-WATCH-01, S-WATCH-02). A frozen JVM gives no thread dump: the one of a
  JVM that still runs is stored before its restart (S-WATCH-08).
- Maintenance on: there is no restart. Maintenance with an expiry: it ends by itself. **Met**
  (S-WATCH-03, S-WATCH-04, S-MAINT-03).
- A permanently broken wiki: there are at most `MAX_RESTARTS` restarts, then a flapping
  escalation. **Met** (S-WATCH-05), with a page that always fails rather than a wrong database
  password, which takes a restart of XWiki to put in place and another to heal.
- `setup --undo` leaves `systemctl cat <UNIT>` identical to the state before `setup`. **Met**
  (S-SETUP-01).
- The watch service runs as `xinit`, and no file written by xinit lets another user read a
  secret. **Met** (S-SETUP-03, S-SEC-01).

Verified on the five local variants (cgroup v1): `tomcat10-pgsql`, `tomcat11-mariadb`,
`xjetty-pgsql`, `war-tomcat10-pgsql` and `tomcat10-mariadb-lts-debian12` (systemd 252). Each one
ran the whole integration suite, 60 tests, of which 3 or 4 are skipped for another kind of
installation. What failed, and what was done:
- S-MAINT-01, on the first two variants: the test expected a mode that a fix had just changed. It
  was corrected and rerun on both.
- S-DB-01, on the WAR variant: the database stopped between the test of its port and the login,
  and the db check called that a failed login. The check was fixed, and the scenario rerun there.
- S-SEC-01, on the WAR variant: its database password is a common word, which cannot be searched
  for. There the scenario checks the permissions only.

An independent review of the code of this phase gave 14 findings, on robustness and on what a
compromised `xinit` user could do: all are fixed, each with a test.

The workflows then ran the suite on GitHub's runners (cgroup v2), with a sixth variant,
`tomcat10-mysql-ubuntu2604`. The scenarios of this phase pass there on the six variants. S-PROC-04
was added from what cgroup v2 showed: the unit of a package is left down after a kill by the
kernel's OOM killer, and the drop-in of `xinit setup` makes systemd start it again.
