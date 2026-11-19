# Reports

Reference of `xinit report`: the diagnostics archive of an instance. The configuration keys are in
[`../etc/xinit.conf.example`](../etc/xinit.conf.example).

A report is what an admin needs to understand a failure, taken while it happens. `xinit watch`
builds one before it restarts XWiki ([acting.md](acting.md)); `xinit report` builds one on demand.

```bash
xinit report                      # stored with the reports of the instance
```

```bash
xinit report --output /root/wiki-report.tar.gz
```

```bash
xinit report --format json
```

- Without `--output`, the archive goes to `<STATE_DIR>/<instance>/reports/report-<time>.tar.gz`,
  and the last `REPORT_KEEP` are kept. The time is in UTC.
- With `--output`, it goes there instead, and nothing is stored. An existing file is never
  replaced.
- The archive is for its owner only (0600): a thread dump or a log line may hold what a user
  typed.
- The text output is the summary, then the path of the archive.
- Exit codes: 0 when the archive is written, whatever the state of XWiki; 3 when it is not, or
  when there is no installation; 64 for a usage error.
- It takes about 15 seconds: three thread dumps, `THREADDUMP_INTERVAL` apart.

| Key | Default | Meaning |
|---|---|---|
| `REPORT_KEEP` | `10` | how many reports are kept |
| `REPORT_JOURNAL_LINES` | `2000` | how many lines of the log go in a report |
| `REPORT_DB_QUERIES` | `no` | `yes`: with the text of the queries the database is running |
| `THREADDUMP_INTERVAL` | `5s` | the time between two thread dumps |

`--format json` prints:

| Field | Meaning |
|---|---|
| `instance` | the instance |
| `report` | the path of the archive |
| `status` | the overall status of the checks |
| `oom` | `true` when the `oom` check is `warn` or `crit` |
| `deadlock` | `true` when a thread dump shows a deadlock |
| `thread_dumps` | how many thread dumps the JVM wrote, 0 to 3 |
| `sections` | for each section, `ok` or `skipped: <why>` |

## What is in the archive

One directory, `xinit-report-<instance>-<time>/`:

| File | Section | Content |
|---|---|---|
| `summary.txt` | | the text below |
| `layout.txt`, `config.txt` | `layout` | what `xinit layout` prints, and the configuration of xinit with where each value comes from |
| `checks.json` | `checks` | the results of the checks, as `xinit check --format json` |
| `system.txt` | `system` | the load and the memory of the host |
| `jvm.txt` | `jvm` | the JVM: its command line, its memory and thread count, its limits |
| `sockets.txt` | `sockets` | the TCP sockets (`ss`), counted by port and state |
| `database.txt` | `database` | the sessions of the database, and its size |
| `disk.txt` | `disk` | the space and the inodes of the file systems (`df`) |
| `dns.txt` | `dns` | only when a check failed on `dns`: what the resolver answers for the host |
| `journal.txt` | `journal` | the last lines of the log of XWiki |
| `threads/dump-N.txt` | `threads` | the thread dumps |

- A section that cannot be filled is left out, and the summary says why: no JVM, no credentials
  for the database, a journal this user may not read. The report is written all the same.
- The files of XWiki's own configuration are not copied: they hold secrets under names xinit
  cannot know. The layout tells the database, the version and the URL.
- The database is asked with the credentials file of the `db` check ([checks.md](checks.md)).
  Without `REPORT_DB_QUERIES=yes`, the text of the queries is not asked for: it may hold data of
  the wiki.
- The log is read from the systemd journal only.

## Thread dumps

- The JVM is asked with `kill -3`, and its answer is read from the journal: the Debian packages
  bring a JRE, without `jcmd`.
- A JVM that writes no dump within 10 seconds is not asked again. A JVM that is stopped or frozen
  gives none.
- A user who is not root asks root for each signal, through the unit `xinit setup` installs
  ([acting.md](acting.md)).

The summary says what the dumps show:
- how many threads, and how many in each state;
- a deadlock: which thread waits for which;
- the requests being served, by URL, with the number of threads on each in each dump. XWiki puts
  the URL of a request in the name of its thread. The URLs are counted without their query
  string, which stays in the dumps;
- the ten threads that used the most CPU between two dumps, from the `cpu=` time of each thread.

A thread name is chosen by whoever sends the request: in the summary, it is shown without control
characters, and cut.

## Secrets

- In the command line of the JVM, the value of an option whose name holds `pass`, `secret`,
  `token`, `key` or `credential` is replaced by `<redacted>`.
- Then the secrets xinit can read itself are replaced wherever they show in the archive, a thread
  dump or a log line included: the password of the database (`hibernate.cfg.xml`, the credentials
  file of the `db` check) and the one of the `http` check (its netrc file).
- A secret shorter than 8 characters is not searched for: it would match ordinary words.
- This does not make a report public. A log or a thread dump can hold other secrets, and data of
  the wiki.

## Who runs it

| Run by | State directory | What happens |
|---|---|---|
| root | root's, or none yet | root builds and stores the report |
| the user of the periodic job | its own | it builds and stores the report; root sends the signals for it |
| root | of the user of the periodic job | root builds the report, and that user stores it |

Root never writes in a directory that belongs to another user. In the last case root builds the
archive in a temporary directory of its own, and gives it to `xinit report --store`, run as the
owner of the state with `setpriv`: that command only stores what it reads, and removes the oldest
reports.

The archive is built in a directory under `$TMPDIR` (`/tmp` by default), created for its owner
only, and removed when the command ends.
