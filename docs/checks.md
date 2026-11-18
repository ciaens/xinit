# `xinit layout` and `xinit check`

Both commands only read. They work with every file system read-only, and need no configuration
when XWiki comes from the Debian packages.

```bash
xinit layout                      # how the installation was detected
```

```bash
xinit check                       # run every check
```

```bash
xinit check --format nagios       # as a Nagios / Icinga plugin
```

```bash
xinit check http rest             # only these checks
```

The configuration keys are documented in [`etc/xinit.conf.example`](../etc/xinit.conf.example).

## Layout

`xinit layout [--format text|json]` prints each key with its source:
- `config`: set in the configuration, in the environment or with `-o`;
- `detected`: read from the installation's own files;
- `default`: derived from another key;
- `unknown`: could not be determined.

| Key | Debian Tomcat | Debian xjetty | WAR |
|---|---|---|---|
| `PROFILE` | `debian-tomcat`, when `xwiki-tomcatN-common` is installed | `debian-xjetty`, when `xwiki-xjetty-common` is installed | `war`, when `UNIT` or `WEBAPP_DIR` is configured |
| `UNIT` | `tomcatN.service` | `xwiki.service` | **to configure** |
| `WEBAPP_DIR` | `/usr/lib/xwiki` | `/usr/lib/xwiki` | **to configure** |
| `CONFIG_DIR` | `/etc/xwiki` | `/etc/xwiki` | `WEBAPP_DIR/WEB-INF` |
| `BASE_URL` | port, and `address` if any, of the first plain HTTP `<Connector>` of `server.xml`; path from the name of the context file whose `docBase` is the webapp | port from `-p` in `ExecStart`, else `JETTY_PORT`, else 8080; path `/xwiki` | **to configure** |
| `PERMDIR` | `environment.permanentDirectory` in `CONFIG_DIR/xwiki.properties` | same | same |
| `DB_TYPE`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER` | the active `connection.url` and `connection.username` of `CONFIG_DIR/hibernate.cfg.xml` | same | same |
| `VERSION` | `WEBAPP_DIR/META-INF/extension.xed` | same | same |
| `LOG_SOURCE` | `journal:<UNIT>` | same | same |
| `JVM_PID` | the unit's main process when it is `java`, else the PID in `PID_FILE` | same | same |

The exit code is 0 when `PROFILE`, `UNIT`, `WEBAPP_DIR`, `CONFIG_DIR` and `BASE_URL` are known.
Otherwise it is 3, and the error message names what to configure.

A user who may not read `server.xml` or `hibernate.cfg.xml` gets `unknown` for the keys read from
them. Set those keys in the configuration.

## Results

A check gives one result:

| Field | Content |
|---|---|
| `check` | the name of the check |
| `status` | `ok`, `warn`, `crit` or `unknown` |
| `reason` | a short word that says why. Programs should test this, not the message. |
| `message` | a sentence for people |
| `metrics` | numbers. A name ends with its unit: `time_seconds`, `free_percent`, `free_bytes`. |

| Status | Exit code | Meaning |
|---|---|---|
| `ok` | 0 | the check passed |
| `warn` | 1 | needs attention, but XWiki is serving or is about to |
| `crit` | 2 | XWiki is not serving, or will not for long |
| `unknown` | 3 | the check could not tell |

The overall status, and the exit code of `xinit check`, is the worst one, in this order: `crit`,
`warn`, `unknown`, `ok`. A check that cannot tell never hides a failure. An error in the command
line is exit code 64.

Formats:
- `text`: one line per check, then the overall status.
- `json`: `{"instance", "status", "results": [{"check", "status", "reason", "message", "metrics"}]}`.
- `nagios`: `XINIT <OK|WARNING|CRITICAL|UNKNOWN> - <what is wrong> | <performance data>`, then one
  line per check.

## Checks

### process

The unit is running, and its main process is a JVM.

| Status | Reason | When |
|---|---|---|
| ok | `running` | the unit is active |
| warn | `starting`, `stopping` | the unit is changing state |
| crit | `stopped`, `failed` | the unit is inactive or failed; or `PID_FILE` is set and no JVM has its PID |
| unknown | `no-unit` | the unit does not exist; or there is no systemd and no `PID_FILE` |
| unknown | `state` | any other unit state |

Metrics: `uptime_seconds` of the JVM, `restarts` by systemd.

A JVM that is frozen is still `running`: only the http check sees that it does not answer.

### http

`BASE_URL` + `HTTP_PATH` answers one of the `HTTP_EXPECT` codes. Redirects are not followed, and
the `~/.curlrc` of the user running xinit is not read.

| Status | Reason | When |
|---|---|---|
| ok | `ok` | an expected code, in less than `HTTP_SLOW` seconds |
| warn | `slow` | an expected code, in `HTTP_SLOW` seconds or more |
| warn | `initializing` | HTTP 202: XWiki answers this to every request until it has started |
| warn | `starting` | connection refused or no answer, from a JVM younger than `STARTUP_GRACE` |
| warn | `wizard` | a redirect to the Distribution Wizard: an administrator has to finish it |
| crit | `refused` | connection refused |
| crit | `timeout` | no answer within `HTTP_TIMEOUT` seconds |
| crit | `status` | another status code |
| crit | `redirect` | another redirect, for example to the login page of a wiki that guests cannot view |
| crit | `error` | any other failure of the request, such as a TLS error |
| unknown | `dns` | the host name does not resolve: not a fault of XWiki |
| unknown | `no-url`, `no-curl`, `bad-config` | `BASE_URL` is not known; curl is not installed; `HTTP_SLOW` or `HTTP_TIMEOUT` is not a number |

Metrics: `code`, `time_seconds`.

For a wiki that guests cannot view, give a login in a netrc file (`HTTP_NETRC`), or accept the
redirect with `HTTP_EXPECT=200 302`.

### rest

`BASE_URL/rest/` answers as XWiki's REST API. Failures have the same reasons as http, plus:

| Status | Reason | When |
|---|---|---|
| warn | `restart-pending` | the running version is not the installed one: XWiki was upgraded and not restarted |
| crit | `not-rest` | the answer is not the REST API's |

A fresh installation answers the REST API before the Distribution Wizard is finished, so this
check does not see the wizard. The http check does.

### oom

The journal of the unit, over the last `OOM_WINDOW` seconds.

| Status | Reason | When |
|---|---|---|
| ok | `ok` | nothing found |
| crit | `heap` | `java.lang.OutOfMemoryError` since the JVM started. That JVM is unreliable until it is restarted. |
| warn | `kernel` | the kernel's OOM killer killed a process of the unit's control group. systemd has usually restarted XWiki by then: the memory settings need attention, a restart does not help. |
| unknown | `no-access` | the user may not read the journal (group `systemd-journal`) |
| unknown | `no-journal`, `bad-config` | `LOG_SOURCE` is not the journal; `OOM_WINDOW` is not a number |

Metrics: `heap_errors`, `kernel_kills`.

### db

The database of `hibernate.cfg.xml` is reachable. xinit never uses the password of that file.

| Status | Reason | When |
|---|---|---|
| ok | `ok` | a login and `SELECT 1` succeeded, with the credentials file |
| ok | `port-only` | the port accepts connections, and the login is not checked: there is no credentials file, or no client for this database, or the database or user name has characters a client could misread |
| ok | `embedded` | HSQLDB, H2 or Derby: nothing to reach |
| crit | `refused`, `timeout`, `error` | the port does not accept connections |
| crit | `login-failed` | the login or the query failed |
| unknown | `dns` | the host name does not resolve |
| unknown | `no-db`, `bad-config` | the database is not known; `DB_TIMEOUT` or `DB_PORT` is not a number |

The credentials file is described in `etc/xinit.conf.example` (`DB_CREDENTIALS`). The password is
given to `psql` through `PGPASSFILE` and to `mariadb` / `mysql` through `--defaults-file`, never
on a command line.

### disk

Free space and free inodes of the file system of `PERMDIR`.

| Status | Reason | When |
|---|---|---|
| ok | `ok` | both above `DISK_WARN` percent |
| warn, crit | `low` | one is below `DISK_WARN`, or below `DISK_CRIT` |
| unknown | `no-permdir`, `no-dir`, `df-failed`, `bad-config` | the directory is not known or missing; `df` failed; a threshold is not a percentage |

Metrics: `free_percent`, `free_bytes`, `inodes_free_percent`.
