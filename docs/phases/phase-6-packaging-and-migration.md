# Phase 6 — Packaging, migration, release

Goal: existing 1.3 users can upgrade, new users install with one command, and 2.0.0 is released.

## Tasks
- `make install PREFIX=/usr DESTDIR=…` installs:
  - `bin/` → `$PREFIX/bin`;
  - `lib/` → `$PREFIX/lib/xinit`;
  - `share/` → `$PREFIX/share/xinit`;
  - units → `$PREFIX/lib/systemd/system`;
  - the example config to `/etc/xinit`, without overwriting an existing file.
- `install.sh` becomes a thin wrapper around `make install`, with a check of the dependencies it
  needs.
- `.deb` (XINIT-13): use `debian/` packaging, or `nfpm`/`fpm` from the Makefile.
  - `Depends:` bash, curl, iproute2.
  - `Recommends:` default-jdk-headless | the JDK already used by XWiki (for `jcmd`),
    postgresql-client | mariadb-client, a mail transport.
  - `postinst` creates the `xinit` system user (`systemd-sysusers` snippet).
  - Built in CI and published as a release asset. An APT repo is out of scope unless XWiki's Nexus
    can host it.
- Maven assembly: keep the zip produced by `pom.xml` for the XWiki release process, with the new
  tree as its content.
- Migration:
  - `xinit config migrate /etc/xinit/xinit.cfg` writes `xinit.conf` and lists what it could not
    map.
  - The old `/etc/init.d/xwiki.sh`, the xinit-owned `xwiki.service` (a 1.3 install) and the cron
    entries are detected. `xinit setup --migrate` disables them and the change is shown in the
    output.
- Other distributions:
  - a RHEL 9 family image (Rocky/Alma) with a tarball Tomcat and the WAR, tested as the `war`
    profile;
  - check SELinux contexts for the state dir and the polkit rule.
- `LimitNOFILE=` is set in the drop-in and checked (XINIT-6).
- Documentation:
  - `README.md` rewritten;
  - an admin guide page proposed for xwiki.org (install, configure, modes, FAQ), using the
    `xwiki-doc-writing` skill conventions.
- Release 2.0.0, through Maven release like 1.3.x plus the `.deb` asset. Announce it on the forum.

## Acceptance
- On a host with xinit 1.3.3 installed by its `install.sh`: migrate, then `setup`, gives a working
  2.0 with the same monitoring behaviour, and nothing of 1.3 left active.
- `apt install ./xinit_2.0.0_all.deb && xinit setup` works on Debian 12, Debian 13 and Ubuntu 24.04
  test images.
- The `war` profile passes the Phase 1 to 3 integration scenarios on Rocky 9.
