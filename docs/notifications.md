# Notifications

What xinit tells the administrator, and how. The code is `lib/xinit/notify.sh`.

A notification is always an entry in the system log. With `MAIL` set, it is also a mail.

| Event | Sent by | When | With a report |
|---|---|---|---|
| `restart` | `xinit watch` | XWiki was restarted, or the restart failed | yes |
| `flapping` | `xinit watch` | `MAX_RESTARTS` restarts did not help: no more restart until a healthy run | yes |
| `cannot-check` | `xinit watch` | the checks of `ACT_ON` could not tell for `RESTART_AFTER` runs in a row | yes |
| `crash` | `xinit notify crash`, from the unit of XWiki | XWiki stopped without being asked to | no |
| `maintenance` | `xinit watch` | a maintenance lasts | no |
| `report` | `xinit report --send` | someone asks for a report by mail | yes |

- `cannot-check` is how a host name that no longer resolves is told (reason `dns` of the `http`
  check): xinit does not restart XWiki for it, and no longer knows how XWiki is. It is notified
  once, until a run finds XWiki healthy, and not during a maintenance. The mail holds what the
  resolver of the host answers.
- `maintenance`: the first reminder comes when the maintenance has lasted `MAINT_REMINDER_AFTER`
  (one hour), the next ones every `MAINT_REMINDER` (one hour). `MAINT_REMINDER=0` turns them off.
  With the default two hours of a maintenance, that is one reminder.

## The system log

```bash
journalctl -t xinit XINIT_EVENT=restart
```

```bash
journalctl -t xinit XINIT_INSTANCE=default -o json
```

Each notification is one entry, written with `logger --journald`:

| Field | Value |
|---|---|
| `MESSAGE` | `instance <name>: notification (<event>): <what happened>` |
| `XINIT_INSTANCE` | the instance |
| `XINIT_EVENT` | the event |
| `XINIT_CHECK` | the checks it is about, separated by spaces; absent when there is none |
| `XINIT_STATUS` | the status of the checks of that run; absent when no check ran |
| `PRIORITY` | 4 (warning), or 5 (notice) for `maintenance` and `report` |

The entry is written before a restart, and whatever becomes of the mail.

## Mail

| Key | Default | Meaning |
|---|---|---|
| `MAIL` | | who gets the mails: addresses separated by spaces or commas. Empty: no mail |
| `MAIL_FROM` | `xinit@<host name>` | the sender |
| `MAIL_SMTP_URL` | `smtp://localhost:25` | the mail server: `smtp://host[:port]`, or `smtps://host[:port]` for TLS from the first byte |
| `MAIL_SMTP_TLS` | `auto` | STARTTLS on an `smtp://` server: `yes` (required), `no` (never), `auto` (required when xinit logs in) |
| `MAIL_SMTP_NETRC` | `/etc/xinit/credentials/smtp.netrc`, when it exists | the login and password of the mail server |
| `MAIL_ATTACH_MAX` | `5000` | a report larger than this, in kilobytes, is not attached. `0`: never attach |
| `NOTIFY_REPEAT` | `1h` | the same notification is not mailed again within this time |

- **The mail goes by SMTP, sent by `curl`**, not through `sendmail`: the periodic job may gain no
  privilege, and the `sendmail` of postfix and of exim needs one. A host without a mail server
  names its relay in `MAIL_SMTP_URL`.
- **Nothing of it is on a command line**: `curl` reads the server, the addresses and the path of
  the message from its standard input, and the password from the netrc file. `MAIL`, `MAIL_FROM`
  and `MAIL_SMTP_URL` are checked first: a value that is not an address, or not such a URL, stops
  the command before it does anything.
- **The password is not sent in clear** unless `MAIL_SMTP_TLS=no` says so: with a netrc file,
  `auto` requires STARTTLS, and a server that has none gets no mail. The netrc file holds one
  line, `machine <host of MAIL_SMTP_URL> login <user> password <password>`, and is readable by the
  user who runs xinit only.
- **The subject** is `[xinit] <instance> on <host>: <what happened> (<checks>)`, for example
  `[xinit] default on wiki1: XWiki restarted (http)`. It starts with `[xinit] [OOM]` when the
  `oom` check of that run found an out-of-memory error, or when systemd says the kernel killed
  XWiki for memory (`oom-kill`). An error older than the last start of the JVM does not count:
  the `oom` check does not see it.
- **The text** is what happened, the instance, the host and the time, then the summary of the
  report: the results of the checks, the JVM, the database, the sockets and what the thread dumps
  say ([reporting.md](reporting.md)). No line is longer than 900 characters, and control
  characters are replaced by spaces: part of it comes from the log of XWiki, where a remote user
  can have a line written.
- **The report is attached** when it is not larger than `MAIL_ATTACH_MAX`. Otherwise the mail
  says where it is stored.
- **The mail of a restart leaves after the restart**, and says how it went. A mail server that
  does not answer is given up after 30 seconds, and stops nothing: the entry in the system log
  says `mail not sent`, with the error of `curl`.
- **Within `NOTIFY_REPEAT`**, a notification of the same event about the same checks is not
  mailed again. The next mail says how many were held back. A mail that could not be sent does
  not count. `xinit report --send` is always sent. What was mailed is remembered in
  `<STATE_DIR>/<instance>/notify`.
- The message is built in a temporary directory that only its owner can read, and removed once
  `curl` has ended.

The headers `X-Xinit-Instance` and `X-Xinit-Event` let a mail filter sort the mails.

## What xinit prints

`xinit watch --format json` has a `notification` member in `watch`: `null`, or
`{"event": "<event>", "mail": "<what became of the mail>"}`. `xinit report --send --format json`
has `mail`.

| `mail` | Meaning |
|---|---|
| `off` | `MAIL` is empty |
| `sent` | the mail server took it |
| `held` | the same was mailed less than `NOTIFY_REPEAT` ago |
| `failed` | it could not be sent |

Exit codes: a mail that fails does not change the one of `xinit watch`. `xinit report --send`
and `xinit notify crash` exit 3 when their mail could not be sent.
