# Phase 2 — Acting safely

Goal: xinit fixes a broken or hung XWiki on a host with systemd, without restart loops and without
needing root for the periodic job.

## Tasks

### 2.1 `xinit watch`
- `flock` on `/run/xinit/<instance>.lock`. State lives in `/var/lib/xinit/<instance>/state`
  (failure counters, last restart times, maintenance expiry).
- Restart policy, configured by `ACT_ON`, `RESTART_AFTER`, `COOLDOWN`, `MAX_RESTARTS`,
  `MAX_RESTARTS_WINDOW`. The algorithm is in DESIGN §3.4.
- Before a restart, capture the minimal diagnostics: a thread dump through `jcmd`, since it must be
  taken before the JVM is gone. The full report is in Phase 3; this phase stores the dump in the
  state dir.
- Restart through `systemctl restart <UNIT>`, or `RESTART_CMD` for a WAR install without systemd.
- Notification hook: a stub that logs to the journal. Mail and webhook come in Phase 3.

### 2.2 Maintenance
- `xinit maint on [--for DURATION] [--reason TEXT] | off | status`.
- The expiry is stored in the state. `watch` ignores the failures but still records them.
- `MAINTENANCE_REMINDER` comes in Phase 3, with notifications.

### 2.3 `xinit setup [--undo] [--dry-run]`
It generates the following files and prints a diff before writing them:
- the drop-in `/etc/systemd/system/<UNIT>.d/50-xinit.conf`:
  - `Restart=on-failure`, `RestartSec=`;
  - `OnFailure=xinit-notify@%n.service`;
  - optional `JVM_OPTS_APPEND` (heap, agents). For `tomcatN` these are appended to the package's
    `JAVA_OPTS`, with `%` escaped. Verify how `/etc/default/tomcatN` and the drop-in `Environment=`
    interact before choosing the mechanism;
  - `ReadWritePaths=` for agent data dirs;
- `xinit-watch@<instance>.{service,timer}`:
  - the service runs `User=xinit`, `StateDirectory=xinit`, `RuntimeDirectory=xinit`,
    `ProtectSystem=strict`, `LoadCredential=`;
  - the timer is `OnUnitActiveSec=1min`;
- the polkit rule (`/etc/polkit-1/rules.d/50-xinit.rules`): user `xinit` may `restart` only the
  listed units (XINIT-15);
- credentials: `db.cnf` / `.pgpass` derived from `hibernate.cfg.xml`, mode 0600, owned by `xinit`;
- `xinit-warmup@<instance>.service` (XINIT-14): `After=<UNIT>`, `PartOf=<UNIT>`,
  `WantedBy=<UNIT>`. It retries `WARMUP_URLS` until 200 or `WARMUP_TIMEOUT`.

`--undo` removes exactly what `setup` wrote (tracked in a manifest in the state dir), then runs
`daemon-reload`.

The `jcmd` thread dump must run as the JVM's user: `runuser -u <jvm user> -- jcmd`, granted by a
narrow sudoers or polkit rule, or by running that one step as root. Choose one and document why.

### 2.4 Cron fallback
`/etc/cron.d/xinit` runs `xinit watch` every minute, for hosts without systemd. It uses the same
locking and state.

### 2.5 Multi-instance (XINIT-2)
Each template unit is instantiated per instance. Two XWiki instances on one host are tested with
two Tomcat instances, or with Tomcat + xjetty on different ports, in one image variant.

## Acceptance (integration scenarios, see TESTING.md)
- Killing the JVM with `kill -9`: systemd restarts it, and `xinit-notify@` fires once.
- A hung JVM (`kill -STOP`): after `RESTART_AFTER` runs, one thread dump is stored, one restart
  happens, and cooldown is respected.
- Maintenance on: there is no restart. Maintenance with an expiry: it ends by itself.
- A permanently broken wiki (for example a wrong DB password): there are at most `MAX_RESTARTS`
  restarts, then a flapping escalation.
- `setup --undo` leaves `systemctl cat <UNIT>` identical to the state before `setup`.
- The watch service runs as `xinit`, and no file written by xinit is world-readable.
