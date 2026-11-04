# Xinit 2 — Roadmap

The target architecture is in [DESIGN.md](DESIGN.md). Each phase ends in something that can be used
and tested, and each phase has its own document with tasks and acceptance criteria.

| Phase | Theme | Outcome | Jira |
|---|---|---|---|
| [0](phases/phase-0-foundations.md) | Foundations | test environment, CI (shellcheck + bats), new tree skeleton, test procedure | XINIT-18, 19 |
| [1](phases/phase-1-detect-and-check.md) | Detection + read-only checks | `xinit layout`, `xinit check` on Debian Tomcat 10/11, xjetty and declared WAR; text/JSON/Nagios output | XINIT-10, 11, 16, 17, 20, 24 |
| [2](phases/phase-2-act.md) | Acting safely | `xinit watch` + restart policy, maintenance, systemd timer and drop-in, `OnFailure` notification, warm-up, non-root via polkit | XINIT-2, 14, 15, 21, 22 |
| [3](phases/phase-3-diagnose-and-notify.md) | Diagnostics + notifications | `xinit report` bundle (jcmd, journal, DB activity, OOM), mail + webhook, Prometheus textfile | XINIT-4, 5, 7, 23, 27, 31 |
| [4](phases/phase-4-containers.md) | Containers | in-container health check, sidecar image, compose/k8s examples, tested against the official `xwiki` image | XINIT-26 |
| [5](phases/phase-5-security.md) | Service hardening | tested systemd hardening levels for the XWiki unit (`xinit setup --harden`), exposure score, functional + attack test suites, direct `java` start | XINIT-30, XWIKI-25659 |
| [6](phases/phase-6-packaging-and-migration.md) | Packaging + migration | `make install`, `.deb`, 1.3 config migration, docs on xwiki.org, release 2.0.0 | XINIT-6, 13, 32 |

Phases 1–3 and 5 are what a 2.0.0 needs. Phase 4 can overlap with 3, and Phase 5 can start as soon
as the test environment and `xinit setup` (Phase 2) exist.

## Added to the original request

These were not in the initial list:

- **CI on GitHub Actions** (shellcheck + bats unit + a nightly integration matrix in containers).
  Xinit had no automated tests.
- **Reproducible test images** (`tests/env/`). They are provisioned with no Distribution Wizard and
  have `Admin:admin` and `standard:standard`. Publishing them to GHCR is proposed in Phase 0, so
  agents and CI skip the ~10-minute build.
- **Multi-instance from the start** (XINIT-2), because it changes the state and config layout and
  is cheap to design in now but expensive to retrofit.
- **Event-driven crash handling.** systemd `Restart=` + `OnFailure=` replaces polling for a dead
  process. Polling remains for hangs (HTTP), which systemd cannot see.
- **Restart policy** (consecutive failures, cooldown, flapping limit) instead of restarting on the
  first failed request.
- **Prometheus textfile output** and the **Nagios** format, both from the same results.
- **Security cleanup**: no secrets in argv or world-readable files, no `eval` of config.

## Jira

Existing open issues and where they land:

| Issue | Phase | Note |
|---|---|---|
| XINIT-2 multiple instances | 1 (layout), 2 (watch) | instance concept from Phase 1 |
| XINIT-4 reports to several emails | 3 | `MAIL` list + `xinit report --send` |
| XINIT-5 DNS support | 3 | DNS failure = `unknown`, not `crit` (no restart); DNS trace in report |
| XINIT-6 ulimit on RedHat | 6 | becomes `LimitNOFILE=` in the drop-in, checked by `config` |
| XINIT-7 rotate catalina.out | 3 | obsolete with journald; logrotate snippet for WAR installs logging to a file |
| XINIT-10 PostgreSQL | 1 (check), 3 (report) | |
| XINIT-11 without MySQL | 1 | DB checks are optional per type |
| XINIT-13 .deb package | 6 | |
| XINIT-14 multiple first requests | 2 | warm-up unit |
| XINIT-15 non-root | 2 | `xinit` user + polkit |
| XINIT-16 Jetty | 1 | `debian-xjetty` profile |
| XINIT-17 multiple installation types | 1 | profiles |

New issues, each named after the problem it addresses:

| Issue | Phase |
|---|---|
| XINIT-18 Provide disposable, pre-provisioned XWiki instances for integration tests | 0 |
| XINIT-19 Run shellcheck and the automated tests in CI | 0 |
| XINIT-20 Report check results in a machine-readable form | 1 |
| XINIT-24 Default JVM options prevent Tomcat from starting on Java 17 and later | 1 |
| XINIT-21 Restart XWiki only after several consecutive failed checks | 2 |
| XINIT-22 Let systemd restart a crashed XWiki and send the crash notification | 2 |
| XINIT-23 Thread dumps and logs are missing from notifications on Debian package installs | 3 |
| XINIT-27 Send notifications to a webhook instead of Jabber | 3 |
| XINIT-31 Export check results as Prometheus metrics | 3 |
| XINIT-26 Monitor XWiki running in a container | 4 |
| XINIT-30 Provide tested systemd hardening levels for the XWiki service | 5 |
| XWIKI-25659 Start Jetty directly from the xwiki-xjetty systemd service (upstream) | 5 |
| XINIT-32 Migrate a 1.3 configuration to the new configuration format | 6 |
| XINIT-28 Remove the OpenOffice server management | 1 |
| XINIT-29 Remove the MySQL spam detection | 1 |
