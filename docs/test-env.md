# Test environment

`tests/env/xwiki-env.sh` builds and runs disposable XWiki instances. Each instance is a container
with systemd as PID 1 and XWiki installed the way admins install it:
- from an **official XWiki Debian package**;
- or as the **WAR** deployed in a distribution's Tomcat.

This way xinit is tested against the real units, paths and drop-ins.

## Images and variants

The images are named `xinit-test/xwiki:<variant>`. A variant is written
`<base>[-lts][-debian12|-ubuntu2404]`:

| Part | Meaning |
|---|---|
| `tomcat10-pgsql`, `xjetty-mariadb`… | the XWiki package `xwiki-<base>`, installed with every `xwiki-*` dependency at the package's newest version |

There is no Tomcat 9 variant. `xwiki-tomcat9-*` stopped at XWiki 16.10, when XWiki moved to Jakarta
EE, and no supported distribution ships `tomcat9` any more (Debian 12 only has `tomcat10`).
| `war-tomcat10-pgsql`, `war-tomcat11-mariadb` | the XWiki WAR exploded in `/var/lib/tomcatN/webapps/xwiki`, with Debian's `tomcatN` package, the JDBC driver from the distribution, and the permanent directory `/var/lib/xwiki-war/data`, following the WAR installation guide |
| `-lts` | XWiki from the LTS repository instead of stable |
| `-debian12`, `-ubuntu2404` | the distribution; Debian 13 by default |

`tests/env/variants` lists the variants CI builds, publishes and tests:

| Variant | XWiki | Why |
|---|---|---|
| `tomcat10-pgsql`, `tomcat11-mariadb`, `xjetty-pgsql` | stable | the three Debian package families |
| `war-tomcat10-pgsql` | stable | the `war` profile |
| `tomcat10-mariadb-lts-debian12` | LTS | XWiki 18 needs Java 21, which Debian 12 does not ship |
| `tomcat10-mysql-ubuntu2404` | stable | `xwiki-*-mysql` depends on Oracle's `mysql-server`: Ubuntu has it, Debian does not |

Each image is already provisioned, so the Distribution Wizard never shows. It has:

| Account | Password | Rights |
|---|---|---|
| `Admin` | `admin` | admin + programming (member of `XWikiAdminGroup`) |
| `standard` | `standard` | plain user (`XWikiAllGroup`) |

Superadmin is disabled. XWiki is at `http://localhost:8080/xwiki` inside the container.
`/etc/xinit-test-env` describes the instance as shell assignments: `VARIANT`, `VERSION`, `UNIT`,
`DB_UNIT`, `BASE_URL` and `CONFIG_DIR` (`/etc/xwiki` for packages, `WEB-INF` for the WAR). The
integration helpers read it.

Building a variant takes about 10 minutes, once: it downloads the packages, then the flavor from
extensions.xwiki.org. A container started from a built image answers after about 1 minute.

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

```bash
make images                                              # every variant in tests/env/variants
```

- The repository is mounted read-only at `/src/xinit`.
- Set `XINIT_TEST_PORT=8081` to publish XWiki on `127.0.0.1:8081` of the host.
- Use a different container name (`start <variant> <name>`) to run several instances of one
  variant side by side.
- Set `XINIT_TEST_KEEP=1` to keep a failed build's container (`xinit-build-<variant>`) for
  debugging.

### Published images

The **Test images** workflow (`.github/workflows/test-images.yml`) runs weekly, on demand, and on
every push that changes `tests/env/`. For each variant it builds the image and runs the baseline
tests on it. It then pushes it as `ghcr.io/<owner>/xinit-test-xwiki:<variant>` and
`:<variant>-<XWiki version>`, except on a push to a branch other than the default one. That
branch still gets its images checked, but cannot replace the published ones.

With `XINIT_TEST_REGISTRY=ghcr.io/<owner>`, `tests/run.sh` pulls a missing image instead of building
it. You can also pull or push one by hand:

```bash
XINIT_TEST_REGISTRY=ghcr.io/<owner> tests/env/xwiki-env.sh pull tomcat10-pgsql
```

A GHCR package is private when first pushed. Make it public once, in the package settings on
GitHub, so that it can be pulled without logging in.

## Host requirements

- Docker with `--privileged` allowed, since systemd needs it. Both cgroup v1 and v2 hosts work.
- Network access to the distribution mirrors, `maven.xwiki.org`, `extensions.xwiki.org` and
  `nexus.xwiki.org` (build only).
- Behind an HTTPS-intercepting proxy, set `XINIT_TEST_CA=/path/to/ca-bundle.pem`. The bundle is
  injected into the system and Java trust stores at build and start, and removed before the image
  is committed.

## Why it is built this way

- **Not a plain `docker build`.** The `xwiki-*-{pgsql,mysql,mariadb}` packages create their
  database from maintainer scripts. That needs the database server running under systemd, which a
  `docker build` step cannot provide. So the image is built by running a container and then
  `docker commit`.
- **`policy-rc.d` is removed from the base image.** The Debian image ships it to stop services from
  starting during `apt install`, which makes the package's DB setup fail.
- **Dependencies pinned to one version.** A plain `apt install xwiki-<variant>` fails when that
  package lags behind `xwiki-common`, as `xwiki-tomcat9-*` does.
- **Splitting the CA bundle.** Java's trust store only imports the first certificate of each file,
  so a CA bundle is split into one file per certificate.
- **Why `XWiki.Admin` must exist.** The flavor's pages name it as their author. Without it, their
  scripts fail to render.
- **Switching the WAR's database.** The WAR's `hibernate.cfg.xml` has nested comments, so its
  HSQLDB block cannot be commented out. `tests/env/war-hibernate.py` removes that block and opens
  the chosen database's block, then checks the result is well-formed with exactly one active
  connection URL.
- **Not committed to git.** A provisioned image is 1–2 GB; GHCR holds them instead.
