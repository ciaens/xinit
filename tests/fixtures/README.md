# Test fixtures

Real files and command outputs copied from the test images (`tests/env/`). The unit tests use them
as inputs.

```bash
tests/fixtures/collect.sh                  # every variant with a local image
```

```bash
tests/fixtures/collect.sh xjetty-pgsql     # one variant
```

`collect.sh` starts a disposable container for each variant and rebuilds
`tests/fixtures/<variant>/` from it. Run it again when a new XWiki version changes these files.

## Layout

- One directory per image variant. It mirrors the instance's file system, so a test can point
  xinit at it as an alternative root.
- Files keep their path: `etc/xwiki/hibernate.cfg.xml`.
- Command outputs are in `cmd/`:

| File | Command |
|---|---|
| `systemctl-show-<unit>.txt` | `systemctl show <unit>`, with XWiki running |
| `systemctl-cat-<unit>.txt` | `systemctl cat <unit>` |
| `dpkg-query.txt` | `dpkg-query -W` of `xwiki*` and `tomcat*`: package, version, status |
| `ps-unit-user.txt` | `ps -o pid,ppid,user,comm` of the unit's user |
| `proc-1-comm.txt` | `/proc/1/comm` |
| `systemd-detect-virt.txt` | `systemd-detect-virt --container` |

## What differs from the instance

- The database password in `hibernate.cfg.xml` is replaced by `REDACTED`. `collect.sh` then checks
  the real one appears nowhere.
- `extension.xed` is cut after its header. The full file lists every bundled extension (about
  300 KB), and only the header is read.
- A symbolic link is replaced by the file it points to. The packages link Tomcat's context file
  `Catalina/localhost/xwiki.xml` to `/etc/xwiki/xwiki-tomcatN.xml`.

## Journal

`journal/` holds journal lines of real events, as `journalctl -o cat` prints them: a heap
`OutOfMemoryError`, a kill by the kernel's OOM killer, and the start and end of a thread dump
(`kill -3`). They were copied by hand from a test container. The kill by the kernel comes three
times: on cgroup v1 (`kernel-oom-system.txt`), on cgroup v2 with systemd 252
(`kernel-oom-cgroup2-system.txt`), and with systemd 259, which words it differently
(`kernel-oom-systemd259-system.txt`). The last two come from the log of a CI run.
