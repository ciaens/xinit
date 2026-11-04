# Test environment

`tests/env/xwiki-env.sh` builds and runs disposable XWiki instances. Each is a container with
systemd as PID 1 and one **official XWiki Debian package**, so xinit is tested against the real
units, paths and drop-ins.

## Images

`xinit-test/xwiki:<variant>`, where `<variant>` is the package name without `xwiki-`:
`tomcat10-pgsql`, `tomcat11-mariadb`, `xjetty-pgsql`…

Each image is already provisioned. The Distribution Wizard never shows. It has:

| Account | Password | Rights |
|---|---|---|
| `Admin` | `admin` | admin + programming (member of `XWikiAdminGroup`) |
| `standard` | `standard` | plain user (`XWikiAllGroup`) |

Superadmin is disabled. XWiki is at `http://localhost:8080/xwiki` inside the container.

The first build of a variant takes about 10 minutes, because it downloads the package and then
the flavor from extensions.xwiki.org. Starting a built image takes about 1–2 minutes before XWiki
answers.

## Usage

```bash
tests/env/xwiki-env.sh build tomcat10-pgsql
```

```bash
tests/env/xwiki-env.sh start tomcat10-pgsql            # → container xinit-tomcat10-pgsql
```

```bash
tests/env/xwiki-env.sh wait xinit-tomcat10-pgsql
```

```bash
tests/env/xwiki-env.sh exec xinit-tomcat10-pgsql systemctl status tomcat10
```

```bash
tests/env/xwiki-env.sh rm xinit-tomcat10-pgsql
```

- The repository is mounted read-only at `/src/xinit`.
- Set `XINIT_TEST_PORT=8081` to publish XWiki on `127.0.0.1:8081` of the host.
- Use a different container name (`start <variant> <name>`) to run several instances of one
  variant side by side.

## Host requirements

- Docker with `--privileged` allowed, since systemd needs it. Both cgroup v1 and v2 hosts work.
- Network access to `deb.debian.org`, `maven.xwiki.org`, `extensions.xwiki.org` and
  `nexus.xwiki.org` (build only).
- Behind an HTTPS-intercepting proxy, set `XINIT_TEST_CA=/path/to/ca-bundle.pem`. The bundle is
  injected into the system and Java trust stores at build and start, and removed before the image
  is committed.

## Why it is built this way

- **Not a plain `docker build`.** The `xwiki-*-{pgsql,mysql,mariadb}` packages create their
  database from maintainer scripts. That needs the database server running under systemd, which a
  `docker build` step cannot provide. So the image is built by running a container and then
  `docker commit`.
- **`policy-rc.d` is removed from the base image.** The Debian image ships it to stop services
  from starting during `apt install`, which makes the package's DB setup fail.
- **Splitting the CA bundle.** Java's trust store only imports the first certificate of each
  file, so a CA bundle is split into one file per certificate.
- **Why `XWiki.Admin` must exist.** The flavor's pages name it as their author. Without it, their
  scripts fail to render.
- **Not committed to git.** A provisioned image is 1–2 GB. Phase 0 plans a workflow that publishes
  the images to GHCR.
