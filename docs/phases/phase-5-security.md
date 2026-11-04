# Phase 5 — Service hardening

Goal: xinit can harden the XWiki service with systemd, at a level chosen by the admin. Each level is
**measured** and **tested**: XWiki keeps working, and code running inside XWiki (a Groovy script,
or a remote code execution through a vulnerable extension) loses what the level is meant to take
away.

This phase was the main motivation for the rewrite. The 2025 `rework` branch had a first
`systemd-hardening.conf`; it is the starting point, reviewed below.

## 1. What is in place today

| Unit | Already set by the package | Not set |
|---|---|---|
| `tomcatN.service` (Debian `tomcatN` package) + `xwiki-tomcatN-systemd.conf` drop-in | `User=tomcat`, `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict` with `ReadWritePaths` for `/etc/tomcatN/Catalina`, `webapps`, logs, `/var/lib/xwiki/data`; `AmbientCapabilities=CAP_NET_BIND_SERVICE` | everything else: `ProtectHome`, kernel/proc protections, capability bounding set, syscall filter, address families, namespaces… |
| `xwiki.service` (`xwiki-xjetty-common`) | `User=xwiki`, `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict`, `ReadOnlyPaths=/etc/xwiki`, `ReadWritePaths=/var/lib/xwiki /var/log/xwiki` | the same |

The first deliverable of this phase records each unit's `systemd-analyze security` score as a
baseline in the test results.

## 2. Review: how the packages start XWiki

This was checked on XWiki 18.9.0 / Debian 13. The Tomcat chain was traced with `strace -f -e
trace=execve`; the xjetty chain was read from the script and observed on a running instance.

### Tomcat (`tomcat10.service`, Debian's package)
- The chain is: `ExecStartPre=+tomcat-update-policy.sh` (as root), then
  `ExecStart=/bin/sh tomcat-start.sh`. That script sources `/etc/default/tomcat10` and
  `tomcat-locate-java.sh`, then runs `exec catalina.sh run`, which runs `uname` and `dirname`, then
  `exec java`.
- In total, 4 programs run before Java (`sh`, `catalina.sh`, `uname`, `dirname`). After that, the
  JVM is the unit's MainPID and the **only process in its cgroup**. Every later clone is a thread.
- Consequence: forks and execs happen only during startup, but they do happen. An `ExecPaths=`
  restriction would have to allow `/bin/sh`, `/usr/bin/uname`, `/usr/bin/dirname` and the scripts.
  Allowing `/bin/sh` defeats the purpose.
- Side effect, already met in the fault tests: `/etc/default/tomcat10` is sourced by the start
  script, so it overrides any `JAVA_OPTS` set by a drop-in. `JDK_JAVA_OPTIONS` works.

### Jetty (`xwiki.service`, `xwiki-xjetty-common`)
`ExecStart=/bin/bash start_xwiki.sh --noninteractive` is the generic `start_xwiki.sh` of the Jetty
distribution, reused as is. Before `exec java` it does the following:
- resolves its own path with `ls`, `expr` and `dirname`;
- starts a **whole JVM** (`java -version`) to check the Java version. That check is redundant with
  the package's dependencies;
- `mkdir`s directories that `StateDirectory=`/`LogsDirectory=` could create;
- writes a lock file and checks it with `ps` and `cat`;
- **leaves a watcher subshell running beside the JVM for the lifetime of the service**: `( while
  kill -0 $PID; do sleep 1; done; rm lockfile ) &`. That runs `sleep` every second, so 86,400
  fork+exec per day, inside the service's cgroup.

The unit also has `ExecStop=/bin/bash stop_xwiki.sh`. That script starts up to two more JVMs
(`java -version`, then `java -jar start.jar --stop`), then `kill`, then `kill -9`. systemd already
does all of this with `KillSignal=SIGTERM` / `TimeoutStopSec` / `SendSIGKILL`, and Jetty stops
cleanly on SIGTERM.

The permanent watcher is what makes "no fork/exec after startup" impossible on xjetty, and the
wrapper scripts make it impossible on both.

### Why "ban forking" must be done with exec restrictions, not a syscall filter
- systemd's `SystemCallFilter=` filters by syscall **name** only, never by argument.
- Threads and processes are both created with `clone`/`clone3`, so these calls cannot be denied
  without killing the JVM. 35 `clone`/`clone3` calls were counted during Tomcat's startup, all
  threads except the 4 execs above.
- glibc's `fork()` and `posix_spawn()`, which Java's `ProcessBuilder` uses, also call `clone`,
  not the `fork`/`vfork` syscalls. So `SystemCallFilter=~fork vfork` blocks nothing that matters.
  *To be verified by the attack suite (§4.3).*
- What does work:
  - `NoExecPaths=/` with `ExecPaths=` limited to the JDK and the shared-library directories the JVM
    maps executable;
  - `TasksMax=`, as a limit on runaway thread or process counts.

  A process can still be created, but it can only run code from the JDK: no `sh`, no `curl`, and
  no dropped binary, since writable paths are no-exec too.

### What this means for xinit
The strictest level requires starting `java` directly. Two routes, to be decided in this phase:

1. **xinit renders the java command line.** `xinit setup --harden=strict` writes a drop-in that
   replaces `ExecStart=` with the JDK's `java` and the arguments the package scripts would have
   computed. Those arguments go in an `EnvironmentFile=` generated by xinit.
   - `ExecStop=` is reset, so systemd stops the JVM with SIGTERM.
   - The directories come from `StateDirectory=`/`LogsDirectory=` or from an
     `ExecStartPre=` that runs before the restrictions apply.
   - Risk: a package upgrade can change the arguments. `xinit check config` compares the rendered
     line with what the package script would produce and reports any drift.
2. **Upstream fixes**, preferred long term: the xjetty unit starts `java` directly, with no
   watcher, no `java -version` probe and no `ExecStop` script. Issues are to be filed on the XWiki
   Debian packaging. Tomcat's wrapper is Debian's own, so route 1 stays necessary there.

## 3. Hardening levels

The levels are written by `xinit setup --harden=<level>` as
`/etc/systemd/system/<UNIT>.d/60-xinit-hardening.conf`, and undone by `setup --undo`.

| Level | Content (to be finalised by the tests) | Requirements |
|---|---|---|
| `baseline` | `ProtectHome`, `ProtectKernelTunables/Modules/Logs`, `ProtectControlGroups`, `ProtectClock`, `ProtectHostname`, `PrivateDevices`, `ProtectProc=invisible`, `CapabilityBoundingSet=` (keeping `CAP_NET_BIND_SERVICE` only if the port is < 1024), `RestrictSUIDSGID`, `RestrictRealtime`, `RestrictNamespaces`, `LockPersonality`, `SystemCallArchitectures=native`, `SystemCallFilter=@system-service` minus what the tests show XWiki never needs, `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK`, `UMask=0027` | none; it must be safe on every supported install |
| `strict` | `baseline` + `NoExecPaths=/` and `ExecPaths=<JDK> <lib dirs>` + `ExecStart=` java directly + `TasksMax=` + `InaccessiblePaths=` for paths XWiki never reads | direct java start (§2) |
| `strict+office` | `strict` + the LibreOffice binaries in `ExecPaths=` (and their shell wrapper's needs) | only for wikis using office conversion |
| `custom` | the admin's own drop-in, still measured and tested by `xinit harden test` | — |

### Review of the rework branch's `systemd-hardening.conf`
Kept: most of the protection list, the dropped capabilities, `NoNewPrivileges`, the
`RestrictAddressFamilies` idea, the syscall-filter idea, and leaving `MemoryDenyWriteExecute` off
because the JIT needs W+X memory.

To change:
- **`TemporaryFileSystem=/etc:ro` + a bind-mount allow-list.** It hides `/etc/passwd` and
  `/etc/group`, which breaks user lookups (`getpwuid`, used by the JVM and by libraries for
  `user.home` / `user.name`). The list also has to be kept up to date per distribution and per Java
  version. Prefer `InaccessiblePaths=` for the few sensitive files (`/etc/shadow`, `/etc/gshadow`,
  `/etc/ssh`, `/etc/sudoers*`). The attack suite (§4.3) checks they are unreadable.
- **`ProcSubset=pid`.** It hides `/proc/meminfo`, `/proc/stat` and `/proc/cpuinfo`. The JVM's
  container detection and some monitoring agents (Glowroot) read them. Test it before keeping it.
- **`PrivateUsers=yes`.** It drops supplementary groups and maps unknown owners to `nobody`. That
  is risky with a shared data directory. Keep it off unless the tests prove it safe.
- **`UMask=0077`.** Files created by XWiki become unreadable to an admin group or a backup user.
  `0027` is a safer default.
- **`InaccessiblePaths=/srv /mnt`.** It breaks installs that keep the permanent directory or
  attachments there. Derive the list from the layout (never hide `PERMDIR` or the store paths).
- **`RestrictAddressFamilies` without `AF_NETLINK`.** Java's `NetworkInterface` (`getifaddrs`) uses
  netlink. Test whether XWiki needs it (for clustering or JGroups, or for UUID generation).
- **It is enabled by default** and was not tested per container: Tomcat needs
  `/etc/tomcatN/Catalina` writable, and xjetty has different paths. The levels above are opt-in, and
  `baseline` must pass the full suite on every image variant before it can become a default.

## 4. Tests

### 4.1 Measure
`systemd-analyze security <UNIT>` is recorded for every level and image variant. The test fails if
the score of a level gets worse than the recorded value.

### 4.2 Functional suite: XWiki still works (`70-hardening.bats`)
Run for each level × variant. Each item is done through REST or HTTP as `Admin` or `standard`:
- the service starts and restarts; it stops cleanly on SIGTERM within `TimeoutStopSec`;
- view, create, edit and delete a page; edit as `standard` in its own space;
- upload and download an attachment (permanent directory writes);
- search (embedded Solr writes to the permanent directory);
- Extension Manager: search the remote repository and install a small extension (network + permanent
  directory);
- send a mail to a local test MTA (SMTP egress);
- image thumbnail generation (`?width=`), which uses Java AWT in headless mode with fonts read
  from `/etc/fonts` and `/usr/share/fonts`;
- the database survives a service restart; logs are written where the layout says;
- `strict+office` only: an office document import (the office server starts and converts).

### 4.3 Attack suite: what code inside XWiki can no longer do (`71-hardening-attacks.bats`)
A Groovy page created by `Admin` (programming rights) plays the attacker. Each attempt is expected
to succeed or fail depending on the level, as recorded in a per-level table in the test file:
- run `/bin/sh -c id` (`ProcessBuilder`), run a binary dropped into the permanent directory or
  `/tmp` (strict: both denied);
- read `/etc/shadow`, `/root`, `/home/*`, another service's config such as `/etc/postgresql`, and
  `/etc/dbconfig-common` (denied at every level, except what the layout needs);
- write outside `PERMDIR`, the logs and `CATALINA_BASE` paths, for example `/usr/lib/xwiki`,
  `/etc/xwiki` and `/var/lib/postgresql` (denied);
- open a raw or packet socket (denied); create a user namespace (denied); load a kernel module /
  change sysctl / set the clock (denied);
- list processes of other users through `/proc` (hidden);
- `ptrace` another process (denied).

### 4.4 Regression across upgrades
After `apt install --only-upgrade` of the XWiki packages in the test image, the hardened unit
still starts, and `xinit check config` reports no drift. For route 1, it reports the drift when
the test simulates a changed start script.

## Acceptance
- For each variant, `baseline` passes §4.2 and its §4.3 expectations. `strict` passes both on
  Tomcat 10/11 and xjetty.
- The exposure score of each level is recorded and enforced.
- `setup --undo` restores the unit exactly.
- The upstream issues for the xjetty start chain are filed, and route 1 or route 2 is decided.
