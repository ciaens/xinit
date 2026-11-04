# Phase 0 — Foundations

Goal: everything later phases need to be developed and verified by people **and by agents**,
without manual setup.

## Tasks

### 0.1 Test environment — `tests/env/` (done)
- `xwiki-env.sh build <variant>` builds `xinit-test/xwiki:<variant>`. The image is Debian 13 with
  systemd as PID 1, one official XWiki package, and is already provisioned:
  - the main flavor is installed;
  - `Admin:admin` has admin + programming rights;
  - `standard:standard` is a plain user;
  - superadmin is disabled.
- `start` / `wait` / `exec` / `rm` run disposable instances. The repository is mounted at
  `/src/xinit`.
- How to use it: [../test-env.md](../test-env.md).

Verified: `tomcat10-pgsql` (Debian 13, XWiki 18.9.0) builds from scratch, and a fresh container answers in about 1 minute with the accounts above.

To do:
- Build and verify the variants `tomcat11-mariadb`, `xjetty-pgsql`,
  `tomcat9-mysql` (Debian 12 base), and a **WAR** variant (Debian 13 `tomcat10` + the XWiki WAR in
  `/var/lib/tomcat10/webapps`, no `xwiki-*` package).
- A GitHub Actions workflow that builds the variants weekly and pushes them to
  `ghcr.io/<owner>/xinit-test-xwiki:<variant>`, so they are pulled instead of rebuilt. A provisioned
  image is 1–2 GB and must not be committed to git.

### 0.2 New tree skeleton
- Create the layout of DESIGN §4. Keep `xinit-application/` (1.3.x) untouched until 2.0 replaces it
  in Phase 6, so the 1.3 branch stays releasable.
- Add a `Makefile` with `lint`, `test-unit`, `test-integration VARIANT=…` and `install`
  (`PREFIX`, `DESTDIR`).

### 0.3 Lint and unit-test tooling
- `shellcheck -x` on every shell file, with no exceptions except annotated ones.
- `shfmt -i 2 -ci -d` for formatting (optional; decide once).
- `bats-core` + `bats-support` + `bats-assert`, vendored as git submodules under `tests/lib/` or
  installed from the distribution package. Unit tests stub external commands (`systemctl`,
  `dpkg-query`, `curl`, `jcmd`) with small fakes on `PATH`, using fixtures in `tests/fixtures/`.
  Examples of fixtures: real `hibernate.cfg.xml` from each DB package, `systemctl show` outputs,
  and `extension.xed`.

### 0.4 CI
- `.github/workflows/ci.yml`: run lint + unit on every push and PR (fast, no Docker images).
- `.github/workflows/integration.yml`: pull or build the test images and run
  `tests/integration` for each variant. Run it nightly, on demand, and on PRs labelled
  `integration`.
- Keep the `Jenkinsfile` / Maven build working (XWiki's CI and release).

### 0.5 Test procedure
- `docs/TESTING.md`: the procedure, the scenario catalogue (what to break, and what xinit must
  report or do), and how an agent runs it (`tests/run.sh` → machine-readable summary).

## Acceptance
- `make lint test-unit` is green locally and in CI.
- `tests/env/xwiki-env.sh build` works for each listed variant, from scratch, on a cgroup v1 and a
  cgroup v2 host.
- An agent can follow `docs/TESTING.md` with no human help.
