# Phase 3 — Diagnostics and notifications

Goal: when something goes wrong, the admin receives everything needed to understand it, sent the
moment it happens, through the channel they use.

## Tasks

### 3.1 `xinit report [--send] [--output FILE]`
- The bundle is described in DESIGN §3.5. It is written mode 0600 into the state dir and rotated
  with `REPORT_KEEP`.
- Redaction: passwords in `hibernate.cfg.xml` and `xwiki.cfg` (`xwiki.authentication.*key`,
  `xwiki.superadminpassword`), and system properties whose names match
  `password|secret|token|key`.
- Thread dumps: three dumps, `THREADDUMP_INTERVAL` apart. Add a summary of the most frequent
  request URLs across `http-nio` threads (the 1.3 "most common pages" feature, made more robust),
  and the hottest threads (from `top -H`, with the TID mapped to the hex `nid`).
- OOM:
  - Heap: `OutOfMemoryError` in the log or journal **since the last start**.
  - Kernel: `journalctl -k --since <last start>` matched to this JVM's PID or cgroup.
  - Either one adds a `[OOM]` prefix to the subject.
- DB:
  - PostgreSQL: `pg_stat_activity` (state, wait_event, query age; query text only if
    `REPORT_DB_QUERIES=yes`) and DB size.
  - MySQL/MariaDB: `SHOW FULL PROCESSLIST` and schema sizes.
- Port and SQL the sanity checks (`share/xinit/sql/`), available through `xinit db sanity`.
- DNS trace when the HTTP check failed on resolution (XINIT-5).

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
