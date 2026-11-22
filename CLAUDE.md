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
  - `acting.md` is the reference of `xinit setup`, `xinit watch` and `xinit maint`, and of the
    state and lock of an instance;
  - `reporting.md` is the reference of `xinit report`;
  - `notifications.md` is the reference of the notifications: the journal entries and the mail.

What exists: `xinit layout` and `xinit check` (Phase 1), which only read, `xinit maint`,
`xinit watch` and `xinit setup` (Phase 2), with the commands the installed units run (`act`,
`notify`, `warmup`), and `xinit report` with the notifications by mail (Phase 3, in progress:
webhook and metrics are still to do).

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
  - Nothing is opened or written, as root, in a directory another user owns. What root reads
    from such a directory (a state file) is data: never a path, never a command, and its control
    characters are removed before it is shown.
  - A command that runs as another user gets no terminal and none of root's environment
    (`xinit_state_become_owner`).
  - A function that `xinit watch` calls returns an error, with its reason in a variable: it
    never ends xinit itself (`xinit_report_build`).
  - A temporary file or directory is created with `mktemp`, for its owner only, and removed when
    the command ends, also when it fails.
  - A function that removes temporary files at the end is registered with `xinit_on_exit`:
    there is one `EXIT` trap, in `lib/xinit/core.sh`.
  - What `curl` needs to send a mail goes on its standard input (`--config -`), after it was
    checked: an address, a URL or a path never goes on its command line.
  - The time comes from `xinit_now`, so that tests can set it with `XINIT_TEST_NOW`.
  - `kill` is a bash builtin, which a unit test cannot replace: send signals with `xinit_signal`.
    A unit test must never signal a real process: the PIDs of the fixtures are not ours.
- **Configuration keys**: `etc/xinit.conf.example` is their reference. A unit test fails when it
  does not list every key with its real default.
- **Unit test fakes**: a fake that xinit runs through `env -i` gets no variable of the test: write
  paths out in its body (`"... >'$FAKEBIN/x'"`), never `"$FAKEBIN"` to be expanded when it runs.
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
- The journal read with `-o cat` has no empty line: in a thread dump, nothing separates two
  threads but the `"name"` line of the next. XWiki names a request thread `<name> - <URL>`, and
  HotSpot prints `cpu=…ms` and `nid=` for each thread.
- `awk` is mawk on Debian 13 and Ubuntu, gawk on Debian 12: `lib/xinit/threads.awk` and the awk
  programs in `lib/` use what both have (no `{n}` in a regular expression, no `asort`).
- A JVM stopped with `kill -STOP` gives no thread dump: `kill -3` stays pending. `systemctl
  restart` still works on it, since systemd sends `SIGCONT` after `SIGTERM`.
- `OnFailure=` does not fire for a crash that `Restart=` repairs: the unit only enters the failed
  state when systemd gives up. `ExecStopPost=` runs at each stop, with `$SERVICE_RESULT`.
- `LoadCredential=` does not work in the Docker test containers: the credentials directory is
  not visible to the service.
- `systemctl show` works for an unprivileged user; `systemctl restart` answers "Access denied"
  (the test images have no polkit).
- On cgroup v2, systemd knows when the kernel's OOM killer killed a process of a unit: it ends
  the unit with `Result=oom-kill` and leaves it `failed`. Only `Restart=on-failure` or `always`
  starts it again: the units of the packages do not (seen with systemd 252, 257 and 259). On
  cgroup v1 it sees a process killed by a signal, and they do.
- systemd 259 words that kill differently in the journal ("The kernel OOM killer killed some
  processes in this unit"). The `Result` of the unit does not depend on the wording.
- `journalctl` exits 0 for a user who may not read the journal, and prints a notice instead.
- `systemctl show -p ControlGroup` gives the path the kernel uses in its OOM messages, container
  prefix included.
- bash 5.2 reads `&` in the replacement of `${var//pattern/replacement}` as the matched text,
  unless the replacement is quoted.
- `curl` sends a mail as the file is: it adds no CR, and only escapes a leading dot after a
  CR LF. Without a path in the `smtp://` URL, it gives the server the name of the uploaded file
  as its host name. It reads an SMTP login from `--netrc-file`.
- `logger --journald` reads `FIELD=value` lines from its standard input, and succeeds without a
  word when there is no journal.
- bash keeps a `HOSTNAME` it finds in its environment: a unit test sets the host name that way.
- Guests can read most pages, REST included. To check credentials, use
  `/bin/admin/XWiki/XWikiPreferences`: 200 for an admin, 403 for a logged-in user, 302 for a guest.

## Environment notes (cloud sessions)

- Docker may need starting: `dockerd > /tmp/dockerd.log 2>&1 &`. After a machine restart it can
  refuse to start because of a stale `/var/run/docker.pid`: remove that file first.
- `docker exec` runs with umask 0000: what a test creates in a container is world-writable unless
  it sets a mode.
- A test container mounts the repository. Do not edit `bin/`, `lib/` or `tests/integration/`
  while an integration run is in progress.
- Behind the session's HTTPS proxy, export `XINIT_TEST_CA=/root/.ccr/ca-bundle.crt` before
  building or starting test images.
- Docker Hub can rate-limit (429). Retry later, or take a base image from a mirror with
  `BASE_IMAGE=mirror.gcr.io/library/<image>`; GitHub's runners are not affected.
- This machine has cgroup v1. systemd 258 and later need cgroup v2: the Ubuntu 26.04 variant
  (systemd 259) does not boot here, and is built and tested by the workflows only.
- The result archives of a workflow run cannot be downloaded from here (the proxy refuses
  GitHub's storage host). `tests/run.sh` prints what each failed test said: read the job log.
- This session's GitHub access cannot start a workflow (`workflow_dispatch` answers 403): ask
  the project lead to run `gh workflow run integration.yml --repo <fork> --ref master`.
- Bash reads a running script as it executes it. Never edit `tests/env/*.sh` while a build runs from
  them: run long builds from a copy.
