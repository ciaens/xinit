# `xinit maint`, and what xinit remembers

`xinit layout` and `xinit check` only read ([checks.md](checks.md)). The commands on this page
write: only in xinit's own directories.

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
| `<STATE_DIR>/<instance>/state` | failure counters and restart times | `xinit watch` (to come) |
| `<RUN_DIR>/<instance>/lock` | the lock of one `xinit watch` run | `xinit watch` (to come) |

`STATE_DIR` is `/var/lib/xinit` and `RUN_DIR` is `/run/xinit`.
- Directories are created for their owner only (0700), files too (0600).
- A state file holds one `KEY=value` per line. It is parsed, never sourced, and replaced in one
  rename: a reader never sees half of it.
- Root never writes in a directory that belongs to another user. When `STATE_DIR` belongs to the
  user of the periodic job, `xinit maint on` and `off` run by root are run again as that user,
  with `setpriv`. What root sets is then readable by the periodic job.
- `maintenance` and `state` are two files, so that `xinit maint` never waits for a running
  `xinit watch`.
