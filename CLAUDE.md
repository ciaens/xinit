# CLAUDE.md

Guidance for agents working in this repository.

## What this is

Xinit monitors XWiki instances: checks, restarts, diagnostics, notifications, and service
hardening.
- `xinit-application/` is the legacy 1.3.x tool. Leave it untouched; old instances keep running it
  until they are upgraded.
- Xinit 2 is a redesign in Bash, in `bin/`, `lib/xinit/` and `tests/`. Start with
  `docs/README.md`:
  - `DESIGN.md` is the architecture and the decisions already made;
  - `ROADMAP.md` lists the phases and their Jira issues;
  - `phases/phase-N-*.md` holds each phase's tasks and acceptance criteria;
  - `TESTING.md` is the test procedure and the scenario catalogue;
  - `test-env.md` describes the test images;
  - `checks.md` is the reference of `xinit layout` and `xinit check`;
  - `acting.md` is the reference of `xinit maint`, and of the state and lock of an instance.

What exists: `xinit layout` and `xinit check` (Phase 1), which only read, and `xinit maint`
(Phase 2). `watch`, `report` and `setup` are not implemented yet.

Load the XWiki plugin from https://github.com/xwiki/xwiki-dev-llm (clone it, then
`claude plugin marketplace add <clone>` and `claude plugin install xwiki@xwiki-dev-llm`). It holds
the XWiki conventions, and its `xwiki-jira` skill is used for Jira.

## Commands

```bash
tests/run.sh --suite lint --suite unit          # fast, no Docker
```

```bash
tests/run.sh --suite integration --variant tomcat10-pgsql   # needs Docker and the test image
```

```bash
tests/fixtures/collect.sh                       # rebuild tests/fixtures/ from the test images
```

- Results go to `tests/results/<timestamp>/summary.json`.
- `make help` lists the Makefile targets.
- Test images: `tests/env/xwiki-env.sh build|start|wait|exec|rm|pull|push <variant>`, with the
  variants in `tests/env/variants`.

## Conventions

- **Commit messages**: `XINIT-NN: …` for an issue, `[Misc] …` otherwise. End each one with exactly
  these two trailers, and no other trailer:
  ```
  Co-Authored-By: Clément Christiaens <commits@ciaens.me>
  Co-Authored-By: Claude <noreply@anthropic.com>
  ```
- **Jira (jira.xwiki.org)**:
  - New issues are short and named after the problem they address, never "phase N" or "rewrite"
    issues. The project lead sets reporter and assignee afterwards.
  - Comments state only the core idea ("Planned: …"), with no reference to phases, the rewrite,
    or design documents on a fork.
- **Security**: XWiki's security policy applies. A vulnerability, in xinit or in XWiki packaging,
  goes into a Jira issue with the `Confidential` security level. It is never described in this
  public repository: code, docs, comments or commit messages.
- **Shell**: `shellcheck -x -S warning` must be clean. Annotate any exception in the code.
  - `xinit layout` and `xinit check` write nothing, not even a temporary file. So `bin/` and `lib/`
    use no here-string (`<<<`) and no here-document on a variable: bash may back them with a
    temporary file. Use a pipe or `< <(printf …)`.
  - A value from a configuration or XML file never reaches a command unchecked: put `--` before
    it, or validate it first. A password never goes on a command line.
  - A configuration key `KEY` is set in the environment as `XINIT_KEY`, so no shell variable of
    xinit may have that name.
  - A function called as `$(…)` runs in a subshell: a variable it sets is lost.
  - Root never writes in a directory that belongs to another user: a command that has to write
    there runs again as that user (`xinit_state_become_owner`). A state file is written with
    `xinit_state_write` and read with `xinit_state_read`, never sourced.
  - The time comes from `xinit_now`, so that tests can set it with `XINIT_TEST_NOW`.
- **Configuration keys**: `etc/xinit.conf.example` is their reference. A unit test fails when it
  does not list every key with its real default.
- **Tests**: assert on xinit's machine output (`--format json`, exit codes), never on human-readable
  text. For a check result, assert its `status` and its `reason`. Each xinit scenario test starts with its scenario id from `docs/TESTING.md`. A scenario
  whose phase is not implemented calls `skip "Phase N"`.
- **Work with the project lead step by step**: short answers, one step at a time, ask before
  outward-facing actions (publishing, triggering CI, writing to Jira outside what was agreed).

## Facts that are easy to get wrong

These are verified on XWiki 18.9.0 / 17.10 with the Debian packages. The details are in the docs.
- JVM options for Tomcat go in `JDK_JAVA_OPTIONS`. A `JAVA_OPTS` set in the unit is overridden by
  the start script, which sources `/etc/default/tomcatN`.
- The packages pull in a JRE, which has no `jcmd`. Thread dumps then mean `kill -3` and the journal.
- With the database down, cached pages are still served.
- XWiki 18 needs Java 21, so Debian 12 runs the LTS. `xwiki-*-mysql` needs Oracle's
  `mysql-server`, which Debian lacks. Tomcat 9 is not supported.
- A restarted XWiki first refuses connections, then accepts them without answering, then answers
  `202` ("XWiki is initializing"), then `200`.
- A fresh XWiki answers `302` to `…/bin/distribution/XWiki/Distribution` on page requests, but
  not on REST requests. The provisioned test images never show it.
- `journalctl` exits 0 for a user who may not read the journal, and prints a notice instead.
- `systemctl show -p ControlGroup` gives the path the kernel uses in its OOM messages, container
  prefix included.
- bash 5.2 reads `&` in the replacement of `${var//pattern/replacement}` as the matched text,
  unless the replacement is quoted.
- Guests can read most pages, REST included. To check credentials, use
  `/bin/admin/XWiki/XWikiPreferences`: 200 for an admin, 403 for a logged-in user, 302 for a guest.

## Environment notes (cloud sessions)

- Docker may need starting: `dockerd > /tmp/dockerd.log 2>&1 &`. After a machine restart it can
  refuse to start because of a stale `/var/run/docker.pid`: remove that file first.
- A test container mounts the repository. Do not edit `bin/`, `lib/` or `tests/integration/`
  while an integration run is in progress.
- Behind the session's HTTPS proxy, export `XINIT_TEST_CA=/root/.ccr/ca-bundle.crt` before
  building or starting test images.
- Docker Hub can rate-limit (429). Retry later; GitHub's runners are not affected.
- Bash reads a running script as it executes it. Never edit `tests/env/*.sh` while a build runs from
  them: run long builds from a copy.
