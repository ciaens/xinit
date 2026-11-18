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

### 2.3 `xinit setup [--undo] [--dry-run]`
It generates the following files and prints a diff before writing them:
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

### 2.5 Multi-instance (XINIT-2)
Each template unit is instantiated per instance. The test uses a second instance whose "wiki" is a
small stub HTTP service in the same container. It proves that the state, the lock and the restart
of one instance leave the other alone, without a second real XWiki and its image variant.

## Acceptance (integration scenarios, see TESTING.md)
- Killing the JVM with `kill -9`: systemd restarts it, and `xinit-notify@` fires once.
- A hung JVM (`kill -STOP`): after `RESTART_AFTER` runs, one thread dump is stored, one restart
  happens, and cooldown is respected.
- Maintenance on: there is no restart. Maintenance with an expiry: it ends by itself.
- A permanently broken wiki (for example a wrong DB password): there are at most `MAX_RESTARTS`
  restarts, then a flapping escalation.
- `setup --undo` leaves `systemctl cat <UNIT>` identical to the state before `setup`.
- The watch service runs as `xinit`, and no file written by xinit is world-readable.
