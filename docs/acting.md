# `xinit setup`, `xinit watch`, `xinit maint`, and what xinit remembers

`xinit layout` and `xinit check` only read ([checks.md](checks.md)). The commands on this page
write in xinit's own directories, `xinit watch` may restart XWiki, and `xinit setup` installs
systemd units.

## Setup

`xinit setup` makes xinit run by itself, for one instance, on a host with systemd. Only root can
run it.

```bash
xinit setup --dry-run             # what it would write, as a diff, and the commands it would run
```

```bash
xinit setup
```

```bash
xinit setup --undo                # remove exactly what setup wrote
```

What it writes:

| File | What for |
|---|---|
| `/etc/sysusers.d/xinit.conf` | the user `xinit`, which the periodic job runs as |
| `/etc/systemd/system/<UNIT>.d/50-xinit.conf` | restart XWiki when it crashes, notify the crash, start the warm-up; `JVM_OPTS_APPEND` |
| `xinit-watch@<instance>.service` and `.timer` | `xinit watch`, every minute, as `xinit` |
| `xinit-act@<instance>.path` and `.service` | how the job, which is not root, gets XWiki restarted |
| `xinit-notify@<instance>.service` | the notification of a crash, as `xinit` |
| `xinit-warmup@<instance>.service` | the first requests after each start of XWiki |
| `/etc/xinit/credentials/<instance>.pgpass` or `.my.cnf` | the password of the db check, from `hibernate.cfg.xml`; 0600, owned by `xinit` |
| `/etc/xinit/setup/<instance>.manifest` | the list of all this, for `--undo` |

- Run it again after a change of the configuration or of the installation: it updates what
  differs, and removes what it wrote before and no longer writes (the drop-in of another unit).
  `--format json` lists each file with `create`, `update`, `unchanged` or `remove`.
- A credentials file that setup did not write is left alone, and so is one that `DB_CREDENTIALS`
  names.
- It warns when the job cannot be given what it needs to read a file of the installation, and
  when xinit itself is installed where another user than root can change it: the units run it,
  some of them as root.
- `--undo` removes what the manifest lists, and only under the directories setup writes in. It
  keeps the user `xinit` and the state. The manifest is trusted only when root alone can write it.
- `JVM_OPTS_APPEND` is passed in `JDK_JAVA_OPTIONS`, which the `java` launcher reads itself: it
  works the same for Tomcat, xjetty and a WAR. It applies at the next start of XWiki. An option on
  the command line of the JVM wins over the same one there: setup warns about an `-Xmx` in both.

### How the job works without root

The job runs as the user `xinit`, confined by systemd (`ProtectSystem=strict`, no new privileges,
its own `/tmp`). Three things let it do its work:
- **Reading.** It gets the group `systemd-journal`, and the group of each file of the
  installation that is not readable by everyone (`server.xml` belongs to `root:tomcat`, mode
  0640). A group that would give much more, as `root` or `adm`, is not given: setup warns
  instead. The file system is read-only for it, except its state and runtime directories.
- **Restarting XWiki, and asking the JVM for a thread dump.** The job creates an empty file,
  `request-restart` or `request-thread-dump`, in `/run/xinit/<instance>/`. A systemd path unit
  sees it and starts `xinit act` as root, which removes the file and does what its name says: it
  restarts the unit of the installation, or sends `SIGQUIT` to its JVM. Nothing is read from the
  file, and a file by another name does nothing. No polkit rule and no sudo are needed.
  `RESTART_CMD`, when there is one, is run by root in the same way.
- **The database password.** It is in a file that only `xinit` reads.

`xinit watch` run by root itself restarts XWiki directly. Once the state belongs to `xinit`, root
uses `systemctl start xinit-watch@<instance>.service`, or `xinit watch --dry-run`.

### Crashes and first requests

- The drop-in sets `Restart=on-failure`: systemd starts a crashed XWiki again after 10 seconds.
  This also covers a kill by the kernel's OOM killer on cgroup v2, which the `Restart=on-abort`
  of Debian's Tomcat unit does not: without the drop-in, XWiki then stays down until the
  periodic job restarts it.
- When the unit stops for another reason than being asked to, its `ExecStopPost=` starts
  `xinit-notify@<instance>.service`. This happens at once, not at the next run of the job. A
  restart someone asks for is not notified, nor one the job asked for. The notification is an
  entry in the system log, and a mail when `MAIL` is set: see
  [notifications.md](notifications.md). Crashes that follow each other within `NOTIFY_REPEAT`
  give one mail.
- After each start, whoever started it, `ExecStartPost=` starts the warm-up: `xinit warmup`
  requests each URL of `WARMUP_URLS` until it answers 200, for `WARMUP_TIMEOUT` at most. Without
  `WARMUP_URLS` it requests the page of the http check. It does not delay the start of XWiki.

## Watch

`xinit watch` is one run of the periodic job: it runs the checks, and restarts XWiki when it has
failed for long enough.

```bash
xinit watch --dry-run             # what a run would do now, without doing or writing anything
```

```bash
xinit watch --format json
```

One run:
1. takes the lock of the instance, or ends at once when another run holds it;
2. runs the checks of `CHECKS`, and those of `ACT_ON`;
3. counts the runs in a row in which a check of `ACT_ON` was `crit`;
4. at `RESTART_AFTER` such runs, stores a report, restarts XWiki, then mails what it did.

| Key | Default | Meaning |
|---|---|---|
| `ACT_ON` | `process http oom` | the checks whose `crit` counts; empty: never restart |
| `RESTART_AFTER` | `3` | failed runs in a row before a restart |
| `COOLDOWN` | `15min` | how long the next restart waits after one |
| `MAX_RESTARTS` | `3` | restarts at most in `MAX_RESTARTS_WINDOW` |
| `MAX_RESTARTS_WINDOW` | `1h` | |
| `RESTART_CMD` | | replaces `systemctl restart <UNIT>`; split on spaces, run without a shell, and its output is not read |

What never causes a restart:
- a `warn`: a starting or slow XWiki, a kill by the kernel's OOM killer;
- an `unknown`: the count then stays as it is, neither raised nor cleared. After
  `RESTART_AFTER` runs in a row in which a check of `ACT_ON` could not tell, as when the host
  name of `BASE_URL` no longer resolves, xinit says once that XWiki is no longer watched (reason
  `cannot-check`);
- the `db` check, unless `ACT_ON` names it: restarting XWiki does not repair its database.

The output is the one of `xinit check`, plus what the run did. In JSON, the `watch` member:

| Field | Meaning |
|---|---|
| `action` | `none` or `restart` |
| `reason` | why, see below |
| `dry_run` | `true` with `--dry-run` |
| `failures`, `restart_after` | failed runs in a row, and how many it takes |
| `failed_checks` | the checks of `ACT_ON` that are `crit` |
| `restarts`, `max_restarts` | restarts in the window, this one included, and the limit |
| `cooldown_remaining_seconds` | with the reason `cooldown` |
| `restart_ok` | `true` or `false` after a restart, else `null` |
| `report` | the archive of the report, else `null` |
| `notification` | `{"event": …, "mail": …}` when this run notified something, else `null`: see [notifications.md](notifications.md) |

| Reason | Action | Meaning |
|---|---|---|
| `healthy` | none | no check of `ACT_ON` is `crit` or `unknown`; the count starts again |
| `unknown` | none | a check of `ACT_ON` could not tell |
| `cannot-check` | none | a check of `ACT_ON` could not tell for `RESTART_AFTER` runs in a row: notified once, until a healthy run |
| `counting` | none | failed, but not yet `RESTART_AFTER` times in a row |
| `maintenance` | none | failed during a maintenance; the failure is still counted |
| `maintenance-unknown` | none | failed, and the stored maintenance cannot be read |
| `cooldown` | none | failed, less than `COOLDOWN` after a restart |
| `flapping` | none | failed after `MAX_RESTARTS` restarts: no more restart until a healthy run |
| `threshold` | restart | failed `RESTART_AFTER` times in a row |
| `locked` | none | another run holds the lock; no check was run. After 20 minutes without a run that ended, this is an error (exit 3) |
| `no-installation` | none | there is no XWiki to watch (exit 3) |

- Exit codes: 0 when the run did its work, whatever the state of XWiki; 3 when it could not
  (no installation, state that cannot be read or written, restart that failed); 64 for a usage
  error. The state of XWiki is in the output.
- A restart is remembered before it is done, and counts even when it fails.
- Before the restart, a report is built, with three thread dumps of the JVM: see
  [reporting.md](reporting.md). It takes about 15 seconds. A JVM that is stopped or frozen gives
  no thread dump, and a report that cannot be written does not stop the restart.
- What a run decides is recorded in the system log (`journalctl -t xinit`): each failed run, each
  restart, and the first healthy run after failures. A restart, the `flapping` stop and
  `cannot-check` are also notifications, each with a report: an entry with fields in the same
  log, and a mail when `MAIL` is set. The mail of a restart leaves after the restart, and a mail
  that cannot be sent stops nothing.
- While a maintenance is on, a run reminds of it: first when it has lasted
  `MAINT_REMINDER_AFTER`, then every `MAINT_REMINDER`.

## Maintenance

During a maintenance, `xinit watch` records the failures but does not act on them.

```bash
xinit maint on                    # for MAINT_DURATION, two hours by default
```

```bash
xinit maint on --for 4h --reason "upgrade to 18.10"
```

```bash
xinit maint status --format json
```

```bash
xinit maint off
```

- A maintenance always has an end, so a forgotten one stops by itself. `on` again replaces the
  end and the reason.
- A duration is a number of seconds, or numbers with a unit: `s`, `m` or `min`, `h`, `d`
  (`90`, `15min`, `2h`, `1h30m`).
- `maint` needs no detected installation: it works from the instance name alone.
- `on` and `off` are recorded in the system log (`journalctl -t xinit`).
- A maintenance that lasts is notified by `xinit watch`: after `MAINT_REMINDER_AFTER` (one
  hour), then every `MAINT_REMINDER` (one hour; `0`: never). With the default two hours of a
  maintenance, that is one reminder.
- Exit codes: 0, 64 for a usage error, 3 when the state cannot be read or written.

`--format json` prints, for every action:

| Field | Meaning |
|---|---|
| `instance` | the instance |
| `maintenance` | `true` while a maintenance is on |
| `until`, `since` | its end and its start, in seconds since the epoch, else `null` |
| `remaining_seconds` | what is left, else `null` |
| `by` | who set it: the `sudo` user when there is one |
| `reason` | the `--reason` text, on one line, cut to 200 characters |

Who may set it: root, or the user who owns the state directory. Any other user gets an error, also
for `status`, and never a wrong "off".

## State and lock

| Path | Holds | Written by |
|---|---|---|
| `<STATE_DIR>/<instance>/maintenance` | the maintenance | `xinit maint` |
| `<STATE_DIR>/<instance>/state` | the count of failed runs, the times of the restarts | `xinit watch` |
| `<STATE_DIR>/<instance>/notify` | when each event was last mailed, and how many mails were held back since | `xinit watch`, `xinit notify` |
| `<STATE_DIR>/<instance>/reports/report-*.tar.gz` | the last `REPORT_KEEP` reports | `xinit watch`, `xinit report` |
| `<RUN_DIR>/<instance>/lock` | the lock of one `xinit watch` run | `xinit watch` |

`STATE_DIR` is `/var/lib/xinit` and `RUN_DIR` is `/run/xinit`.
- Directories are created for their owner only (0700), files too (0600).
- A state file holds one `KEY=value` per line. It is parsed, never sourced, and replaced in one
  rename: a reader never sees half of it.
- Root never writes in a directory that belongs to another user. When `STATE_DIR` belongs to the
  user of the periodic job, `xinit maint on` and `off` run by root are run again as that user,
  with `setpriv`. What root sets is then readable by the periodic job. A report that root builds
  is stored the same way.
- `maintenance` and `state` are two files, so that `xinit maint` never waits for a running
  `xinit watch`.
