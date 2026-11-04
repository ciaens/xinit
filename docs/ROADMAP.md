# Xinit 2 — Roadmap

The target architecture is in [DESIGN.md](DESIGN.md). Each phase ends in something that can be used
and tested, and each phase has its own document with tasks and acceptance criteria.

| Phase | Theme | Outcome | Jira |
|---|---|---|---|
| [0](phases/phase-0-foundations.md) | Foundations | test environment, CI (shellcheck + bats), new tree skeleton, test procedure | XINIT-12 (build kept) |
| [1](phases/phase-1-detect-and-check.md) | Detection + read-only checks | `xinit layout`, `xinit check` on Debian Tomcat 9/10/11, xjetty and declared WAR; text/JSON/Nagios output | XINIT-10, 11, 16, 17 |
| [2](phases/phase-2-act.md) | Acting safely | `xinit watch` + restart policy, maintenance, systemd timer and drop-in, `OnFailure` notification, warm-up, non-root via polkit | XINIT-14, 15, 2 |
| [3](phases/phase-3-diagnose-and-notify.md) | Diagnostics + notifications | `xinit report` bundle (jcmd, journal, DB activity, OOM), mail + webhook, Prometheus textfile | XINIT-4, 5, 7 |
| [4](phases/phase-4-containers.md) | Containers | in-container health check, sidecar image, compose/k8s examples, tested against the official `xwiki` image | — |
| [5](phases/phase-5-packaging-and-migration.md) | Packaging + migration | `make install`, `.deb`, 1.3 config migration, docs on xwiki.org, release 2.0.0 | XINIT-13, 6 |

Phases 1–3 are what a 2.0.0 needs; 4 and 5 can overlap with 3.

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
| XINIT-6 ulimit on RedHat | 5 | becomes `LimitNOFILE=` in the drop-in, checked by `config` |
| XINIT-7 rotate catalina.out | 3 | obsolete with journald; logrotate snippet for WAR installs logging to a file |
| XINIT-10 PostgreSQL | 1 (check), 3 (report) | |
| XINIT-11 without MySQL | 1 | DB checks are optional per type |
| XINIT-13 .deb package | 5 | |
| XINIT-14 multiple first requests | 2 | warm-up unit |
| XINIT-15 non-root | 2 | `xinit` user + polkit |
| XINIT-16 Jetty | 1 | `debian-xjetty` profile |
| XINIT-17 multiple installation types | 1 | profiles |

New issues to create once this roadmap is agreed: one epic-like issue per phase, plus container
support, CI and the test environment.
