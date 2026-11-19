# Phase 3 — Diagnostics and notifications

Goal: when something goes wrong, the admin receives everything needed to understand it, sent the
moment it happens, through the channel they use.

## Carried over from Phase 2

What Phase 2 built, that this phase has to use ([../acting.md](../acting.md)):
- `xinit_notify <event> <message>` (`lib/xinit/notify.sh`) is the one place a notification leaves
  from. It writes a line in the system log. The events: `restart` and `flapping`, from
  `xinit watch`, and `crash`, from `xinit notify crash`, which the unit of XWiki starts when it
  stops unexpectedly. Mail and webhooks go there.
- `xinit watch` stores one thread dump before a restart, in the state directory, and keeps the
  last five. The report takes over from there (three dumps, the summaries).
- A job that is not root asks root for a thread dump with a request file. `jcmd`, when there is
  a JDK, has to run as the user of the JVM: that needs a third request, or `xinit report` run by
  root.
- The state of the job holds the result of each check of the last run (`RESULTS`), the count of
  failed runs and the times of the restarts: what a status command or a metrics file needs.
- A maintenance stores who set it and why. `MAINTENANCE_REMINDER` is still to do.
- The crash notification says what systemd said ("Failed with result 'signal'"). The report of a
  crash cannot take a thread dump: the JVM is gone.
- The oom check counts the lines the JVM writes itself. A JVM started with
  `-XX:+ExitOnOutOfMemoryError` turns a heap error into a crash, which systemd repairs and
  notifies at once: worth proposing through `JVM_OPTS_APPEND`.

## Decisions

Taken before the work started:
- **Mail goes by SMTP, with `curl`**, to `MAIL_SMTP_URL` (default `smtp://localhost:25`), not
  through `sendmail`. The periodic job runs with `NoNewPrivileges`, and the `sendmail` of postfix
  and of exim needs setgid or setuid. `curl` is already required. A host without a listening
  mail server names a relay.
- **No `jcmd` in this phase**: thread dumps come from `kill -3` and the journal. The packages
  bring a JRE, and `jcmd` has to run as the user of the JVM, which would take a third request to
  root.
- **The webhook URL is in a credentials file**, which `curl` reads itself: `xinit.conf` is
  readable by everyone, and such a URL is a secret. It never goes on a command line.
- **`xinit db sanity` moves to Phase 6**: the SQL integrity script of 1.3 has nothing to do with
  diagnostics.
- **XINIT-7: no logrotate snippet now.** The Debian packages log to the journal.
- **The tests use stub SMTP and webhook listeners** in perl, inside the test container, as the
  two-instance scenario does. No image is rebuilt.

Order of work: `xinit report`; notifications by mail; webhook; Prometheus; then the changes to
`xinit setup`, the docs, a review and the full runs.

## Tasks

### 3.1 `xinit report [--output FILE]` (done, without the sending)

Built as [../reporting.md](../reporting.md) describes. What differs from the first plan:
- **The threads that use the CPU come from the dumps**, not from `top -H`: HotSpot prints the CPU
  time of each thread (`cpu=…ms`), and the difference between two dumps says the same, without
  another tool nor the mapping of thread ids.
- **XWiki's configuration files are not copied**, so there is nothing to redact in them: a
  redaction by key name would miss secrets, and the archive leaves by mail. What is redacted: the
  command line of the JVM, by option name, and the secrets xinit can read itself, wherever they
  show.
- **Run by root on a state that belongs to the user of the job, root builds the archive and that
  user only stores it.** Running the whole command again as that user, as `xinit maint` does,
  would lose the groups the job gets from its unit: it could not read the journal.
- `xinit watch` builds the whole report before a restart, where it stored one thread dump: its
  JSON has `report` in place of `thread_dump`.
- The out-of-memory part is the `oom` check, whose result is in the report (`oom` in the JSON,
  for the `[OOM]` prefix of a subject).
- The DNS trace (XINIT-5) is `dns.txt`. Whether a host name that stops resolving is notified is
  decided with the notifications.
- `--send` comes with the notifications.

### 3.2 Notifications (`lib/xinit/notify/`)
- `mail`: uses `sendmail -t` (works with postfix, exim, msmtp-mta, nullmailer). The body is a text
  summary with lines wrapped at 900 characters. The bundle is attached when it is under
  `MAIL_ATTACH_MAX`. `MAIL` accepts a list (XINIT-4).
- `webhook`: a JSON POST to `WEBHOOK_URL`, with templates for generic, Slack/Mattermost and
  Matrix. The secret comes from the credentials.
- `journal`: always on; structured fields (`XINIT_INSTANCE`, `XINIT_CHECK`, `XINIT_STATUS`).
- Rate limiting: identical notifications are not repeated within `NOTIFY_REPEAT`.
- The maintenance reminder (from 1.3) is sent through the same path.
- `xinit-notify@.service` is the `OnFailure=` target from Phase 2. It runs `xinit report --send`
  with the reason taken from the failing unit's `Result`/`ExecMainStatus`.

### 3.3 Prometheus textfile
`--format prom`, plus `PROM_TEXTFILE_DIR`: after each `watch`, it writes `xinit.prom` atomically
(temp file + `mv`).

### 3.4 Logs (XINIT-7)
- Debian packages log to the journal or `/var/log/xwiki`, so nothing to rotate.
- For WAR installs writing `catalina.out`, `xinit setup` can install a logrotate snippet with
  `copytruncate`. This is optional, and `config` checks for it.

## Acceptance
- A hung-JVM scenario gives a mail captured by a local test MTA in the test image, with three
  thread dumps, the URL summary, the DB activity and no secrets. `grep` checks against the known
  test passwords prove the redaction.
- A kernel or heap OOM scenario gives a subject with `[OOM]`, and an old OOM from before the last
  start does **not**.
- A webhook scenario sends a POST to a local `nc`/python listener, with the expected JSON.
