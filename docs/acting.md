# `xinit watch`, `xinit maint`, and what xinit remembers

`xinit layout` and `xinit check` only read ([checks.md](checks.md)). The commands on this page
write in xinit's own directories, and `xinit watch` may restart XWiki.

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
4. at `RESTART_AFTER` such runs, stores a thread dump, then restarts XWiki.

| Key | Default | Meaning |
|---|---|---|
| `ACT_ON` | `process http oom` | the checks whose `crit` counts; empty: never restart |
| `RESTART_AFTER` | `3` | failed runs in a row before a restart |
| `COOLDOWN` | `15min` | how long the next restart waits after one |
| `MAX_RESTARTS` | `3` | restarts at most in `MAX_RESTARTS_WINDOW` |
| `MAX_RESTARTS_WINDOW` | `1h` | |
| `RESTART_CMD` | | replaces `systemctl restart <UNIT>`; split on spaces, run without a shell |

What never causes a restart:
- a `warn`: a starting or slow XWiki, a kill by the kernel's OOM killer;
- an `unknown`: the count then stays as it is, neither raised nor cleared;
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
| `thread_dump` | the file of the thread dump, else `null` |

| Reason | Action | Meaning |
|---|---|---|
| `healthy` | none | no check of `ACT_ON` is `crit` or `unknown`; the count starts again |
| `unknown` | none | a check of `ACT_ON` could not tell |
| `counting` | none | failed, but not yet `RESTART_AFTER` times in a row |
| `maintenance` | none | failed during a maintenance; the failure is still counted |
| `maintenance-unknown` | none | failed, and the stored maintenance cannot be read |
| `cooldown` | none | failed, less than `COOLDOWN` after a restart |
| `flapping` | none | failed after `MAX_RESTARTS` restarts: no more restart until a healthy run |
| `threshold` | restart | failed `RESTART_AFTER` times in a row |
| `locked` | none | another run holds the lock; no check was run |
| `no-installation` | none | there is no XWiki to watch (exit 3) |

- Exit codes: 0 when the run did its work, whatever the state of XWiki; 3 when it could not
  (no installation, state that cannot be read or written, restart that failed); 64 for a usage
  error. The state of XWiki is in the output.
- A restart is remembered before it is done, and counts even when it fails.
- The thread dump is asked with `kill -3` and read from the journal: the Debian packages bring a
  JRE, without `jcmd`. It goes to `<STATE_DIR>/<instance>/threaddump-<time>.txt`; the last five
  are kept. A JVM that is stopped or frozen gives none, and is restarted all the same.
- What a run decides is recorded in the system log (`journalctl -t xinit`): each failed run, each
  restart, and the first healthy run after failures. A restart and the `flapping` stop are also
  notifications, which for now are lines in the same log.

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
| `<STATE_DIR>/<instance>/threaddump-*.txt` | the last five thread dumps | `xinit watch` |
| `<RUN_DIR>/<instance>/lock` | the lock of one `xinit watch` run | `xinit watch` |

`STATE_DIR` is `/var/lib/xinit` and `RUN_DIR` is `/run/xinit`.
- Directories are created for their owner only (0700), files too (0600).
- A state file holds one `KEY=value` per line. It is parsed, never sourced, and replaced in one
  rename: a reader never sees half of it.
- Root never writes in a directory that belongs to another user. When `STATE_DIR` belongs to the
  user of the periodic job, `xinit maint on` and `off` run by root are run again as that user,
  with `setpriv`. What root sets is then readable by the periodic job.
- `maintenance` and `state` are two files, so that `xinit maint` never waits for a running
  `xinit watch`.
