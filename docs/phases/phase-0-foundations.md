# Phase 0 — Foundations

Goal: everything later phases need to be developed and verified by people **and by agents**,
without manual setup.

Jira: XINIT-18 (test environment), XINIT-19 (CI).

## Tasks

### 0.1 Test environment: `tests/env/` (done)
- `xwiki-env.sh build <variant>` builds a provisioned image `xinit-test/xwiki:<variant>`. It has
  systemd as PID 1 and XWiki from a Debian package or as a WAR. The flavor is installed, the
  `Admin:admin` and `standard:standard` accounts exist, and superadmin is disabled.
- `start` / `wait` / `exec` / `rm` run disposable instances. `pull` / `push` exchange images with a
  registry.
- The variants are listed in `tests/env/variants`. Details are in [../test-env.md](../test-env.md).
- Verified locally, on a cgroup v1 host: `tomcat10-pgsql`, `tomcat11-mariadb`, `xjetty-pgsql` and
  `war-tomcat10-pgsql` (XWiki 18.9.0), and `tomcat10-mariadb-lts-debian12` (17.10.14).
  The integration suite (baseline + faults, 17 tests) passes on all five.
- Verified on GitHub's cgroup v2 runners (Test images workflow, run 1): all six variants build and
  pass the baseline tests, `tomcat10-mysql-ubuntu2404` included.
- Facts found while building them, which the profiles of Phase 1 must also know:
  - XWiki 18 needs Java 21. Debian 12 only has 17, so it runs the LTS.
  - `xwiki-*-mysql` depends on Oracle's `mysql-server`, which Debian lacks (it has MariaDB).
  - `xwiki-tomcat9-*` stopped at 16.10, and Debian 12 has no `tomcat9`: Tomcat 9 is dropped.

### 0.2 Code skeleton (done)
- `bin/xinit` (help, version, the exit-code conventions) and `lib/xinit/core.sh`. The rest of
  DESIGN §4 is created when its phase needs it. `xinit-application/` (1.3.x) is untouched until
  2.0 replaces it in Phase 6, so the 1.3 line stays releasable.
- `Makefile`: `lint`, `test-unit`, `test-integration VARIANT=…`, `test`, `images`, and `install` /
  `uninstall` (`PREFIX`, `DESTDIR`).

### 0.3 Lint and unit-test tooling (done)
- `shellcheck -x -S warning` on every new shell file and on the tests. Exceptions are annotated in
  the code.
- Plain `bats` from the distribution package (1.10 on Debian 13 and Ubuntu 24.04), without
  `bats-support`/`bats-assert`. The helpers in `tests/unit/helpers.bash` cover what the tests need.
  `fake <cmd> <body>` puts a recording fake on `PATH`.
- `tests/fixtures/<variant>/` holds real files copied from the images. It is filled by Phase 1,
  together with the profiles that read them.
- Formatting with `shfmt` is not adopted: it is not packaged where CI runs, and shellcheck covers
  correctness.

### 0.4 CI (done, integration still to be run on GitHub)
- `ci.yml`: lint + unit on every push and pull request. It passed on its first run.
- `integration.yml`: one job per variant. It pulls the published image or builds it, then runs
  `tests/integration`. It runs nightly, on demand, and on pull requests labelled `integration`.
- `test-images.yml`: runs weekly or on demand. It builds each variant, runs the baseline tests on
  it, then pushes it to `ghcr.io/<owner>/xinit-test-xwiki`.
- The `Jenkinsfile` / Maven build are unchanged (XWiki's CI and release).

Still to do, once the workflows are on the default branch (`workflow_dispatch` and `schedule`
only run from there):
- Publish the images with `test-images.yml`, then make the GHCR package public.
- Run `integration.yml` on every variant.

### 0.5 Test procedure (done)
- [../TESTING.md](../TESTING.md): the procedure for agents, the fault library and the scenario
  catalogue. `tests/run.sh` writes a `summary.json`.

## Acceptance
- `make lint test-unit` is green locally and in CI. **Met.**
- Every listed variant builds from scratch on a cgroup v1 host and a cgroup v2 host. **Met**: five
  variants locally (cgroup v1), all six on GitHub (cgroup v2).
- An agent can follow `docs/TESTING.md` with no human help.
